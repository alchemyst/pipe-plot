import Foundation
import Darwin
import PipePlotTransport

/// One shell process at a time, with stdout drained without blocking the IPC loop.
final class WatchSampler {
    private let command: String
    private let interval: TimeInterval
    private var pid: pid_t = 0
    private var output: Int32 = -1
    private var nextStart = Date.distantPast
    private var lastByte: UInt8?
    private var childStatus: Int32?

    init(command: String, interval: TimeInterval) {
        self.command = command
        self.interval = interval
    }

    func next() throws -> Data? {
        if pid == 0 {
            guard Date() >= nextStart else { return nil }
            try start()
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(output, &buffer, buffer.count)
        if count > 0 {
            lastByte = buffer[count - 1]
            return Data(buffer[..<count])
        }
        if count < 0 && errno != EAGAIN && errno != EINTR {
            throw SocketError.system("read watched command", errno)
        }
        if childStatus == nil {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { childStatus = status }
            else if result < 0 && errno != EINTR { throw SocketError.system("wait for watched command", errno) }
        }
        // EOF is needed as well as exit: a descendant can still hold stdout open.
        guard count == 0, let status = childStatus else { return nil }
        Darwin.close(output); output = -1
        pid = 0; childStatus = nil
        guard status == 0 else { throw WatchError.failed(status: status) }
        nextStart = Date().addingTimeInterval(interval)
        if let lastByte, lastByte != 10 { self.lastByte = nil; return Data([10]) }
        lastByte = nil
        return nil
    }

    private func start() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SocketError.system("create watch pipe", errno) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = [strdup("sh"), strdup("-c"), strdup(command), nil]
        defer { for arg in arguments { free(arg) } }
        var argv = arguments
        var child: pid_t = 0
        let result = posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, environ)
        Darwin.close(fds[1])
        guard result == 0 else { Darwin.close(fds[0]); throw SocketError.system("start watched command", result) }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        pid = child; output = fds[0]
    }

    func stop() {
        if pid != 0 {
            // The shell and its descendants run in their own process group.
            _ = kill(-pid, SIGKILL)
            if childStatus == nil { while waitpid(pid, nil, 0) < 0 && errno == EINTR {} }
            pid = 0
        }
        if output >= 0 { Darwin.close(output); output = -1 }
    }

    deinit { stop() }
}

enum WatchError: LocalizedError {
    case failed(status: Int32)
    var errorDescription: String? {
        switch self {
        case .failed(let status):
            if status & 0x7f == 0 { return "watched command exited with status \((status >> 8) & 0xff)" }
            return "watched command terminated by signal \(status & 0x7f)"
        }
    }
}
