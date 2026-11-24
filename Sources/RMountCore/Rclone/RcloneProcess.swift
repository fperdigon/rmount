import Foundation
import Darwin

public final class RcloneProcess {
    public struct Spawned {
        public let process: Process
        public let port: Int
        public let user: String
        public let password: String
        public let rcPort: Int
        public let rcUser: String
        public let rcPassword: String
        /// The temporary rclone config; rclone may rewrite it (e.g. refreshed OAuth tokens).
        public let configURL: URL
    }

    public enum SpawnError: Error {
        case failedToWriteConfig(Error)
        case noFreePort
        case launchFailed(Error)
    }

    private let binary: URL
    private let logFile: URL

    public init(binary: URL, logFile: URL) {
        self.binary = binary
        self.logFile = logFile
    }

    /// Writes `configText` to a temp file, picks a free localhost port, generates random local creds,
    /// and starts `rclone serve webdav <remoteName>:<remotePath> --addr 127.0.0.1:<port> `, credentials in RCLONE_USER/RCLONE_PASS.
    /// `passwordEnvValue` (if non-nil) is set as `passwordEnvName` for the child so rclone can use it for SFTP auth.
    public func spawnWebDAVServe(
        remoteName: String,
        remotePath: String,
        configText: String,
        baseurl: String,
        liveUpdates: Bool,
        tuning: TransferTuning = .defaults(for: .webdav),
        envOverrides: [String: String] = [:],
        extraArgs: [String] = []
    ) throws -> Spawned {
        let extra = ["--baseurl", baseurl] + tuning.serveArgs(liveUpdates: liveUpdates) + extraArgs
        return try spawn(
            serveSubcommand: "webdav",
            extraServeArgs: extra,
            remoteName: remoteName,
            remotePath: remotePath,
            configText: configText,
            envOverrides: envOverrides,
            includeAuth: true
        )
    }

    /// Spawns `rclone serve nfs <remote>:<path> --addr 127.0.0.1:<port>`.
    /// NFS does not use HTTP basic auth; the returned `user`/`password` are blanks.
    public func spawnNFSServe(
        remoteName: String,
        remotePath: String,
        configText: String,
        liveUpdates: Bool,
        tuning: TransferTuning = .defaults(for: .nfs),
        envOverrides: [String: String] = [:],
        extraArgs: [String] = []
    ) throws -> Spawned {
        let extra = tuning.serveArgs(liveUpdates: liveUpdates) + extraArgs
        return try spawn(
            serveSubcommand: "nfs",
            extraServeArgs: extra,
            remoteName: remoteName,
            remotePath: remotePath,
            configText: configText,
            envOverrides: envOverrides,
            includeAuth: false
        )
    }

    private func spawn(
        serveSubcommand: String,
        extraServeArgs: [String],
        remoteName: String,
        remotePath: String,
        configText: String,
        envOverrides: [String: String],
        includeAuth: Bool
    ) throws -> Spawned {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(TempNaming.rclonePrefix + TempNaming.tag + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configURL = tmpDir.appendingPathComponent("rclone.conf")
        // Anything that throws from here on must not leave the temp dir (config) behind.
        do {
            return try spawnPrepared(serveSubcommand: serveSubcommand, extraServeArgs: extraServeArgs,
                remoteName: remoteName, remotePath: remotePath, configText: configText,
                configURL: configURL, envOverrides: envOverrides, includeAuth: includeAuth)
        } catch {
            try? FileManager.default.removeItem(at: tmpDir)
            throw error
        }
    }

    private func spawnPrepared(
        serveSubcommand: String,
        extraServeArgs: [String],
        remoteName: String,
        remotePath: String,
        configText: String,
        configURL: URL,
        envOverrides: [String: String],
        includeAuth: Bool
    ) throws -> Spawned {
        do { try configText.write(to: configURL, atomically: true, encoding: .utf8) }
        catch { throw SpawnError.failedToWriteConfig(error) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let port = try Self.findFreePort()
        var rcPort = try Self.findFreePort()
        while rcPort == port { rcPort = try Self.findFreePort() }
        let rcUser = "rmount-\(UUID().uuidString)"
        let rcPassword = UUID().uuidString
        let user = includeAuth ? "rmount-\(UUID().uuidString.prefix(8))" : ""
        let password = includeAuth ? UUID().uuidString : ""

        let process = Process()
        process.executableURL = binary
        var args: [String] = [
            "serve", serveSubcommand,
            "\(remoteName):\(remotePath)",
            "--config", configURL.path,
            "--addr", "127.0.0.1:\(port)",
            "--rc", "--rc-addr", "127.0.0.1:\(rcPort)",
        ]
        args.append(contentsOf: extraServeArgs)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in envOverrides { env[k] = v }
        env["RCLONE_RC_USER"] = rcUser
        env["RCLONE_RC_PASS"] = rcPassword
        // The serve credentials go through the environment, never argv (`ps` shows argv to other users).
        if includeAuth {
            env["RCLONE_USER"] = user
            env["RCLONE_PASS"] = password
        }
        process.environment = env

        LogArchive.rotate(current: logFile)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = logHandle
        process.standardError = logHandle
        // The child owns its own duplicate of the descriptor; the parent's copy is closed
        // on success and on failure so it does not leak once per spawn.
        defer { try? logHandle.close() }

        do { try process.run() }
        catch { throw SpawnError.launchFailed(error) }

        return Spawned(process: process, port: port, user: user, password: password, rcPort: rcPort, rcUser: rcUser, rcPassword: rcPassword, configURL: configURL)
    }

    /// Runs `rclone obscure -` with the plaintext on stdin (never argv, which other users can read
    /// with `ps`) and returns the obscured form. rclone's env-var override for a password expects
    /// the obscured form (the same one used in config files); passing plaintext makes rclone fail
    /// with "input too short when revealing password". Throws if rclone fails or prints nothing.
    /// rclone reads only the first line of stdin, so a secret containing a newline is truncated.
    public static func obscure(plaintext: String, binary: URL) throws -> String {
        let r = try ProcessRunner.run(
            executable: binary, arguments: ["obscure", "-"], stdin: Data((plaintext + "\n").utf8), timeout: 30)
        let result = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !result.isEmpty else {
            throw ObscureError.failed(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    public enum ObscureError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let m) = self { return m.isEmpty ? "rclone obscure failed" : m }
            return nil
        }
    }

    public enum RevealError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let m) = self { return m.isEmpty ? "rclone reveal failed" : m }
            return nil
        }
    }

    /// Runs `rclone reveal <obscured>` and returns the plaintext (the inverse of `obscure`).
    /// `reveal` has no stdin form, so the obscured value (reversible with rclone's public key) is
    /// briefly visible in argv; it is only used when importing an rclone.conf.
    public static func reveal(obscured: String, binary: URL) throws -> String {
        let r = try ProcessRunner.run(executable: binary, arguments: ["reveal", obscured], timeout: 30)
        guard r.status == 0 else {
            throw RevealError.failed(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdoutString.trimmingCharacters(in: .newlines)
    }

    private static func findFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SpawnError.noFreePort }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SpawnError.noFreePort }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard getResult == 0 else { throw SpawnError.noFreePort }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Names of the temporary items RMount puts in `$TMPDIR`. They carry the app's bundle id so
/// that rmount, rmount-lite or two builds running together never sweep each other's items.
public enum TempNaming {
    public static let rclonePrefix = "rmount-rclone-"
    public static let keyPrefix = "rmount-key-"
    public static let tag: String = Bundle.main.bundleIdentifier ?? "app"
    public static func keyName(remoteID: UUID) -> String { "\(keyPrefix)\(tag)-\(remoteID.uuidString)" }
}
