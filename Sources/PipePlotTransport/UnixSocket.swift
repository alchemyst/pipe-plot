import Foundation
import Darwin

private struct MonotonicDeadline {
    private let clock = ContinuousClock()
    private let end: ContinuousClock.Instant

    init(after seconds: TimeInterval) {
        let clock = ContinuousClock()
        self.end = clock.now.advanced(by: .seconds(max(0, seconds)))
    }

    var remaining: TimeInterval {
        let value = clock.now.duration(to: end).components
        return max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }
}

/// A bounded, newline-delimited JSON stream over a local Unix domain socket.
/// `stateLock` guards close and descriptor leases; the descriptor is shut down
/// once, then closed only after every lease drains. `readLock` owns `pending`,
/// and `writeLock` serializes writes and their socket timeout option. No other
/// mutable state escapes these locks.
public final class SocketConnection: @unchecked Sendable {
    public static let maximumFrameBytes = 1_048_576

    private let descriptor: Int32
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pending = Data()
    private var isClosed = false
    private var activeLeases = 0

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The descriptor remains owned for this synchronous operation, including
    /// a blocking poll. Never retain or close the raw value outside the closure.
    public func withFileDescriptor<T>(_ operation: (Int32) throws -> T) throws -> T {
        let fd = try leaseDescriptor()
        defer { releaseDescriptor() }
        return try operation(fd)
    }

    private func leaseDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { throw SocketError.closed }
        activeLeases += 1
        return descriptor
    }

    private func releaseDescriptor() {
        stateLock.lock()
        activeLeases -= 1
        if isClosed && activeLeases == 0 { _ = Darwin.close(descriptor) }
        stateLock.unlock()
    }

    public func send<T: Encodable>(
        _ value: T, encoder: JSONEncoder = SocketConnection.makeEncoder(), timeout: TimeInterval? = nil
    ) throws {
        var frame = try encoder.encode(value)
        guard frame.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
        frame.append(0x0a)
        try send(bytes: frame, timeout: timeout)
    }

    /// Sends all bytes, optionally bounding the entire write even when the peer
    /// stops reading. The default remains blocking for quiet, healthy peers.
    public func send(bytes: Data, timeout: TimeInterval? = nil) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let descriptor = try leaseDescriptor()
        defer { releaseDescriptor() }
        let deadline = timeout.map { MonotonicDeadline(after: $0) }
        var previousSendTimeout = timeval()
        var previousSendTimeoutLength = socklen_t(MemoryLayout<timeval>.size)
        if deadline != nil {
            guard getsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &previousSendTimeout, &previousSendTimeoutLength) == 0
            else {
                throw SocketError.system("getsockopt send timeout", errno)
            }
        }
        defer {
            if deadline != nil {
                _ = setsockopt(
                    descriptor, SOL_SOCKET, SO_SNDTIMEO, &previousSendTimeout, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                if let deadline {
                    let remaining = deadline.remaining
                    guard remaining > 0 else { throw SocketError.timedOut }
                    var sendTimeout = timeval()
                    sendTimeout.tv_sec = numericCast(Int64(remaining))
                    sendTimeout.tv_usec = Int32((remaining - Double(sendTimeout.tv_sec)) * 1_000_000)
                    if sendTimeout.tv_sec == 0 && sendTimeout.tv_usec == 0 { sendTimeout.tv_usec = 1 }
                    guard
                        setsockopt(
                            descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
                            == 0
                    else {
                        throw SocketError.system("setsockopt send timeout", errno)
                    }
                }
                let n = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    if closed { throw SocketError.closed }
                    if let deadline, (errno == EAGAIN || errno == EWOULDBLOCK) {
                        if deadline.remaining <= 0 { throw SocketError.timedOut }
                        continue
                    }
                    throw SocketError.system("send", errno)
                }
                if n == 0 { throw SocketError.closed }
                offset += n
            }
        }
    }

    /// Returns nil on clean peer EOF. A frame without its terminating newline is rejected.
    public func receiveFrame(timeout: TimeInterval? = nil) throws -> Data? {
        readLock.lock()
        defer { readLock.unlock() }
        let descriptor = try leaseDescriptor()
        defer { releaseDescriptor() }
        let deadline = timeout.map { MonotonicDeadline(after: $0) }
        while true {
            if let newline = pending.firstIndex(of: 0x0a) {
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard frame.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
                return frame
            }
            guard pending.count <= Self.maximumFrameBytes else { throw SocketError.frameTooLarge }
            if let deadline {
                let remaining = deadline.remaining
                guard remaining > 0 else { throw SocketError.timedOut }
                var pfd = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ms = Int32(min(Double(Int32.max), max(1, remaining * 1_000)))
                let result = Darwin.poll(&pfd, 1, ms)
                if result == 0 { throw SocketError.timedOut }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("poll", errno)
                }
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

    public func receive<T: Decodable>(
        _ type: T.Type, decoder: JSONDecoder = JSONDecoder(), timeout: TimeInterval? = nil
    ) throws -> T? {
        guard let frame = try receiveFrame(timeout: timeout) else { return nil }
        return try decoder.decode(type, from: frame)
    }

    public func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        _ = shutdown(descriptor, SHUT_RDWR)
        if activeLeases == 0 { _ = Darwin.close(descriptor) }
        stateLock.unlock()
    }

    private var closed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
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
/// `lifecycleLock` serializes start/stop and socket-path ownership. `lock`
/// guards listener identity, stopped, clients, and ownsSocketPath. The accept
/// queue holds a listener lease: stop shuts it down, drains that queue, then
/// closes it, so a restarted listener cannot reuse its descriptor meanwhile.
public final class UnixSocketServer: @unchecked Sendable {
    /// Maximum number of simultaneous accepted connections. Excess clients are
    /// closed immediately so an unbounded number of idle peers cannot consume
    /// one worker and descriptor each.
    public static let maximumClients = 64
    private let clientLimit: Int
    public let socketURL: URL
    private let handler: @Sendable (SocketConnection) -> Void
    private let queue = DispatchQueue(label: "PipePlot.UnixSocketServer", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    private var clients: [ObjectIdentifier: SocketConnection] = [:]
    private var ownsSocketPath = false

    public init(
        socketURL: URL = PipePlotLocations.socketURL, maximumClients: Int = UnixSocketServer.maximumClients,
        handler: @escaping @Sendable (SocketConnection) -> Void
    ) {
        self.socketURL = socketURL
        self.clientLimit = max(1, maximumClients)
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system("bind", code)
        }
        _ = chmod(path, mode_t(S_IRUSR | S_IWUSR))
        guard Darwin.listen(fd, 32) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw SocketError.system("listen", code)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw SocketError.system("configure listener", code)
        }
        listener = fd
        stopped = false
        ownsSocketPath = true
        queue.async { [weak self] in
            while self?.acceptOne(fd) == true {}
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        let fd = listener
        listener = -1
        stopped = true
        let removeSocketPath = ownsSocketPath
        ownsSocketPath = false
        let activeClients = Array(clients.values)
        clients.removeAll()
        if fd >= 0 {
            _ = shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
        // A deinit reached between accept iterations can run on this queue.
        if DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
        if fd >= 0 { _ = Darwin.close(fd) }
        activeClients.forEach { $0.close() }
        if removeSocketPath { _ = unlink(socketURL.path) }
    }

    private func acceptOne(_ fd: Int32) -> Bool {
        lock.lock()
        let active = !stopped && listener == fd
        lock.unlock()
        guard active else { return false }
        var readiness = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let ready = Darwin.poll(&readiness, 1, 100)
        if ready == 0 { return true }
        if ready < 0 { return errno == EINTR || isListening(on: fd) }
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return isListening(on: fd)
        }
        let clientFlags = fcntl(client, F_GETFL)
        guard clientFlags >= 0, fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else {
            Darwin.close(client)
            return true
        }
        let connection = SocketConnection(descriptor: client)
        lock.lock()
        let acceptClient = !stopped && listener == fd
        let belowClientLimit = clients.count < clientLimit
        if acceptClient && belowClientLimit { clients[ObjectIdentifier(connection)] = connection }
        lock.unlock()
        guard acceptClient && belowClientLimit else {
            connection.close()
            return acceptClient
        }
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
        return true
    }

    private func isListening(on fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && listener == fd
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
            URL(fileURLWithPath: "/System/Applications/PipePlot.app"),
        ]
        return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
    }

    /// Present the locally installed app on cold launch. Ready warm connections
    /// bypass this path and never repeatedly activate the app.
    public static func launchInstalledApp() throws {
        let app = appURL
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw NSError(
                domain: "PipePlot", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "PipePlot.app is not installed. Run the repository install script first."
                ])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = [app.path, "--args", "--pipeplot-launched-by-cli"]
        if let trace = ProcessInfo.processInfo.environment["PIPEPLOT_ACCEPTANCE_TRACE"], trace.hasPrefix("/") {
            arguments += ["--acceptance-trace", trace]
        }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PipePlot", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not launch PipePlot.app"])
        }
    }

    /// Wait briefly for a launched or already-running app to create its socket.
    public static func connect(timeout: TimeInterval = 12) throws -> SocketConnection {
        try connect(socketURL: socketURL, timeout: timeout)
    }

    public static func connect(socketURL: URL, timeout: TimeInterval = 12) throws -> SocketConnection {
        let deadline = MonotonicDeadline(after: timeout)
        var lastError: Int32 = 0
        while true {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError.system("socket", errno) }
            let originalFlags = fcntl(fd, F_GETFL)
            guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw SocketError.system("configure socket", code)
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = socketURL.path
            let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            guard path.utf8.count < pathCapacity else {
                Darwin.close(fd)
                throw SocketError.pathTooLong
            }
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { target in
                    target.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                        _ = strlcpy($0, source, pathCapacity)
                    }
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            var connected = result == 0
            if !connected {
                lastError = errno
                if lastError == EINPROGRESS || lastError == EAGAIN || lastError == EWOULDBLOCK {
                    while deadline.remaining > 0 {
                        let ms = Int32(min(Double(Int32.max), max(1, deadline.remaining * 1_000)))
                        var readiness = pollfd(fd: fd, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
                        let ready = Darwin.poll(&readiness, 1, ms)
                        if ready < 0 && errno == EINTR { continue }
                        if ready <= 0 {
                            lastError = ready == 0 ? ETIMEDOUT : errno
                            break
                        }
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) < 0 {
                            lastError = errno
                        } else if socketError == 0 {
                            connected = true
                        } else {
                            lastError = socketError
                        }
                        break
                    }
                }
            }
            if connected {
                guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
                    let code = errno
                    Darwin.close(fd)
                    throw SocketError.system("configure connected socket", code)
                }
                return SocketConnection(descriptor: fd)
            }
            Darwin.close(fd)
            let remaining = deadline.remaining
            if remaining <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.08, remaining))
        }
        throw SocketError.system("connect", lastError)
    }
}
