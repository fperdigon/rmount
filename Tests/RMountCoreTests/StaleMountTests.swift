import XCTest
@testable import RMountCore

final class StaleMountTests: DebugTestCase {
    private let mountOutput = """
    /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
    127.0.0.1:/ on /Users/fco/rmount/DevEnv (nfs, nodev, nosuid, mounted by fco)
    127.0.0.1:/ on /Users/fco/rmount/DevEnv-2 (nfs, nodev, nosuid, mounted by fco)
    http://127.0.0.1:49165/Docs/ on /Volumes/Docs (webdav, nodev, nosuid, mounted by fco)
    192.168.1.5:/export on /Users/fco/rmount/Nas (nfs, nodev, nosuid, mounted by fco)
    127.0.0.1:/ on /Users/fco/other/Thing (nfs, nodev, nosuid, mounted by fco)
    /dev/disk4s1 on /Volumes/rmount (hfs, local, nodev, nosuid, read-only, noowners, quarantine, mounted by fco)
    """

    private let nfsstat = """
    /Users/fco/rmount/DevEnv from 127.0.0.1:/
      -s sys
      NFS parameters: vers=3,tcp,port=54924,mountport=54924,soft,noresvport,nolocks,rsize=1048576
      File system locations:
        /
    /Users/fco/rmount/DevEnv-2 from 127.0.0.1:/
      NFS parameters: vers=3,tcp,port=55300,mountport=55300,soft,noresvport,nolocks
    """

    func testFindsOnlyLocalRcloneMounts() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/rmount")
        XCTAssertEqual(found.map(\.path), ["/Users/fco/rmount/DevEnv", "/Users/fco/rmount/DevEnv-2", "/Volumes/Docs"])
    }

    func testNFSPortsComeFromNfsstat() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/rmount")
        XCTAssertEqual(found[0].port, 54924)
        XCTAssertEqual(found[1].port, 55300)
        XCTAssertEqual(found[0].kind, .nfs)
    }

    func testWebDAVPortComesFromTheURL() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/rmount")
        XCTAssertEqual(found[2].kind, .webdav)
        XCTAssertEqual(found[2].port, 49165)
    }

    func testIgnoresRemoteNFSAndMountsOutsideTheBase() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/rmount")
        XCTAssertFalse(found.contains { $0.path.hasSuffix("Nas") || $0.path.hasSuffix("Thing") })
    }

    func testMissingNfsstatLeavesPortUnknown() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: "", mountBase: "/Users/fco/rmount")
        XCTAssertNil(found.first?.port)
    }

    func testBaseWithTrailingSlashAndPrefixLookalike() {
        let text = "127.0.0.1:/ on /Users/fco/rmount-other/X (nfs, nodev)\n127.0.0.1:/ on /Users/fco/rmount/Y (nfs, nodev)"
        let found = Mounter.parseLocalMounts(mountOutput: text, nfsstatOutput: "", mountBase: "/Users/fco/rmount/")
        XCTAssertEqual(found.map(\.path), ["/Users/fco/rmount/Y"])
    }

    func testForceUnmountOfUnmountedPathIsNoOp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rmount-fu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try Mounter().forceUnmount(mountpoint: dir.path))
    }
}

@MainActor
final class RcloneExitWatcherTests: DebugTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rmount-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func makeSession(autoMount: Bool = false) -> (SessionManager, RemoteSession) {
        let remote = Remote(
            id: UUID(), name: "w",
            backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)),
            mountProtocol: .nfs, autoMount: autoMount
        )
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: KeychainService(serviceName: "ai.rmount.test"),
            mounter: Mounter(mountBase: dir), logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: URL(fileURLWithPath: "/usr/bin/true"), finderBadgeTracker: FinderBadgeTracker(writer: NoopFinderBadgeStatusWriter()))
        return (manager, RemoteSession(remote: remote))
    }

    private func finishedProcess(status: Int32) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exit \(status)"]
        try p.debugRun(); p.debugWaitUntilExit()
        return p
    }

    func testUnexpectedExitMarksFailedAndClearsMount() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 7)
        session.rcloneProcess = proc
        session.mountpoint = dir.path            // not a real mount: force-unmount is a no-op
        session.transition(to: .mounted(at: dir.path))
        await manager.handleRcloneExit(session: session, process: proc)
        guard case .failed(let reason) = session.status else { return XCTFail("expected failed, got \(session.status)") }
        XCTAssertTrue(reason.contains("exit 7"))
        XCTAssertNil(session.mountpoint)
        XCTAssertNil(session.rcloneProcess)
    }

    func testUnexpectedExitPersistsRefreshedTokenAndRemovesTempConfig() async throws {
        let cfg = RcloneBackendConfig(type: "drive", options: [:], secretOptions: [RcloneSecretOption(name: "token", obscure: false, refreshable: true)], remotePath: "")
        let remote = Remote(id: UUID(), name: "d", backend: .rclone(cfg), mountProtocol: .nfs, autoMount: false)
        let keychain = KeychainService(serviceName: "ai.rmount.test")
        try keychain.set(remoteID: remote.id, kind: .option("token"), value: "OLD")
        defer { try? keychain.delete(remoteID: remote.id, kind: .option("token")) }
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: keychain,
            mounter: Mounter(mountBase: dir), logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: URL(fileURLWithPath: "/usr/bin/true"), finderBadgeTracker: FinderBadgeTracker(writer: NoopFinderBadgeStatusWriter()))
        let session = RemoteSession(remote: remote)
        let confDir = dir.appendingPathComponent("rmount-rclone-x", isDirectory: true)
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let conf = confDir.appendingPathComponent("rclone.conf")
        try "[r]\ntoken = NEW\n".write(to: conf, atomically: true, encoding: .utf8)
        let proc = try finishedProcess(status: 9)
        session.rcloneProcess = proc
        session.rcloneConfigURL = conf
        session.mountpoint = dir.path
        session.transition(to: .mounted(at: dir.path))
        await manager.handleRcloneExit(session: session, process: proc)
        XCTAssertEqual(try keychain.get(remoteID: remote.id, kind: .option("token")), "NEW")
        XCTAssertFalse(FileManager.default.fileExists(atPath: confDir.path))
        XCTAssertNil(session.rcloneConfigURL)
    }

    func testSweepRemovesOwnStaleItemsAndLeavesOtherFlavorsAlone() throws {
        let (manager, _) = makeSession()
        let fm = FileManager.default
        let ownDir = dir.appendingPathComponent("rmount-rclone-ai.x-\(UUID().uuidString)")
        let ownKey = dir.appendingPathComponent("rmount-key-ai.x-\(UUID().uuidString)")
        let otherDir = dir.appendingPathComponent("rmount-rclone-ai.x.lite-\(UUID().uuidString)")
        let otherKey = dir.appendingPathComponent("rmount-key-ai.x.lite-\(UUID().uuidString)")
        let unrelated = dir.appendingPathComponent("unrelated.txt")
        try fm.createDirectory(at: ownDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)
        for u in [ownKey, otherKey, unrelated] { try "k".write(to: u, atomically: true, encoding: .utf8) }
        let later = Date().addingTimeInterval(120)
        XCTAssertEqual(manager.sweepStaleTempItems(in: dir, tag: "ai.x", now: later, processLister: { "" }), 2)
        XCTAssertFalse(fm.fileExists(atPath: ownDir.path))
        XCTAssertFalse(fm.fileExists(atPath: ownKey.path))
        for u in [otherDir, otherKey, unrelated] { XCTAssertTrue(fm.fileExists(atPath: u.path)) }
    }

    func testSweepKeepsRecentOwnItems() throws {
        let (manager, _) = makeSession()
        let fresh = dir.appendingPathComponent("rmount-rclone-ai.x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        XCTAssertEqual(manager.sweepStaleTempItems(in: dir, tag: "ai.x", processLister: { "" }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSweepLegacyItemsNeedAgeAndNoArgvReference() throws {
        let (manager, _) = makeSession()
        let fm = FileManager.default
        let old = dir.appendingPathComponent("rmount-rclone-\(UUID().uuidString)")
        let busy = dir.appendingPathComponent("rmount-rclone-\(UUID().uuidString)")
        let oldKey = dir.appendingPathComponent("rmount-key-\(UUID().uuidString)")
        for d in [old, busy] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try "k".write(to: oldKey, atomically: true, encoding: .utf8)
        let lister = { "rclone serve --config \(busy.path)/rclone.conf" }
        XCTAssertEqual(manager.sweepStaleTempItems(in: dir, tag: "ai.x", now: Date().addingTimeInterval(3600), processLister: lister), 0)
        XCTAssertEqual(manager.sweepStaleTempItems(in: dir, tag: "ai.x", now: Date().addingTimeInterval(25 * 3600), processLister: lister), 2)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertFalse(fm.fileExists(atPath: oldKey.path))
        XCTAssertTrue(fm.fileExists(atPath: busy.path))
    }

    func testLiveProcessListerReturnsOutput() {
        XCTAssertFalse(SessionManager.liveProcessCommandLines().isEmpty)
    }

    func testSweepKeepsItemsUsedByALiveSession() throws {
        let (manager, _) = makeSession()
        try manager.add(Remote(id: UUID(), name: "live", backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)), mountProtocol: .nfs, autoMount: false))
        let session = manager.sessions[0]
        let fm = FileManager.default
        let liveDir = dir.appendingPathComponent("rmount-rclone-\(TempNaming.tag)-live", isDirectory: true)
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let liveKey = dir.appendingPathComponent("rmount-key-\(TempNaming.tag)-live")
        try "k".write(to: liveKey, atomically: true, encoding: .utf8)
        session.rcloneConfigURL = liveDir.appendingPathComponent("rclone.conf")
        session.ephemeralKeyURL = liveKey
        XCTAssertEqual(manager.sweepStaleTempItems(in: dir, now: Date().addingTimeInterval(120), processLister: { "" }), 0)
        XCTAssertTrue(fm.fileExists(atPath: liveDir.path))
        XCTAssertTrue(fm.fileExists(atPath: liveKey.path))
    }

    func testIntentionalStopIsIgnored() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 0)
        session.rcloneProcess = nil              // unmount detaches the process before terminating it
        session.transition(to: .idle)
        await manager.handleRcloneExit(session: session, process: proc)
        XCTAssertEqual(session.status, .idle)
    }

    func testExitDuringStoppingIsIgnored() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 0)
        session.rcloneProcess = proc
        session.transition(to: .stopping)
        await manager.handleRcloneExit(session: session, process: proc)
        XCTAssertEqual(session.status, .stopping)
    }
}
