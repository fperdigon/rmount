import XCTest
@testable import RMountCore

final class OrphanReaperTests: XCTestCase {
    private let uuid = "12345678-ABCD-4EF0-9876-0123456789AB"

    private func rmountCmd(port: Int, kind: String = "webdav", rc: Int = 50000) -> String {
        "/Applications/rmount.app/Contents/Resources/rclone serve \(kind) my remote:/a b --config /var/folders/x/T/rmount-rclone-\(uuid)/rclone.conf --addr 127.0.0.1:\(port) --rc --rc-addr 127.0.0.1:\(rc) --user rmount-1 --pass x"
    }

    private final class Recorder {
        var unmounted: [String] = []
        var killed: [Int32] = []
        var removed: [URL] = []
    }

    private func reaper(_ procs: [OrphanReaper.ProcessInfo], mounts: [Mounter.LocalMount], _ r: Recorder) -> OrphanReaper {
        OrphanReaper(
            listProcesses: { procs }, listMounts: { mounts },
            unmount: { r.unmounted.append($0) }, terminate: { r.killed.append($0) },
            removeDirectory: { r.removed.append($0) })
    }

    func testRecognisesRMountRcloneAndPort() {
        let o = OrphanReaper.ownedRclone(.init(pid: 5, ppid: 1, command: rmountCmd(port: 4321)))
        XCTAssertEqual(o?.port, 4321)
        XCTAssertEqual(o?.configURL.lastPathComponent, "rclone.conf")
        XCTAssertNotNil(OrphanReaper.ownedRclone(.init(pid: 5, ppid: 1, command: rmountCmd(port: 1, kind: "nfs"))))
    }

    func testRejectsForeignRclone() {
        for cmd in [
            "/opt/homebrew/bin/rclone serve webdav remote:/ --addr 127.0.0.1:8080",
            "rclone serve webdav r: --config /Users/me/.config/rclone/rclone.conf --addr 127.0.0.1:8080 --rc --rc-addr 127.0.0.1:5572",
            "rclone mount r: /mnt --config /tmp/rmount-rclone-\(uuid)/rclone.conf --addr 127.0.0.1:1 --rc --rc-addr 127.0.0.1:2",
            "vim rmount-rclone-\(uuid)/rclone.conf",
        ] {
            XCTAssertNil(OrphanReaper.ownedRclone(.init(pid: 9, ppid: 1, command: cmd)), cmd)
        }
    }

    func testParseProcessList() {
        let text = "  101     1 /usr/sbin/foo bar\n 202   101 rclone serve nfs x\nbad line\n"
        let ps = OrphanReaper.parseProcessList(text)
        XCTAssertEqual(ps.map(\.pid), [101, 202])
        XCTAssertEqual(ps[1].ppid, 101)
        XCTAssertEqual(ps[0].command, "/usr/sbin/foo bar")
    }

    func testReapsOrphanWithoutMountAndRemovesConfig() {
        let r = Recorder()
        let rep = reaper([.init(pid: 10, ppid: 1, command: rmountCmd(port: 7000))], mounts: [], r).reap()
        XCTAssertEqual(r.killed, [10])
        XCTAssertEqual(rep.killedPIDs, [10])
        XCTAssertEqual(r.removed.first?.lastPathComponent, "rmount-rclone-\(uuid)")
        XCTAssertTrue(r.unmounted.isEmpty)
    }

    func testUnmountsOnlyMountsServedByOrphan() {
        let r = Recorder()
        let mounts = [
            Mounter.LocalMount(path: "/Volumes/OldName", kind: .webdav, port: 7000),
            Mounter.LocalMount(path: "/Volumes/UserOwn", kind: .webdav, port: 9999),
            Mounter.LocalMount(path: "/Volumes/NoPort", kind: .nfs, port: nil),
        ]
        let rep = reaper([.init(pid: 10, ppid: 1, command: rmountCmd(port: 7000))], mounts: mounts, r).reap()
        XCTAssertEqual(r.unmounted, ["/Volumes/OldName"])
        XCTAssertEqual(rep.unmounted, ["/Volumes/OldName"])
    }

    func testLeavesLiveInstanceAndForeignProcessesAlone() {
        let r = Recorder()
        let procs: [OrphanReaper.ProcessInfo] = [
            .init(pid: 11, ppid: 4242, command: rmountCmd(port: 7001)),   // a running RMount's child
            .init(pid: 12, ppid: 1, command: "rclone serve webdav r: --addr 127.0.0.1:7002"),   // user's own
        ]
        let rep = reaper(procs, mounts: [Mounter.LocalMount(path: "/Volumes/X", kind: .webdav, port: 7001)], r).reap()
        XCTAssertEqual(rep, OrphanReaper.Report())
        XCTAssertTrue(r.killed.isEmpty && r.unmounted.isEmpty && r.removed.isEmpty)
    }

    func testSystemProcessesRuns() {
        XCTAssertFalse(OrphanReaper.systemProcesses().isEmpty)
    }
}
