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

    func testReceiveDeadlineBoundsAnIdleHandshake() throws {
        let path = temporarySocketPath()
        let timedOut = expectation(description: "idle handshake timed out")
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                _ = try connection.receiveFrame(timeout: 0.05)
                XCTFail("Expected the idle handshake deadline")
            } catch SocketError.timedOut {
                timedOut.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        wait(for: [timedOut], timeout: 3)
    }

    func testReceiveDeadlineAlsoBoundsAPartialFrame() throws {
        let path = temporarySocketPath()
        let timedOut = expectation(description: "partial handshake timed out")
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                _ = try connection.receiveFrame(timeout: 0.08)
                XCTFail("Expected the partial-frame deadline")
            } catch SocketError.timedOut {
                timedOut.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        try send(Data("{\"partial\"".utf8), on: fd)
        wait(for: [timedOut], timeout: 3)
    }

    func testSendDeadlineBoundsAClientThatStopsReading() throws {
        let path = temporarySocketPath()
        let accepted = expectation(description: "client accepted")
        let timedOut = expectation(description: "blocked send timed out")
        let server = UnixSocketServer(socketURL: path) { connection in
            accepted.fulfill()
            var sendBuffer: Int32 = 1_024
            try? connection.withFileDescriptor { fd in
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
            }
            do {
                try connection.send(bytes: Data(repeating: 0x61, count: 64 * 1_024 * 1_024), timeout: 0.1)
                XCTFail("Expected the non-reading peer deadline")
            } catch SocketError.timedOut {
                timedOut.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        wait(for: [accepted], timeout: 3)
        wait(for: [timedOut], timeout: 3)
    }

    func testServerClosesConnectionsAboveClientLimit() throws {
        let path = temporarySocketPath()
        let capacityReached = expectation(description: "client limit reached")
        let clientLimit = 2
        capacityReached.expectedFulfillmentCount = clientLimit
        let server = UnixSocketServer(socketURL: path, maximumClients: clientLimit) { connection in
            capacityReached.fulfill()
            _ = try? connection.receiveFrame()
        }
        try server.start()
        defer { server.stop() }
        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        for _ in 0..<clientLimit { clients.append(try connect(path)) }
        wait(for: [capacityReached], timeout: 5)

        let overflow = try connect(path)
        defer { Darwin.close(overflow) }
        var byte: UInt8 = 0
        let count = Darwin.recv(overflow, &byte, 1, 0)
        XCTAssertEqual(count, 0, "the first client over the cap should be closed")
    }

    func testConcurrentClientsAreServed() throws {
        let path = temporarySocketPath()
        let clientCount = 16
        let allReceived = expectation(description: "all concurrent clients served")
        allReceived.expectedFulfillmentCount = clientCount
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                if try connection.receiveFrame() == Data("client\n".dropLast().utf8) {
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

    func testConnectionLeaseSurvivesConcurrentRepeatedCloseWithoutDescriptorReuse() throws {
        let path = temporarySocketPath()
        let checked = expectation(description: "descriptor remains leased through close")
        let server = UnixSocketServer(socketURL: path) { connection in
            do {
                let held = try connection.withFileDescriptor { held in
                    let closed = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        for _ in 0..<8 { connection.close() }
                        closed.signal()
                    }
                    XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
                    let replacement = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                    XCTAssertGreaterThanOrEqual(replacement, 0)
                    if replacement >= 0 {
                        XCTAssertNotEqual(replacement, held)
                        Darwin.close(replacement)
                    }
                    XCTAssertGreaterThanOrEqual(fcntl(held, F_GETFD), 0)
                    return held
                }
                XCTAssertEqual(fcntl(held, F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
                XCTAssertThrowsError(try connection.withFileDescriptor { _ in }) { error in
                    guard case SocketError.closed = error else {
                        XCTFail("Expected closed, got \(error)")
                        return
                    }
                }
            } catch { XCTFail("Unexpected lease error: \(error)") }
            checked.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        wait(for: [checked], timeout: 3)
    }

    func testConcurrentCloseUnblocksBlockedSendAndReceive() throws {
        let path = temporarySocketPath()
        let sendStarted = expectation(description: "send worker started")
        let sendReturned = expectation(description: "send worker returned")
        let receiveStarted = expectation(description: "receive worker started")
        let receiveReturned = expectation(description: "receive worker returned")
        let server = UnixSocketServer(socketURL: path) { connection in
            var sendBuffer: Int32 = 1_024
            try? connection.withFileDescriptor { fd in
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
            }
            sendStarted.fulfill()
            do {
                try connection.send(bytes: Data(repeating: 0x61, count: 16 * 1_024 * 1_024), timeout: 5)
                XCTFail("Non-reading peer unexpectedly consumed the full send")
            } catch { sendReturned.fulfill() }
        }
        try server.start()
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        wait(for: [sendStarted], timeout: 3)
        Thread.sleep(forTimeInterval: 0.05)
        server.stop()
        wait(for: [sendReturned], timeout: 2)

        let secondPath = temporarySocketPath()
        let receiver = UnixSocketServer(socketURL: secondPath) { connection in
            receiveStarted.fulfill()
            _ = try? connection.receiveFrame()
            receiveReturned.fulfill()
        }
        try receiver.start()
        let secondFD = try connect(secondPath)
        defer { Darwin.close(secondFD) }
        wait(for: [receiveStarted], timeout: 3)
        receiver.stop()
        wait(for: [receiveReturned], timeout: 2)
    }

    func testListenerCanRapidlyStopAndRestartWithoutReusingActiveAcceptDescriptor() throws {
        let path = temporarySocketPath()
        let received = DispatchSemaphore(value: 0)
        let server = UnixSocketServer(socketURL: path) { connection in
            _ = try? connection.receiveFrame(timeout: 1)
            received.signal()
        }
        defer { server.stop() }
        for _ in 0..<6 {
            try server.start()
            let fd = try connect(path)
            try send(Data("ping\n".utf8), on: fd)
            Darwin.close(fd)
            XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testConnectRetryUsesBoundedMonotonicBudget() {
        let path = temporarySocketPath()
        let clock = ContinuousClock()
        let start = clock.now
        XCTAssertThrowsError(try PipePlotLocations.connect(socketURL: path, timeout: 0.08))
        let elapsed = start.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(40))
        XCTAssertLessThan(elapsed, .seconds(1))
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
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system("test connect", code)
        }
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
