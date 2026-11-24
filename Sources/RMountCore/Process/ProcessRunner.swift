import Foundation

/// What a finished helper process left behind.
public struct ProcessResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    /// True when the deadline passed and the process was stopped by us.
    public let timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a short-lived helper (`mount`, `diskutil`, `ssh-keyscan`, `rclone obscure`, ...) safely:
/// both pipes are drained while the process runs (so >64 KB of output cannot fill a pipe and
/// deadlock it), the wait is bounded, and a process that ignores SIGTERM gets SIGKILL.
/// Never use it for long-running servers such as `rclone serve`.
public enum ProcessRunner {
    /// - Parameters:
    ///   - environment: full child environment; `nil` inherits ours.
    ///   - mergeStderr: send stderr into the stdout pipe (`stderr` is then empty).
    ///   - timeout: seconds before SIGTERM; `nil` waits forever.
    ///   - killGrace: seconds between SIGTERM and SIGKILL.
    ///   - onStart: called with the running process (e.g. to allow cancelling it).
    public static func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval? = 30,
        killGrace: TimeInterval = 2,
        onStart: ((Process) -> Void)? = nil
    ) throws -> ProcessResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = mergeStderr ? out : err

        // Wait on a semaphore, not waitUntilExit(), which can miss its wakeup.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        // Our copy of the write ends must not stay open, or EOF never arrives.
        try? out.fileHandleForWriting.close()
        if !mergeStderr { try? err.fileHandleForWriting.close() }
        onStart?(p)

        let readers = DispatchGroup()
        let box = Buffers()
        readers.enter()
        DispatchQueue.global().async {
            box.out = out.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        if !mergeStderr {
            readers.enter()
            DispatchQueue.global().async {
                box.err = err.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }

        var timedOut = false
        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        // A grandchild can keep a pipe open after the child exits; do not wait for it forever.
        if readers.wait(timeout: .now() + 2) == .timedOut {
            try? out.fileHandleForReading.close()
            if !mergeStderr { try? err.fileHandleForReading.close() }
            _ = readers.wait(timeout: .now() + 1)
        }
        let status = p.isRunning ? SIGKILL : p.terminationStatus
        return ProcessResult(status: status, stdout: box.out, stderr: box.err, timedOut: timedOut)
    }

    private final class Buffers: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}
