import Foundation
import Darwin

/// Finds and cleans up what a previous RMount run left behind when it died without cleaning up
/// (SIGKILL, crash, power loss): `rclone serve` children that no session owns, and the localhost
/// WebDAV volumes they back, including those of remotes that were renamed or deleted since.
///
/// Only things provably RMount's are touched. An rclone process counts as RMount's when its
/// argv has the exact shape `RcloneProcess` produces (`serve webdav|nfs ... --config
/// <tmp>/rmount-rclone-<UUID>/rclone.conf --addr 127.0.0.1:<port> --rc --rc-addr 127.0.0.1:<port>`)
/// and it is orphaned (parent is launchd, pid 1). A running RMount's children have the app as
/// parent, so a second instance never takes them. Every other rclone survives.
public struct OrphanReaper {
    public struct ProcessInfo: Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let command: String
        public init(pid: Int32, ppid: Int32, command: String) {
            self.pid = pid; self.ppid = ppid; self.command = command
        }
    }

    public struct OwnedRclone: Equatable {
        public let pid: Int32
        public let port: Int
        public let configURL: URL
    }

    public struct Report: Equatable {
        public var killedPIDs: [Int32] = []
        public var unmounted: [String] = []
        public init() {}
    }

    var listProcesses: () -> [ProcessInfo]
    var listMounts: () -> [Mounter.LocalMount]
    var unmount: (String) -> Void
    var terminate: (Int32) -> Void
    var removeDirectory: (URL) -> Void

    public init(
        listProcesses: @escaping () -> [ProcessInfo] = OrphanReaper.systemProcesses,
        listMounts: @escaping () -> [Mounter.LocalMount],
        unmount: @escaping (String) -> Void,
        terminate: @escaping (Int32) -> Void = { kill($0, SIGTERM) },
        removeDirectory: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    ) {
        self.listProcesses = listProcesses
        self.listMounts = listMounts
        self.unmount = unmount
        self.terminate = terminate
        self.removeDirectory = removeDirectory
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|/)rclone serve (?:webdav|nfs) .+? --config (\S+/rmount-rclone-[0-9A-Fa-f-]{36}/rclone\.conf) --addr 127\.0\.0\.1:(\d+) --rc --rc-addr 127\.0\.0\.1:\d+(?: |$)"#
    )

    /// The RMount rclone this command line describes, or nil when it is not provably ours.
    public static func ownedRclone(_ p: ProcessInfo) -> OwnedRclone? {
        let c = p.command
        let range = NSRange(c.startIndex..., in: c)
        guard let m = pattern.firstMatch(in: c, range: range),
              let cfg = Range(m.range(at: 1), in: c),
              let portRange = Range(m.range(at: 2), in: c),
              let port = Int(c[portRange]) else { return nil }
        return OwnedRclone(pid: p.pid, port: port, configURL: URL(fileURLWithPath: String(c[cfg])))
    }

    /// Parses `ps -axww -o pid=,ppid=,command=` output.
    public static func parseProcessList(_ text: String) -> [ProcessInfo] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.drop { $0 == " " }.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            return ProcessInfo(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }

    public static func systemProcesses() -> [ProcessInfo] {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProcessList(String(decoding: data, as: UTF8.self))
    }

    /// Orphaned RMount rclone processes (parent is launchd).
    func orphans() -> [OwnedRclone] {
        listProcesses().filter { $0.ppid == 1 }.compactMap(Self.ownedRclone)
    }

    /// Unmounts the localhost mounts served by an orphan, then stops the orphans and removes
    /// their temporary config. Mounts whose server is not a provable RMount orphan are left alone.
    @discardableResult
    public func reap() -> Report {
        let found = orphans()
        guard !found.isEmpty else { return Report() }
        var report = Report()
        let ports = Set(found.map(\.port))
        for m in listMounts() {
            guard let port = m.port, ports.contains(port) else { continue }
            unmount(m.path)
            report.unmounted.append(m.path)
        }
        for o in found {
            terminate(o.pid)
            removeDirectory(o.configURL.deletingLastPathComponent())
            report.killedPIDs.append(o.pid)
        }
        return report
    }
}
