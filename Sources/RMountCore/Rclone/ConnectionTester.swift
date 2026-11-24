import Foundation

public struct ConnectionTestResult: Equatable {
    public let ok: Bool
    public let message: String
    /// rclone's own last lines of output for a failure, for diagnostics ("" otherwise).
    public let detail: String

    public init(ok: Bool, message: String, detail: String = "") {
        self.ok = ok
        self.message = message
        self.detail = detail
    }

    public static func success(_ message: String) -> ConnectionTestResult { .init(ok: true, message: message) }
    public static func failure(_ message: String, detail: String = "") -> ConnectionTestResult {
        .init(ok: false, message: message, detail: detail)
    }
}

/// "Test connection": lists the remote's folder with rclone before anything is saved or
/// mounted, and turns rclone's error into a readable message.
public enum ConnectionTester {
    /// Runs `rclone lsf` against `r:<remotePath>` using a throw-away config.
    public static func run(
        binary: URL, configText: String, remotePath: String, env: [String: String],
        timeout: TimeInterval = 30
    ) -> ConnectionTestResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmount-test-\(UUID().uuidString)", isDirectory: true)
        let config = dir.appendingPathComponent("rclone.conf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try configText.write(to: config, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Could not prepare the test: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable: binary,
                arguments: [
                    "lsf", "\(RcloneConfigBuilder.sectionName):\(remotePath)",
                    "--config", config.path, "--max-depth", "1",
                    "--contimeout", "15s", "--timeout", "20s", "--retries", "1", "--low-level-retries", "1",
                ],
                environment: environment,
                timeout: timeout)
        } catch { return .failure("Could not start rclone: \(error.localizedDescription)") }

        if result.timedOut { return .failure("The server did not answer in time — check host, port and network.") }
        if result.status == 0 {
            let count = result.stdoutString
                .split(separator: "\n", omittingEmptySubsequences: true).count
            return .success(count == 0 ? "Connected (the folder is empty)"
                                       : "Connected — \(count) item\(count == 1 ? "" : "s") found")
        }
        let stderr = result.stderrString
        let detail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(3).joined(separator: "\n")
        return .failure(explain(stderr: stderr), detail: detail)
    }

    /// Maps rclone's error output to something a person can act on.
    public static func explain(stderr: String) -> String {
        let text = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("unable to authenticate", "permission denied (", "login incorrect", "authentication failed",
               "invalidaccesskeyid", "signaturedoesnotmatch", "accessdenied", "access denied", "unauthorized",
               "invalid_grant", "invalid credentials", "bad credentials", "logon_failure", "logon failure", "attempted logon is invalid", "bad username or authentication") {
            return "Authentication failed — check the user, password, key or token."
        }
        if has("certificate", "x509") {
            return "TLS certificate problem — the server's certificate is not trusted."
        }
        if has("no such host", "connection refused", "i/o timeout", "network is unreachable",
               "no route to host", "dial tcp", "context deadline exceeded") {
            return "Could not reach the server — check the host, port and network."
        }
        if has("directory not found", "nosuchbucket", "no such file", "object not found",
               "bucket not found", "couldn't find", "404 not found",
               "bad_network_name", "network name") {
            return "Folder or bucket not found — check the path."
        }
        let tail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(2).joined(separator: "\n")
        return tail.isEmpty ? "The connection test failed." : "The connection test failed:\n\(tail)"
    }
}
