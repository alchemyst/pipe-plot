import Foundation
import Darwin

/// A bounded, newline-delimited JSON stream over a local Unix domain socket.
/// The connection owns its descriptor and is safe to close from another thread.
public final class SocketConnection {
    public static let maximumFrameBytes = 1_048_576

    private let descriptor: Int32
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pending = Data()
    private var isClosed = false

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Native descriptor for integrating socket readiness into `poll(2)` loops.
    public var fileDescriptor: Int32 { descriptor }

    public func send<T: Encodable>(_ value: T, encoder: JSONEncoder = SocketConnection.makeEncoder()) throws {
        var frame = try encoder.encode(value)
        guard frame.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
        frame.append(0x0a)
        try send(bytes: frame)
    }

    public func send(bytes: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { throw SocketError.closed }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let n = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("send", errno)
                }
                if n == 0 { throw SocketError.closed }
                offset += n
            }
        }
    }

    /// Returns nil on clean peer EOF. A frame without its terminating newline is rejected.
    public func receiveFrame(timeout: TimeInterval? = nil) throws -> Data? {
        readLock.lock(); defer { readLock.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let newline = pending.firstIndex(of: 0x0a) {
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard frame.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
                return frame
            }
            guard pending.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw SocketError.timedOut }
                var pfd = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ms = Int32(min(Double(Int32.max), max(1, remaining * 1_000)))
                let result = Darwin.poll(&pfd, 1, ms)
                if result == 0 { throw SocketError.timedOut }
                if result < 0 { if errno == EINTR { continue }; throw SocketError.system("poll", errno) }
            }
            var scratch = [UInt8](repeating: 0, count: 16 * 1024)
            let n = Darwin.recv(descriptor, &scratch, scratch.count, 0)
            if n == 0 {
                if pending.isEmpty { return nil }
                throw SocketError.truncatedFrame
            }
            if n < 0 {
                if errno == EINTR { continue }
                if closed { return nil }
                throw SocketError.system("recv", errno)
            }
            pending.append(contentsOf: scratch[..<n])
        }
    }

    public func receive<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder(), timeout: TimeInterval? = nil) throws -> T? {
        guard let frame = try receiveFrame(timeout: timeout) else { return nil }
        return try decoder.decode(type, from: frame)
    }

    public func close() {
        stateLock.lock()
        let shouldClose = !isClosed
        isClosed = true
        stateLock.unlock()
        if shouldClose {
            _ = shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
    }

    private var closed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isClosed
    }

    deinit { close() }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum SocketError: Error, LocalizedError {
    case pathTooLong
    case frameTooLarge
    case truncatedFrame
    case timedOut
    case closed
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "PipePlot socket path is too long"
        case .frameTooLarge: return "PipePlot IPC frame exceeds 1 MiB"
        case .truncatedFrame: return "PipePlot IPC connection ended in the middle of a frame"
        case .timedOut: return "PipePlot IPC handshake timed out"
        case .closed: return "PipePlot IPC connection is closed"
        case let .system(operation, code): return "Unix socket \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Accepts connections on a per-client queue. The handler owns the accepted
/// connection and normally runs a receive loop until EOF or a protocol error.
public final class UnixSocketServer {
    /// Maximum number of simultaneous accepted connections. Excess clients are
    /// closed immediately so an unbounded number of idle peers cannot consume
    /// one worker and descriptor each.
    public static let maximumClients = 64
    private let clientLimit: Int
    public let socketURL: URL
    private let handler: (SocketConnection) -> Void
    private let queue = DispatchQueue(label: "PipePlot.UnixSocketServer", qos: .utility)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    private var clients: [ObjectIdentifier: SocketConnection] = [:]
    private var ownsSocketPath = false

    public init(socketURL: URL = PipePlotLocations.socketURL, maximumClients: Int = UnixSocketServer.maximumClients, handler: @escaping (SocketConnection) -> Void) {
        self.socketURL = socketURL
        self.clientLimit = max(1, maximumClients)
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = socketURL.path
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < pathCapacity else { throw SocketError.pathTooLong }
        var previous = stat()
        if lstat(path, &previous) == 0 {
            // Do not unlink a live server's endpoint. A socket left by a crash
            // refuses connections and can safely be replaced.
            if let active = try? PipePlotLocations.connect(socketURL: socketURL, timeout: 0.12) {
                active.close()
                throw SocketError.system("bind (another PipePlot app is already listening)", EADDRINUSE)
            }
            _ = unlink(path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                target.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dest in
                    _ = strlcpy(dest, source, pathCapacity)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bindResult == 0 else { let code = errno; Darwin.close(fd); throw SocketError.system("bind", code) }
        _ = chmod(path, mode_t(S_IRUSR | S_IWUSR))
        guard Darwin.listen(fd, 32) == 0 else { let code = errno; Darwin.close(fd); unlink(path); throw SocketError.system("listen", code) }
        listener = fd
        stopped = false
        ownsSocketPath = true
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        stopped = true
        let removeSocketPath = ownsSocketPath
        ownsSocketPath = false
        let activeClients = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR); _ = Darwin.close(fd) }
        activeClients.forEach { $0.close() }
        if removeSocketPath { _ = unlink(socketURL.path) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                lock.lock(); let shouldStop = stopped || listener != fd; lock.unlock()
                if shouldStop { return }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            let connection = SocketConnection(descriptor: client)
            lock.lock()
            let acceptClient = !stopped && listener == fd
            let belowClientLimit = clients.count < clientLimit
            if acceptClient && belowClientLimit { clients[ObjectIdentifier(connection)] = connection }
            lock.unlock()
            guard acceptClient else { connection.close(); return }
            guard belowClientLimit else { connection.close(); continue }
            DispatchQueue.global(qos: .utility).async { [weak self, handler] in
                defer {
                    connection.close()
                    if let self {
                        self.lock.lock()
                        self.clients.removeValue(forKey: ObjectIdentifier(connection))
                        self.lock.unlock()
                    }
                }
                handler(connection)
            }
        }
    }

    deinit { stop() }
}

public enum PipePlotLocations {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PipePlot", isDirectory: true)
    }
    public static var socketURL: URL { supportDirectory.appendingPathComponent("pipeplot.sock") }
    public static var lockURL: URL { supportDirectory.appendingPathComponent("app.lock") }
    public static var appURL: URL {
        let fm = FileManager.default
        let candidates = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PipePlot.app"),
            URL(fileURLWithPath: "/Applications/PipePlot.app"),
            URL(fileURLWithPath: "/System/Applications/PipePlot.app")
        ]
        return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
    }

    /// Launch the locally installed app without activating its windows.
    public static func launchInstalledApp() throws {
        let app = appURL
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw NSError(domain: "PipePlot", code: 1, userInfo: [NSLocalizedDescriptionKey: "PipePlot.app is not installed. Run the repository install script first."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", app.path, "--args", "--pipeplot-launched-by-cli"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PipePlot", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Could not launch PipePlot.app"])
        }
    }

    /// Wait briefly for a launched or already-running app to create its socket.
    public static func connect(timeout: TimeInterval = 12) throws -> SocketConnection {
        try connect(socketURL: socketURL, timeout: timeout)
    }

    public static func connect(socketURL: URL, timeout: TimeInterval = 12) throws -> SocketConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = 0
        while Date() < deadline {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError.system("socket", errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = socketURL.path
            let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            guard path.utf8.count < pathCapacity else { Darwin.close(fd); throw SocketError.pathTooLong }
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { target in
                    target.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { _ = strlcpy($0, source, pathCapacity) }
                }
            }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result == 0 { return SocketConnection(descriptor: fd) }
            lastError = errno
            Darwin.close(fd)
            Thread.sleep(forTimeInterval: 0.08)
        }
        throw SocketError.system("connect", lastError)
    }
}
