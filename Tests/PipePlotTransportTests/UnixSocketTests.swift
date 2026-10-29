import Foundation
import Darwin
import XCTest
@testable import PipePlotTransport

final class UnixSocketTests: XCTestCase {
    func testOversizedFrameIsRejected() throws {
        let path = temporarySocketPath()
        let rejected = expectation(description: "oversized frame rejected")
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                _ = try connection.receiveFrame()
                XCTFail("Expected an oversized frame")
            } catch {
                guard let socketError = error as? SocketError, case .frameTooLarge = socketError else {
                    XCTFail("Expected frameTooLarge, got \(error)")
                    rejected.fulfill()
                    return
                }
                rejected.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        let bytes = Data(repeating: 0x61, count: SocketConnection.maximumFrameBytes + 1) + Data([0x0a])
        try send(bytes, on: fd)
        wait(for: [rejected], timeout: 3)
    }

    func testTruncatedFrameIsRejected() throws {
        let path = temporarySocketPath()
        let received = expectation(description: "truncated frame reported")
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                _ = try connection.receiveFrame()
                XCTFail("Expected a truncated frame")
            } catch SocketError.truncatedFrame {
                received.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        try send(Data("{\"partial\"".utf8), on: fd)
        _ = Darwin.shutdown(fd, SHUT_WR)
        Darwin.close(fd)
        wait(for: [received], timeout: 3)
    }

    func testConcurrentClientsAreServed() throws {
        let path = temporarySocketPath()
        let clientCount = 16
        let allReceived = expectation(description: "all concurrent clients served")
        allReceived.expectedFulfillmentCount = clientCount
        let lock = NSLock()
        var received = 0
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                if try connection.receiveFrame() == Data("client\n".dropLast().utf8) {
                    lock.lock(); received += 1; lock.unlock()
                    allReceived.fulfill()
                }
            } catch { XCTFail("Client failed: \(error)") }
        }
        try server.start()
        defer { server.stop() }
        let clients = try (0..<clientCount).map { _ -> Int32 in
            let fd = try connect(path)
            try send(Data("client\n".utf8), on: fd)
            return fd
        }
        clients.forEach { Darwin.close($0) }
        wait(for: [allReceived], timeout: 5)
        lock.lock(); let total = received; lock.unlock()
        XCTAssertEqual(total, clientCount)
    }

    func testStopClosesActiveClientsAndUnlinksSocket() throws {
        let path = temporarySocketPath()
        let accepted = expectation(description: "client accepted")
        let returned = expectation(description: "blocked receive released")
        let server = UnixSocketServer(socketURL: path) { connection in
            accepted.fulfill()
            do {
                _ = try connection.receiveFrame()
                returned.fulfill()
            } catch SocketError.closed {
                returned.fulfill()
            } catch {
                returned.fulfill()
            }
        }
        try server.start()
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        wait(for: [accepted], timeout: 3)
        server.stop()
        wait(for: [returned], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func temporarySocketPath() -> URL {
        URL(fileURLWithPath: "/tmp/pp-\(UUID().uuidString).sock")
    }

    private func connect(_ url: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("test socket", errno) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = url.path
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else { throw SocketError.pathTooLong }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                target.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, source, capacity) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let code = errno; Darwin.close(fd); throw SocketError.system("test connect", code) }
        return fd
    }

    private func send(_ data: Data, on fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("test send", errno)
                }
                offset += count
            }
        }
    }
}
