import Foundation
import Darwin
import NetFS

public class Mounter {
    public enum MountError: LocalizedError {
        case mountpointCreationFailed(String)
        case mountFailed(stderr: String, exitCode: Int32)
        case unmountFailed(stderr: String, exitCode: Int32)
        /// The volume is in use (open files, a Finder window); a plain unmount was refused.
        case busy(mountpoint: String)
        case netFSFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .mountpointCreationFailed(let msg):
                return "Could not create mountpoint: \(msg)"
            case .mountFailed(let stderr, let code):
                return "mount failed (exit \(code)): \(stderr.isEmpty ? "no stderr output" : stderr)"
            case .unmountFailed(let stderr, let code):
                return "unmount failed (exit \(code)): \(stderr.isEmpty ? "no stderr output" : stderr)"
            case .busy(let mp):
                return "\(mp) is in use by an app or Finder, so it was not unmounted."
            case .netFSFailed(let status):
                return "NetFS mount failed (status \(status))"
            }
        }
    }

    private let mountBase: URL
    let legacyMountBases: [URL]

    /// `mountBase` is where NFS mountpoints are created; defaults to `~/rmount`.
    /// `legacyMountBases` are old locations (`~/macsh`) that are never mounted into but are still
    /// searched for leftover mounts of a previous run; by default only when `mountBase` is too.
    public init(mountBase: URL? = nil, legacyMountBases: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.mountBase = mountBase ?? home.appendingPathComponent("rmount", isDirectory: true)
        self.legacyMountBases = legacyMountBases
            ?? (mountBase == nil ? [home.appendingPathComponent(LegacyNames.mountDirectoryName, isDirectory: true)] : [])
    }

    /// Strips characters that can't appear in a macOS volume name (`/`, `:`, NULs)
    /// but otherwise leaves the user's chosen name alone. NetFS uses the URL path as
    /// the default volume name, so the returned string becomes both the rclone
    /// `--baseurl` value and `/Volumes/<name>`.
    public func volumeName(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty ? "rmount-mount" : cleaned
    }

    /// Mounts a WebDAV server via NetFS.framework. Asks NetAuth/automountd to perform
    /// the mount, which is how Finder mounts WebDAV — no privilege escalation needed
    /// from us, and the entry appears under the system's `/Volumes/`.
    /// Returns the actual mountpoint path chosen by the system.
    public func mountWebDAV(host: String, port: Int, baseurl: String, user: String, password: String) throws -> String {
        // baseurl arrives as an unencoded path like "/My Laptop". Percent-encode for the URL.
        let pathEscaped = baseurl.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baseurl
        let urlString = "http://\(host):\(port)\(pathEscaped)"
        guard let url = URL(string: urlString) else {
            throw MountError.netFSFailed(status: -1)
        }

        let openOpts = NSMutableDictionary()
        openOpts[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        openOpts[kNetFSAllowLoopbackKey as String] = true

        let mountOpts = NSMutableDictionary()

        var mountpoints: Unmanaged<CFArray>? = nil
        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            user as CFString,
            password as CFString,
            openOpts as CFMutableDictionary,
            mountOpts as CFMutableDictionary,
            &mountpoints
        )
        if status != 0 {
            throw MountError.netFSFailed(status: status)
        }
        guard let mps = mountpoints?.takeRetainedValue() as? [String], let first = mps.first else {
            throw MountError.netFSFailed(status: -1)
        }
        return first
    }

    /// Calls `mount_nfs -o <opts> <host>:<exportPath> <mountpoint>`.
    /// Defaults: NFSv3, no root squash, locallocks, vers=3 (rclone serve nfs default).
    /// NFS still goes through the legacy exec path; NetFS supports NFS too but the URL
    /// shape and option keys differ from the WebDAV path — left as a follow-up.
    /// `timeo` is in tenths of a second: 60 s per attempt. The old 3 s made a cloud listing
    /// that takes a few seconds look like a dead server ("Server connections interrupted").
    static func nfsMountOptions(port: Int) -> String {
        "vers=3,tcp,noresvport,port=\(port),mountport=\(port),nolocks,locallocks,soft,timeo=600,retrans=2,nfc,rsize=1048576,wsize=1048576"
    }

    public func mountNFS(host: String, port: Int, exportPath: String, name: String, mountpoint: String) throws {
        let source = "\(host):\(exportPath)"
        let opts = Self.nfsMountOptions(port: port)
        try run(
            "/sbin/mount_nfs",
            args: ["-o", opts, source, mountpoint],
            failure: MountError.mountFailed
        )
    }

    /// NFS mounts go through `mount_nfs`, which runs as the user and so can't create
    /// folders in the root-owned `/Volumes`. Mount into a user-owned folder instead:
    /// `~/rmount/<name>`. A leftover empty directory from a previous mount is reused;
    /// a directory that is a live mount or has content gets a `-2`, `-3`, ... suffix.
    public func resolveMountpoint(name: String) throws -> String {
        let fm = FileManager.default
        let base = mountBase
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw MountError.mountpointCreationFailed(error.localizedDescription)
        }
        var candidate = base.appendingPathComponent(name).path
        var counter = 2
        while fm.fileExists(atPath: candidate) {
            let contents = (try? fm.contentsOfDirectory(atPath: candidate)) ?? ["?"]
            if contents.isEmpty && !isMountPoint(candidate) { return candidate }
            candidate = base.appendingPathComponent("\(name)-\(counter)").path
            counter += 1
        }
        do {
            try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false)
        } catch {
            throw MountError.mountpointCreationFailed(error.localizedDescription)
        }
        return candidate
    }

    /// True when `path` is on a different device than its parent directory.
    private func isMountPoint(_ path: String) -> Bool {
        var a = stat(), b = stat()
        let parent = (path as NSString).deletingLastPathComponent
        guard stat(path, &a) == 0, stat(parent, &b) == 0 else { return false }
        return a.st_dev != b.st_dev
    }

    /// A mount RMount created: NFS under the mount base, or WebDAV from a localhost rclone.
    public struct LocalMount: Equatable {
        public enum Kind { case nfs, webdav }
        public let path: String
        public let kind: Kind
        /// Port of the `rclone serve` behind it, when it can be determined.
        public let port: Int?
    }

    /// Parses `/sbin/mount` and `nfsstat -m` output for mounts served by a local rclone
    /// whose mountpoint is under `mountBase` (NFS) or that come from `http://127.0.0.1:<port>/`.
    /// `mount` does not show NFS ports, so those come from `nfsstat -m`.
    static func parseLocalMounts(mountOutput: String, nfsstatOutput: String, mountBase: String) -> [LocalMount] {
        var nfsPorts: [String: Int] = [:]
        var current: String?
        for line in nfsstatOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = line.range(of: " from 127.0.0.1:") {
                current = String(line[..<r.lowerBound])
            } else if let path = current, nfsPorts[path] == nil, let r = line.range(of: #"(?<![a-z])port=(\d+)"#, options: .regularExpression) {
                nfsPorts[path] = Int(line[r].dropFirst("port=".count))
            }
        }
        var result: [LocalMount] = []
        let base = mountBase.hasSuffix("/") ? mountBase : mountBase + "/"
        for line in mountOutput.split(separator: "\n") {
            guard let on = line.range(of: " on "), let paren = line.range(of: " (", range: on.upperBound..<line.endIndex) else { continue }
            let source = String(line[..<on.lowerBound])
            let path = String(line[on.upperBound..<paren.lowerBound])
            let fsType = line[paren.upperBound...].prefix { $0 != "," && $0 != ")" }
            if fsType == "nfs", source.hasPrefix("127.0.0.1:"), path.hasPrefix(base) {
                result.append(LocalMount(path: path, kind: .nfs, port: nfsPorts[path]))
            } else if fsType == "webdav", source.hasPrefix("http://127.0.0.1:") {
                let after = source.dropFirst("http://127.0.0.1:".count)
                result.append(LocalMount(path: path, kind: .webdav, port: Int(after.prefix { $0.isNumber })))
            }
        }
        return result
    }

    /// Mounts currently on this machine that look like ours (see `parseLocalMounts`).
    public func currentLocalMounts() -> [LocalMount] {
        let mountOutput = Self.output(of: "/sbin/mount", [])
        let nfsstatOutput = Self.output(of: "/usr/bin/nfsstat", ["-m"])
        var seen = Set<String>()
        return ([mountBase] + legacyMountBases).flatMap {
            Self.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstatOutput, mountBase: $0.path)
        }.filter { seen.insert($0.path).inserted }
    }

    /// At launch nothing is mounted by *this* process, so any NFS mount of a local rclone
    /// under the mount base is a leftover from a previous run (app killed, rclone killed,
    /// crash). Left alone it makes macOS show "Server connections interrupted" and makes
    /// the next mount pick `<name>-2`, `<name>-3`, ... Unmount it, stop its rclone and
    /// remove the empty folder. Returns the mountpoints that were cleaned up.
    @discardableResult
    public func reconcileLeftoverNFSMounts() -> [String] {
        var cleaned: [String] = []
        for m in currentLocalMounts() where m.kind == .nfs {
            try? forceUnmount(mountpoint: m.path)
            if let port = m.port { killRcloneOnPort(port) }
            if !isMounted(mountpoint: m.path) {
                rmdir(m.path)    // POSIX rmdir: only removes an empty directory
                cleaned.append(m.path)
            }
        }
        return cleaned
    }

    /// Stops RMount-owned `rclone serve` processes that no session owns (left by a run that died,
    /// whether or not they ever got mounted) and unmounts the localhost WebDAV volumes they served,
    /// even when the remote was renamed or deleted since. See `OrphanReaper` for the safety rules.
    @discardableResult
    public func reconcileOrphanedRclone() -> OrphanReaper.Report {
        OrphanReaper(
            listMounts: { self.currentLocalMounts() },
            unmount: { try? self.forceUnmount(mountpoint: $0) }
        ).reap()
    }

    private static func output(of exe: String, _ args: [String]) -> String {
        guard let r = try? ProcessRunner.run(executable: URL(fileURLWithPath: exe), arguments: args, timeout: 15)
        else { return "" }
        return r.stdoutString
    }

    /// If `/Volumes/<volname>` is currently mounted from a `http://127.0.0.1:<port>/...`
    /// source (the shape RMount produces), unmount it and SIGTERM the orphan rclone
    /// process listening on that port. Returns true if anything was reconciled.
    ///
    /// Called at app launch before `autoMountAll` so a prior RMount instance that
    /// died via SIGKILL/crash doesn't produce duplicate `/Volumes/<name>-1`,
    /// `<name>-2` mounts on every subsequent launch.
    @discardableResult
    public func reconcileStaleMount(volumeName: String) -> Bool {
        guard let port = staleLocalhostPort(forVolume: volumeName) else { return false }
        try? unmount(mountpoint: "/Volumes/\(volumeName)")
        killRcloneOnPort(port)
        return true
    }

    /// Parses `/sbin/mount` output for a line like
    /// `http://127.0.0.1:<port>/.../ on /Volumes/<volname> (webdav, ...)` and returns
    /// the port. Returns nil if the volume isn't mounted, or it's mounted from a
    /// non-localhost source (someone else's mount we shouldn't touch).
    private func staleLocalhostPort(forVolume volname: String) -> Int? {
        guard let r = try? ProcessRunner.run(executable: URL(fileURLWithPath: "/sbin/mount"), timeout: 15),
              !r.timedOut else { return nil }
        let text = r.stdoutString
        let suffix = " on /Volumes/\(volname) "
        for line in text.split(separator: "\n") {
            guard line.contains(suffix) else { continue }
            // Expected: "http://127.0.0.1:<port>/<path>/ on /Volumes/<volname> (webdav, ...)"
            guard let prefixRange = line.range(of: "http://127.0.0.1:") else { return nil }
            let after = line[prefixRange.upperBound...]
            // Port runs from here up to the next '/'.
            guard let slash = after.firstIndex(of: "/") else { return nil }
            return Int(after[..<slash])
        }
        return nil
    }

    /// `pgrep -f` for an rclone child whose --addr matches the given port, then SIGTERM.
    /// Per-port matching keeps this safe for users (especially of rmount-lite) who may
    /// have other rclone processes running unrelated to RMount.
    private func killRcloneOnPort(_ port: Int) {
        let pattern = "rclone serve (webdav|nfs).*--addr 127.0.0.1:\(port)( |$)"
        guard let r = try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", pattern], timeout: 15)
        else { return }
        let text = r.stdoutString
        for line in text.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// Calls `diskutil unmount <mountpoint>`. A refusal because the volume is in use throws
    /// `MountError.busy` so the caller can ask the user; it never forces on its own. With
    /// `force` (quit, remote deletion, the user's "Force Unmount") it uses `unmount force`.
    ///
    /// Unmounting something that is already gone (ejected in Finder, rclone killed, mount
    /// cleaned up by another run) is a success, not an error.
    public func unmount(mountpoint: String, force: Bool = false) throws {
        if force { return try forceUnmount(mountpoint: mountpoint) }
        guard isMounted(mountpoint: mountpoint) else { return }
        do {
            try run(
                "/usr/sbin/diskutil",
                args: ["unmount", mountpoint],
                failure: MountError.unmountFailed
            )
        } catch MountError.unmountFailed(let stderr, let code) {
            if Self.isBusyFailure(stderr) { throw MountError.busy(mountpoint: mountpoint) }
            throw MountError.unmountFailed(stderr: stderr, exitCode: code)
        }
    }

    /// True when diskutil's message says the volume could not be unmounted because it is in use.
    static func isBusyFailure(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("busy") || s.contains("dissented") || s.contains("in use")
    }

    /// `diskutil unmount force`, for mounts whose server is gone. No-op if not mounted.
    public func forceUnmount(mountpoint: String) throws {
        guard isMounted(mountpoint: mountpoint) else { return }
        try run("/usr/sbin/diskutil", args: ["unmount", "force", mountpoint], failure: MountError.unmountFailed)
    }

    /// True when `mountpoint` appears as a mount target in `/sbin/mount` output.
    public func isMounted(mountpoint: String) -> Bool {
        // Can't tell (launch failed or hung): let diskutil decide.
        guard let r = try? ProcessRunner.run(executable: URL(fileURLWithPath: "/sbin/mount"), timeout: 15),
              !r.timedOut else { return true }
        let text = r.stdoutString
        let resolved = URL(fileURLWithPath: mountpoint).resolvingSymlinksInPath().path
        return text.split(separator: "\n").contains { line in
            line.contains(" on \(mountpoint) (") || line.contains(" on \(resolved) (")
        }
    }

    /// Longest a `diskutil`/`umount` run may take before it is killed (a hung one would
    /// otherwise block its caller forever).
    var commandDeadline: TimeInterval = 30

    /// Waits for `p` by polling `isRunning` (never `waitUntilExit` after a kill, which can
    /// miss its wakeup) and SIGKILLs it past the deadline.
    static func waitWithDeadline(_ p: Process, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            let grace = Date().addingTimeInterval(1)
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let after = Date().addingTimeInterval(1)
            while p.isRunning && Date() < after { Thread.sleep(forTimeInterval: 0.02) }
        }
    }

    private func run(_ executable: String, args: [String], failure: (String, Int32) -> MountError) throws {
        let r = try ProcessRunner.run(executable: URL(fileURLWithPath: executable), arguments: args, timeout: commandDeadline)
        if r.status != 0 {
            throw failure(r.stderrString, r.status)
        }
    }
}
