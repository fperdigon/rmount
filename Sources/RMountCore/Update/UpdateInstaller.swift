import Foundation
import CryptoKit

/// Downloads an update DMG, checks it, and swaps the new app over the running one.
public enum UpdateInstaller {
    public enum InstallError: LocalizedError, Equatable {
        case downloadFailed(Int)
        case checksumMismatch
        case notWritable(String)
        case mountFailed(String)
        case appNotFound(String)
        case replaceFailed(String)
        case digestMissing
        case bundleIdentifierMismatch(expected: String?, found: String?)
        case codeSignatureInvalid(String)
        case downgrade(current: String, new: String)
        case releaseSignatureMissing
        case releaseSignatureInvalid

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let code): return "The download failed (HTTP \(code))."
            case .checksumMismatch: return "The downloaded file does not match its published checksum, so it was discarded."
            case .notWritable(let dir):
                return "RMount cannot write to \(dir). Move RMount to /Applications (or another folder you can write to) and try again."
            case .mountFailed(let m): return "Could not open the downloaded disk image: \(m)"
            case .appNotFound(let n): return "The downloaded disk image does not contain \(n)."
            case .replaceFailed(let m): return "Could not replace the installed app: \(m)"
            case .digestMissing: return "GitHub did not publish a SHA-256 checksum for this download, so it cannot be verified and was not installed."
            case .bundleIdentifierMismatch(let expected, let found):
                return "The downloaded app is not RMount (bundle id \(found ?? "missing"), expected \(expected ?? "unknown")), so it was not installed."
            case .codeSignatureInvalid(let m): return "The downloaded app's code signature is broken, so it was not installed: \(m)"
            case .downgrade(let current, let new):
                return "The downloaded app (\(new)) is older than the running one (\(current)), so it was not installed."
            case .releaseSignatureMissing: return "This release has no signature file, so it was not installed."
            case .releaseSignatureInvalid: return "The release signature does not match the download, so it was discarded."
            }
        }
    }

    // MARK: Download and verify

    /// Downloads `asset` into `directory` and returns the file URL.
    public static func download(_ asset: ReleaseAsset, to directory: URL, session: URLSession = .shared) async throws -> URL {
        var req = URLRequest(url: asset.downloadURL)
        req.setValue("rmount-updater", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await session.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw InstallError.downloadFailed(status)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `checksumMismatch` unless the file matches `expected` ("sha256:<hex>" or bare hex).
    /// A nil, empty or non-SHA-256 `expected` throws `digestMissing`: an unverifiable download is never installed.
    public static func verify(file: URL, expected: String?) throws {
        guard var want = expected?.lowercased(), !want.isEmpty else { throw InstallError.digestMissing }
        if want.hasPrefix("sha256:") { want = String(want.dropFirst(7)) }
        else if want.contains(":") { throw InstallError.digestMissing }
        guard try sha256(of: file) == want else { throw InstallError.checksumMismatch }
    }

    // MARK: Install

    /// True when the folder holding the app can be written to (needed to swap the bundle).
    public static func canReplace(_ appURL: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    /// Opens the DMG, copies `<appName>` out of it into `directory` and unmounts it.
    public static func extractApp(fromDMG dmg: URL, appName: String, into directory: URL) throws -> URL {
        try extractApp(fromDMG: dmg, into: directory) { _ in appName }
    }

    /// Like `extractApp(fromDMG:appName:into:)`, but `pick` chooses the app's name once the image
    /// is mounted (it is given the mount point).
    static func extractApp(fromDMG dmg: URL, into directory: URL, pick: (URL) -> String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("rmount-update-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else {
            try? FileManager.default.removeItem(at: mount)
            throw InstallError.mountFailed(attach.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let appName = pick(mount)
        let source = mount.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: source.path) else { throw InstallError.appNotFound(appName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(appName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Removes the download quarantine flag so Gatekeeper does not block the unsigned new build.
    public static func clearQuarantine(_ app: URL) {
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    /// Replaces `current` with `new` (same volume), keeping nothing of the old bundle.
    public static func replaceApp(at current: URL, with new: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: new)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
    }

    /// The app to take from a mounted update DMG: one named like the running app, otherwise, for a
    /// running `macsh*.app` (the old name), the matching `rmount*.app` (`macsh.app` -> `rmount.app`,
    /// `macsh-lite.app` -> `rmount-lite.app`).
    static func appName(inMountedDMG mount: URL, matching current: String) -> String {
        if FileManager.default.fileExists(atPath: mount.appendingPathComponent(current).path) { return current }
        if current.hasPrefix(LegacyNames.assetPrefix) {
            let renamed = "rmount" + current.dropFirst(LegacyNames.assetPrefix.count)
            if FileManager.default.fileExists(atPath: mount.appendingPathComponent(renamed).path) { return renamed }
        }
        return current
    }

    /// Verifies the DMG and installs the app it contains over `current`. The new copy is staged
    /// next to the old one so the swap never crosses volumes. Does not relaunch.
    ///
    /// Returns where the new app now is: `current`, or, when the DMG's app has another name
    /// (macsh.app updated to rmount.app), a sibling with the new name, with the old bundle moved
    /// to the Trash.
    @discardableResult
    ///
    /// Before anything is mounted the digest must match (and the Ed25519 release signature, when
    /// `releaseKey` is given). Before the swap the staged app must have RMount's bundle id, a valid
    /// code signature and, on the stable channel, not be older than the running app.
    public static func install(dmg: URL, expectedDigest: String?, over current: URL,
                               channel: UpdateChannel = .stable,
                               releaseKey: Data? = nil, releaseSignature: Data? = nil) throws -> URL {
        try verify(file: dmg, expected: expectedDigest)
        if let releaseKey {
            try UpdateSignature.verify(file: dmg, signature: releaseSignature, publicKey: releaseKey)
        }
        guard canReplace(current) else {
            throw InstallError.notWritable(current.deletingLastPathComponent().path)
        }
        let staging = current.deletingLastPathComponent().appendingPathComponent(".rmount-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = try extractApp(fromDMG: dmg, into: staging) { appName(inMountedDMG: $0, matching: current.lastPathComponent) }
        try verifyStaged(staged, replacing: current, channel: channel)
        clearQuarantine(staged)
        guard staged.lastPathComponent != current.lastPathComponent else {
            try replaceApp(at: current, with: staged)
            return current
        }
        let target = current.deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try replaceApp(at: target, with: staged)
        } else {
            do { try FileManager.default.moveItem(at: staged, to: target) }
            catch { throw InstallError.replaceFailed(error.localizedDescription) }
        }
        try? FileManager.default.trashItem(at: current, resultingItemURL: nil)
        return target
    }

    /// Checks the extracted app before it replaces `current`: same bundle id (the `ai.macsh` ids
    /// map to their `ai.rmount` successors), `codesign --verify --deep --strict` passes, and on the
    /// stable channel the version is not lower than the running one.
    static func verifyStaged(_ staged: URL, replacing current: URL, channel: UpdateChannel) throws {
        let new = Bundle(url: staged)?.infoDictionary
        let old = Bundle(url: current)?.infoDictionary
        let expectedID = old?["CFBundleIdentifier"] as? String
        let foundID = new?["CFBundleIdentifier"] as? String
        var allowed = Set<String>()
        if let expectedID {
            allowed.insert(expectedID)
            if expectedID.hasPrefix(LegacyNames.bundleIDPrefix) {
                allowed.insert(LegacyNames.currentBundleIDPrefix + expectedID.dropFirst(LegacyNames.bundleIDPrefix.count))
            }
        }
        guard let foundID, allowed.contains(foundID) else {
            throw InstallError.bundleIdentifierMismatch(expected: expectedID, found: foundID)
        }
        let seal = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        guard seal.status == 0 else {
            throw InstallError.codeSignatureInvalid(seal.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if channel == .stable {
            let newVersion = (new?["CFBundleShortVersionString"] as? String) ?? "0"
            let oldVersion = (old?["CFBundleShortVersionString"] as? String) ?? "0"
            if VersionCompare.compare(newVersion, oldVersion) < 0 {
                throw InstallError.downgrade(current: oldVersion, new: newVersion)
            }
        }
    }

    /// A detached process that waits for this app to quit, then opens the (new) app.
    public static func relaunchProcess(appURL: URL) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let path = appURL.path.replacingOccurrences(of: "'", with: "'\\''")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n '\(path)'"]
        return p
    }

    // MARK: Process helper

    static func run(_ exe: String, _ args: [String]) -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
