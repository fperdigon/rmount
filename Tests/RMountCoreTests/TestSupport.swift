import Foundation
import XCTest
@testable import RMountCore

/// A stand-in for the rclone binary: a python script that records its arguments and the
/// RCLONE_CONFIG_* environment, answers `obscure`, and (for `serve`) listens on `--addr`.
struct FakeRclone {
    let binary: URL
    let argsFile: URL

    static func make(in dir: URL) throws -> FakeRclone {
        let argsFile = dir.appendingPathComponent("fake-rclone-args.txt")
        let script = """
        #!/usr/bin/env python3
        import os, socket, sys, time
        args = sys.argv[1:]
        # The fake's stderr is part of what tests assert on, so debug lines go ONLY to the debug file.
        debug_file = os.environ.get("RMOUNT_TEST_DEBUG_FILE") if os.environ.get("RMOUNT_TEST_DEBUG") == "1" else None
        def debug_log(event):
            if debug_file:
                with open(debug_file, "a") as f:
                    f.write("[RMOUNT_TEST_DEBUG] time=%.6f pid=%d thread=main %s\\n" % (time.time(), os.getpid(), event))
        debug_log("fake-rclone start (arguments and environment redacted)")
        if args and args[0] == "obscure":
            if args[1] == "-":
                if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "obscure-fail.txt")):
                    sys.stderr.write("obscure exploded\\n")
                    sys.exit(1)
                print("OBS-" + sys.stdin.readline().rstrip("\\n"))
            else:
                print("OBS-" + args[1])
            sys.exit(0)
        if args and args[0] == "reveal":
            if args[1].startswith("OBS-"):
                print(args[1][4:])
                sys.exit(0)
            sys.stderr.write("Failed to reveal: input too short when revealing password\\n")
            sys.exit(1)
        here = os.path.dirname(os.path.abspath(__file__))
        if args and args[0] == "authorize":
            lines = list(args) + ["ENV:RCLONE_DRIVE_SCOPE=" + os.environ.get("RCLONE_DRIVE_SCOPE", ""), "ENV:RCLONE_DRIVE_CLIENT_ID=" + os.environ.get("RCLONE_DRIVE_CLIENT_ID", ""), "ENV:RCLONE_DRIVE_CLIENT_SECRET=" + os.environ.get("RCLONE_DRIVE_CLIENT_SECRET", "")]
            with open("\(argsFile.path)", "w") as f:
                f.write("\\n".join(lines))
            mode = open(os.path.join(here, "authorize-mode.txt")).read().strip() if os.path.exists(os.path.join(here, "authorize-mode.txt")) else "ok"
            if mode == "fail":
                sys.stderr.write("Failed to authorize: access denied\\n")
                sys.exit(1)
            if mode == "hang":
                import time
                time.sleep(60)
            print("Waiting for code...")
            print("Paste the following into your remote machine --->")
            print('{"access_token":"AT","token_type":"Bearer","refresh_token":"RT","expiry":"2030-01-01T00:00:00Z"}')
            print("<---End paste")
            sys.exit(0)
        lines = list(args)
        # Simulate rclone refreshing an OAuth token: rewrite the --config file like rclone does.
        refresh = os.path.join(here, "refresh-token.txt")
        if "serve" in args and "--config" in args and os.path.exists(refresh):
            with open(args[args.index("--config") + 1], "a") as cf:
                cf.write("token = " + open(refresh).read().strip() + "\\n")
        for k in sorted(os.environ):
            if k.startswith("RCLONE_CONFIG_") or k == "RMOUNT_TEST_ENV" or k in ("RCLONE_USER", "RCLONE_PASS"):
                lines.append("ENV:%s=%s" % (k, os.environ[k]))
        with open("\(argsFile.path)", "w") as f:
            f.write("\\n".join(lines))
        if args and args[0] == "lsf":
            mode_file = os.path.join(here, "lsf-mode.txt")
            if os.path.exists(mode_file):
                parts = open(mode_file).read().split("\\n", 1)
                code = int(parts[0])
                if code == 124:
                    time.sleep(60)
                if code != 0:
                    sys.stderr.write(parts[1] if len(parts) > 1 else "")
                    sys.exit(code)
            print("a.txt")
            print("sub/")
            sys.exit(0)
        once = os.path.join(here, "bind-fail-once.txt")
        if "--addr" in args and os.path.exists(once):
            os.remove(once)
            sys.stderr.write("Failed to start server: listen tcp 127.0.0.1:1: bind: address already in use\\n")
            sys.exit(1)
        if "--addr" in args:
            host, port = args[args.index("--addr") + 1].rsplit(":", 1)
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            debug_log("bind before address=%s:%s" % (host, port))
            s.bind((host, int(port)))
            debug_log("bind after address=%s:%s" % (host, port))
            s.listen(5)
            while True:
                c, _ = s.accept()
                c.close()
        """
        let url = dir.appendingPathComponent("fake-rclone")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return FakeRclone(binary: url, argsFile: argsFile)
    }

    static func requirePython() throws {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        if !candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            throw XCTSkip("python3 not available")
        }
    }

    /// Lines the fake wrote (args, then ENV:... lines). Waits for the script to start.
    func recordedLines(timeout: TimeInterval = 10) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: argsFile, encoding: .utf8), !text.isEmpty {
                return text.components(separatedBy: "\n")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return []
    }
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rmount-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeRemote(
    name: String = "test-remote",
    backend: Backend,
    proto: MountProtocol = .webdav,
    autoMount: Bool = false,
    liveUpdates: Bool = true
) -> Remote {
    Remote(id: UUID(), name: name, backend: backend, mountProtocol: proto,
           autoMount: autoMount, liveUpdates: liveUpdates)
}

func sftpBackend(auth: SFTPAuthKind = .password) -> Backend {
    .sftp(SFTPConfig(host: "example.com", port: 22, user: "alice", remotePath: "/data", authKind: auth))
}

func s3Backend(prefix: String = "pre") -> Backend {
    .s3(S3Config(provider: .aws, region: "us-east-1", endpoint: nil, bucket: "bkt", prefix: prefix))
}

func ftpBackend() -> Backend {
    .ftp(FTPConfig(host: "ftp.example.com", port: 21, user: "bob", remotePath: "/pub", tlsMode: .explicit))
}

func webdavBackend(remotePath: String = "docs") -> Backend {
    .rclone(BackendDescriptor.webdav.makeConfig(
        values: ["url": "https://cloud.example.com/remote.php/dav/files/bob/", "vendor": "nextcloud", "user": "bob", "pass": ""],
        remotePath: remotePath))
}

func driveBackend(remotePath: String = "", clientID: String = "") -> Backend {
    .rclone(BackendDescriptor.googleDrive.makeConfig(
        values: ["scope": "drive", "token": "", "client_id": clientID, "client_secret": ""],
        remotePath: remotePath))
}

/// Diagnostic output only: never dump environments, arbitrary argument values, or errors.
/// In particular, shell bodies and rclone obscure/reveal operands can contain secrets.
enum TestDebug {
    static let enabled = ProcessInfo.processInfo.environment["RMOUNT_TEST_DEBUG"] == "1"
    private static let lock = NSLock()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[RMOUNT_TEST_DEBUG] \(timestamp) uptime=\(ProcessInfo.processInfo.systemUptime) pid=\(ProcessInfo.processInfo.processIdentifier) thread=\(Thread.isMainThread ? "main" : "background") \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        // `swift test` relays the test process's stderr and can hold lines back when the run stalls;
        // RMOUNT_TEST_DEBUG_FILE=<path> appends each line straight to a file so nothing is lost.
        if let path = ProcessInfo.processInfo.environment["RMOUNT_TEST_DEBUG_FILE"] {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 { _ = line.withCString { write(fd, $0, strlen($0)) }; close(fd) }
        }
    }

    /// Keep known command/option names; redact every operand, including addresses.
    /// An allowlist also covers inline credentials, script bodies, and unknown options.
    static func safeArguments(_ arguments: [String]) -> [String] {
        let commands: Set<String> = ["serve", "webdav", "nfs", "obscure", "reveal", "create"]
        let options: Set<String> = [
            "--addr", "--rc", "--rc-addr", "--config", "--user", "--pass", "--baseurl",
            "--cache-dir", "--bwlimit", "--vfs-cache-mode", "--vfs-write-back",
            "--vfs-cache-max-size", "--vfs-cache-max-age", "--vfs-read-chunk-size",
            "--vfs-read-chunk-size-limit", "--buffer-size", "--dir-cache-time",
            "--vfs-fast-fingerprint", "--poll-interval", "--read-only",
            "-q", "-t", "-N", "-f", "-D", "-h", "-p", "-o", "-c",
            "-volname", "-srcfolder", "-fs", "-size", "-format", "-ov"
        ]
        var expectsValue = false
        let switches: Set<String> = ["--rc", "--vfs-fast-fingerprint", "--read-only", "-q", "-D", "-ov"]
        return arguments.enumerated().map { index, argument in
            if expectsValue {
                expectsValue = false
                return "<redacted>"
            }
            if index == 0, commands.contains(argument) {
                expectsValue = argument == "obscure" || argument == "reveal"
                return argument
            }
            if index == 1, arguments.first == "serve", ["webdav", "nfs"].contains(argument) {
                return argument
            }
            if options.contains(argument) {
                expectsValue = !switches.contains(argument)
                return argument
            }
            return "<redacted>"
        }
    }

    static func process(_ event: String, _ process: Process) {
        log("\(event) child=\(process.processIdentifier) path=\(String(reflecting: process.executableURL?.path ?? "?")) args=\(safeArguments(process.arguments ?? []))")
    }

    static func spawned(_ spawned: RcloneProcess.Spawned) {
        guard enabled else { return }
        process("spawned", spawned.process)
        log("ports child=\(spawned.process.processIdentifier) serve=127.0.0.1:\(spawned.port) rc=127.0.0.1:\(spawned.rcPort)")
    }
}

/// Use the same XCTest invocation, with a pair of diagnostic boundaries when enabled.
class DebugTestCase: XCTestCase {
    override func invokeTest() {
        TestDebug.log("test start \(name)")
        defer { TestDebug.log("test finish \(name)") }
        super.invokeTest()
    }
}

extension XCTestCase {
    func addDebugTeardownBlock(file: StaticString = #filePath, line: UInt = #line,
                               _ block: @escaping () throws -> Void) {
        guard TestDebug.enabled else { addTeardownBlock(block); return }
        let label = "\(name) \(URL(fileURLWithPath: String(describing: file)).lastPathComponent):\(line)"
        addTeardownBlock {
            TestDebug.log("teardown start \(label)")
            defer { TestDebug.log("teardown finish \(label)") }
            try block()
        }
    }

    func addDebugTeardownBlock(file: StaticString = #filePath, line: UInt = #line,
                               _ block: @escaping @Sendable () async throws -> Void) {
        guard TestDebug.enabled else { addTeardownBlock(block); return }
        let label = "\(name) \(URL(fileURLWithPath: String(describing: file)).lastPathComponent):\(line)"
        addTeardownBlock {
            TestDebug.log("teardown start \(label)")
            defer { TestDebug.log("teardown finish \(label)") }
            try await block()
        }
    }
}

extension Process {
    func debugRun() throws {
        TestDebug.process("run before", self)
        defer { TestDebug.process("run after", self) }
        try run()
    }

    func debugTerminate() {
        TestDebug.process("terminate before", self)
        defer { TestDebug.process("terminate after", self) }
        terminate()
    }

    func debugWaitUntilExit() {
        TestDebug.process("waitUntilExit before", self)
        defer { TestDebug.process("waitUntilExit after", self) }
        if TestDebug.enabled {
            // Watchdog: if the wait is still blocked after 5 s, record what Foundation and the OS say.
            let pid = processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                let alive = kill(pid, 0) == 0
                TestDebug.log("waitUntilExit STILL BLOCKED after 5s pid=\(pid) foundationIsRunning=\(self?.isRunning ?? false) osProcessExists=\(alive) errno=\(errno)")
            }
        }
        waitUntilExit()
    }
}

extension Process {
    /// Terminates the child and waits (bounded) until Foundation has observed its exit, so a test never
    /// drops a still-running `Process`. Uses polling instead of `waitUntilExit()`, which can block forever.
    func stopAndReap(timeout: TimeInterval = 10) {
        guard isRunning else { return }
        TestDebug.process("stopAndReap terminate", self)
        terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if isRunning {
            kill(processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(5)
            while isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        TestDebug.log("stopAndReap done pid=\(processIdentifier) stillRunning=\(isRunning)")
    }
}


/// Keep session tests from changing the running app's Finder extension state.
@MainActor
final class NoopFinderBadgeStatusWriter: FinderBadgeStatusWriting {
    func write(_ snapshot: FinderBadgeSnapshot) {}
    func flush(_ snapshot: FinderBadgeSnapshot) {}
}

/// In-memory `SecretStore` so SessionManager tests do not touch the real Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private func key(_ id: UUID, _ kind: SecretKind) -> String { "\(id.uuidString):\(kind.rawValue)" }
    func set(remoteID: UUID, kind: SecretKind, value: String) throws { lock.withLock { items[key(remoteID, kind)] = value } }
    func get(remoteID: UUID, kind: SecretKind) throws -> String? { lock.withLock { items[key(remoteID, kind)] } }
    func delete(remoteID: UUID, kind: SecretKind) throws { lock.withLock { _ = items.removeValue(forKey: key(remoteID, kind)) } }
}
