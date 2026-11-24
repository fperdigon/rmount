import XCTest
@testable import RMountCore

private actor TransfersClient: RcloneControlClient {
    var applied: [Int] = []
    var fails = false
    func vfsQueue() async throws -> VFSQueue { VFSQueue() }
    func setTransfers(_ count: Int) async throws {
        if fails { throw URLError(.cannotConnectToHost) }
        applied.append(count)
    }
    func failSets() { fails = true }
}

private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var seen: URLRequest?
    nonisolated(unsafe) static var body: Data?
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = request
        if let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.body = data
        } else { Self.body = request.httpBody }
        let r = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func entry(_ id: UInt64, size: Int64 = 100_000_000, uploading: Bool = true, tries: Int = 0, name: String? = nil) -> VFSQueue.Entry {
    VFSQueue.Entry(name: name ?? "f\(id)", id: id, size: size, uploading: uploading, tries: tries)
}

// MARK: - Batch tracker

final class TransfersBatchTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func stats(_ bytes: Int64, errors: Int = 0, last: String? = nil) -> RcloneStats {
        RcloneStats(bytes: bytes, errors: errors, lastError: last)
    }

    func testIdleQueueProducesNothing() {
        var t = TransfersBatchTracker()
        XCTAssertNil(t.observe(queue: VFSQueue(), stats: stats(0), now: at(0)))
        XCTAssertFalse(t.isActive)
    }

    func testSidecarsAloneDoNotStartABatch() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1, name: "dir/._x")])
        XCTAssertNil(t.observe(queue: q, stats: stats(0), now: at(0)))
    }

    func testBatchStartsAndFinishesWithBytesDurationAndFiles() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1), entry(2)])
        XCTAssertEqual(t.observe(queue: q, stats: stats(1_000), now: at(0)), .started(fileCount: 2, bytes: 200_000_000))
        XCTAssertNil(t.observe(queue: q, stats: stats(60_001_000), now: at(10)))
        XCTAssertNil(t.observe(queue: q, stats: stats(160_001_000), now: at(30)))
        let event = t.observe(queue: VFSQueue(), stats: stats(200_001_000), now: at(33))
        XCTAssertEqual(event, .finished(UploadBatch(bytes: 200_000_000, duration: 33, fileCount: 2)))
        XCTAssertFalse(t.isActive)
    }

    func testBytesAreCappedByQueuedSizes() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1, size: 10_000_000)])
        _ = t.observe(queue: q, stats: stats(0), now: at(0))
        _ = t.observe(queue: q, stats: stats(900_000_000), now: at(10))   // a download ran meanwhile
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(900_000_000), now: at(12)) else { return XCTFail() }
        XCTAssertEqual(b.bytes, 10_000_000)
    }

    func testFilesAddedDuringBatchAreCounted() {
        var t = TransfersBatchTracker()
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0), now: at(0))
        _ = t.observe(queue: VFSQueue(queue: [entry(1), entry(2)]), stats: stats(50_000_000), now: at(5))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(200_000_000), now: at(10)) else { return XCTFail() }
        XCTAssertEqual(b.fileCount, 2)
    }

    func testRisingTriesMarkRateLimited() {
        var t = TransfersBatchTracker()
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0), now: at(0))
        _ = t.observe(queue: VFSQueue(queue: [entry(1, tries: 2)]), stats: stats(1_000_000), now: at(5))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(100_000_000), now: at(20)) else { return XCTFail() }
        XCTAssertTrue(b.rateLimited)
        XCTAssertFalse(b.failed)
    }

    func testThrottlingErrorMarksRateLimited() {
        var t = TransfersBatchTracker()
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0), now: at(0))
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(1, errors: 1, last: "googleapi: Error 403: User rate limit exceeded"), now: at(5))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(100_000_000, errors: 1), now: at(20)) else { return XCTFail() }
        XCTAssertTrue(b.rateLimited)
    }

    func testOtherErrorMarksFailedEvenWithRetries() {
        var t = TransfersBatchTracker()
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0), now: at(0))
        _ = t.observe(queue: VFSQueue(queue: [entry(1, tries: 3)]), stats: stats(1, errors: 1, last: "connection reset by peer"), now: at(5))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(100_000_000, errors: 1), now: at(20)) else { return XCTFail() }
        XCTAssertTrue(b.failed)
        XCTAssertFalse(b.rateLimited)
    }

    func testErrorsPresentBeforeTheBatchAreIgnored() {
        var t = TransfersBatchTracker()
        _ = t.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0, errors: 5, last: "429"), now: at(0))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(100_000_000, errors: 5, last: "429"), now: at(20)) else { return XCTFail() }
        XCTAssertFalse(b.rateLimited); XCTAssertFalse(b.failed)
    }

    func testStalledBatchIsIgnored() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1)])
        _ = t.observe(queue: q, stats: stats(0), now: at(0))
        _ = t.observe(queue: q, stats: stats(10_000_000), now: at(10))
        XCTAssertNil(t.observe(queue: q, stats: stats(10_000_000), now: at(120)))   // 110 s without bytes
        XCTAssertEqual(t.observe(queue: VFSQueue(), stats: stats(10_000_000), now: at(125)), .finished(nil))
    }

    func testRecoveryAfterAStallStillCounts() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1, size: 100_000_000)])
        _ = t.observe(queue: q, stats: stats(0), now: at(0))
        _ = t.observe(queue: q, stats: stats(0), now: at(100))     // stalled
        _ = t.observe(queue: q, stats: stats(50_000_000), now: at(110))
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(100_000_000), now: at(130)) else { return XCTFail() }
        XCTAssertEqual(b.bytes, 100_000_000)
    }

    func testIdleForTooLongEndsTheBatchIgnored() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1, uploading: false)])
        _ = t.observe(queue: q, stats: stats(0), now: at(0))
        XCTAssertEqual(t.observe(queue: q, stats: stats(0), now: at(700)), .finished(nil))
        XCTAssertFalse(t.isActive)
        XCTAssertNotNil(t.observe(queue: q, stats: stats(0), now: at(701)))   // a new batch begins
    }

    func testNoByteCounterMeansIgnored() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1)])
        _ = t.observe(queue: q, stats: nil, now: at(0))
        XCTAssertNil(t.observe(queue: q, stats: nil, now: at(200)))    // no stall verdict without a counter
        XCTAssertEqual(t.observe(queue: VFSQueue(), stats: nil, now: at(210)), .finished(nil))
    }

    func testCounterResetDoesNotGoNegative() {
        var t = TransfersBatchTracker()
        let q = VFSQueue(queue: [entry(1, size: 100_000_000)])
        _ = t.observe(queue: q, stats: stats(500_000_000), now: at(0))
        _ = t.observe(queue: q, stats: stats(10), now: at(5))   // rclone restarted
        guard case .finished(let b?) = t.observe(queue: VFSQueue(), stats: stats(60_000_010), now: at(20)) else { return XCTFail() }
        XCTAssertEqual(b.bytes, 60_000_000)
    }

    func testRateLimitTextDetection() {
        for s in ["HTTP 429", "Too Many Requests", "rateLimitExceeded", "quota exceeded", "SlowDown: reduce rate"] {
            XCTAssertTrue(TransfersBatchTracker.looksRateLimited(s), s)
        }
        XCTAssertFalse(TransfersBatchTracker.looksRateLimited("connection refused"))
    }
}

// MARK: - Controller

@MainActor
final class TransfersControllerTests: XCTestCase {
    private var dir: URL!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var logs: [String] = []

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func make(_ remote: Remote, arm: Int = 4, client: TransfersClient,
                      random: @escaping () -> Double = { 0 }) -> TransfersController {
        TransfersController(remote: remote, startingArm: arm, store: TransfersBanditStore(directory: dir), client: client,
                            random: random, clock: { [unowned self] in self.now }, log: { [unowned self] in self.logs.append($0) })
    }

    private func stats(_ b: Int64) -> RcloneStats { RcloneStats(bytes: b) }

    private func runBatch(_ c: TransfersController, bytes: Int64 = 600_000_000, seconds: TimeInterval = 60) async {
        let q = VFSQueue(queue: [entry(1, size: bytes)])
        await c.observe(queue: q, stats: stats(0))
        now = now.addingTimeInterval(seconds)
        await c.observe(queue: q, stats: stats(bytes))
        await c.observe(queue: VFSQueue(), stats: stats(bytes))
    }

    func testBatchStartAppliesChosenArmLive() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        await c.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0))
        let applied = await client.applied
        XCTAssertEqual(applied, [2])            // explore forced: first neighbour of 4
        XCTAssertEqual(c.currentArm, 2)
        XCTAssertTrue(logs.contains { $0.contains("4 -> 2") })
    }

    func testNoApplyWhenArmUnchanged() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client, random: { 0.99 })
        await c.observe(queue: VFSQueue(queue: [entry(1)]), stats: stats(0))
        let applied = await client.applied
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(c.currentArm, 4)
    }

    func testFailedApplyKeepsArmAndRecordsAgainstIt() async {
        let client = TransfersClient()
        await client.failSets()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        await runBatch(c)
        XCTAssertEqual(c.currentArm, 4)
        XCTAssertNotNil(c.bandit.stats(for: .large, arm: 4))
        XCTAssertNil(c.bandit.stats(for: .large, arm: 2))
    }

    func testFinishedBatchIsRecordedAndPersisted() async throws {
        let client = TransfersClient()
        let remote = makeRemote(backend: sftpBackend())
        let c = make(remote, client: client)
        await runBatch(c)
        let saved = try XCTUnwrap(TransfersBanditStore(directory: dir).load(remote: remote.id.uuidString))
        let arm = c.currentArm
        XCTAssertEqual(saved.buckets["large"]?.stats[String(arm)]?.count, 1)
        XCTAssertEqual(try XCTUnwrap(saved.buckets["large"]?.stats[String(arm)]).mean, 10, accuracy: 0.01)   // 600 MB / 60 s
    }

    func testStalledBatchIsNotPersisted() async {
        let client = TransfersClient()
        let remote = makeRemote(backend: sftpBackend())
        let c = make(remote, client: client)
        let q = VFSQueue(queue: [entry(1)])
        await c.observe(queue: q, stats: stats(0))
        now = now.addingTimeInterval(200)
        await c.observe(queue: q, stats: stats(0))
        await c.observe(queue: VFSQueue(), stats: stats(0))
        XCTAssertNil(TransfersBanditStore(directory: dir).load(remote: remote.id.uuidString))
        XCTAssertTrue(logs.contains { $0.contains("ignored") })
    }

    func testStartupArmUsesPriorThenBestMeasured() throws {
        let store = TransfersBanditStore(directory: dir)
        let s3 = makeRemote(backend: s3Backend())
        XCTAssertEqual(TransfersController.startupArm(for: s3, store: store), 8)
        var bandit = TransfersBandit(state: BanditState(), clock: { self.now }, random: { 0.99 })
        bandit.record(UploadBatch(bytes: 600_000_000, duration: 60, fileCount: 2), arm: 12, bucket: .large)
        try store.save(bandit.state, remote: s3.id.uuidString)
        XCTAssertEqual(TransfersController.startupArm(for: s3, store: store), 12)
    }

    func testDriveArmsAreCappedAtEight() {
        let config = BanditConfiguration.forBackend("drive")
        XCTAssertEqual(config.arms, [2, 4, 8])
        XCTAssertEqual(config.startingArm, 8)
        XCTAssertEqual(BanditConfiguration.forBackend("sftp").arms, [2, 4, 8, 12, 16])
        let drive = makeRemote(backend: driveBackend())
        XCTAssertEqual(drive.transfersBackendID, "drive")
        XCTAssertEqual(TransfersController.startupArm(for: drive, store: TransfersBanditStore(directory: dir)), 8)
    }

    func testBackendIDs() {
        XCTAssertEqual(makeRemote(backend: sftpBackend()).transfersBackendID, "sftp")
        XCTAssertEqual(makeRemote(backend: s3Backend()).transfersBackendID, "s3")
        XCTAssertEqual(makeRemote(backend: ftpBackend()).transfersBackendID, "ftp")
        XCTAssertEqual(makeRemote(backend: webdavBackend()).transfersBackendID, "webdav")
    }

    func testStoreRemoveDeletesTheFile() throws {
        let store = TransfersBanditStore(directory: dir)
        try store.save(BanditState(), remote: "abc")
        XCTAssertNotNil(store.load(remote: "abc"))
        store.remove(remote: "abc")
        XCTAssertNil(store.load(remote: "abc"))
        store.remove(remote: "abc")   // missing is fine
    }
}

// MARK: - Model and client

final class TransfersModelTests: XCTestCase {
    func testRemoteWithoutAutoTransfersDecodesAsOn() throws {
        let id = UUID().uuidString
        let json = """
        {"id":"\(id)","name":"n","mountProtocol":"webdav","autoMount":false,
         "backend":{"sftp":{"_0":{"host":"h","port":22,"user":"u","remotePath":"/","authKind":"password"}}}}
        """
        let r = try JSONDecoder().decode(Remote.self, from: Data(json.utf8))
        XCTAssertTrue(r.autoTransfers)
    }

    func testAutoTransfersRoundTripsAndToleratesGarbage() throws {
        var r = makeRemote(backend: sftpBackend())
        r.autoTransfers = false
        let data = try JSONEncoder().encode(r)
        XCTAssertFalse(try JSONDecoder().decode(Remote.self, from: data).autoTransfers)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["autoTransfers"] = "yes"
        let bad = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertTrue(try JSONDecoder().decode(Remote.self, from: bad).autoTransfers)
    }

    func testStatsDecodeBytesAndErrorsTolerantly() throws {
        let s = try JSONDecoder().decode(RcloneStats.self, from: Data(#"{"bytes":123,"errors":2,"lastError":"429 slow","transferring":[]}"#.utf8))
        XCTAssertEqual(s.bytes, 123); XCTAssertEqual(s.errors, 2); XCTAssertEqual(s.lastError, "429 slow")
        let odd = try JSONDecoder().decode(RcloneStats.self, from: Data(#"{"bytes":"x","errors":null}"#.utf8))
        XCTAssertNil(odd.bytes); XCTAssertNil(odd.errors)
    }

    func testSetTransfersPostsOptionsSet() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLProtocol.status = 200
        let client = URLSessionRcloneControlClient(port: 43210, user: "u", password: "p", session: URLSession(configuration: cfg))
        try await client.setTransfers(8)
        XCTAssertEqual(RecordingURLProtocol.seen?.url?.absoluteString, "http://127.0.0.1:43210/options/set")
        XCTAssertEqual(RecordingURLProtocol.seen?.httpMethod, "POST")
        let body = try XCTUnwrap(RecordingURLProtocol.body)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String: Int]])
        XCTAssertEqual(obj["main"]?["Transfers"], 8)
        RecordingURLProtocol.status = 500
        do { try await client.setTransfers(4); XCTFail("expected failure") } catch {}
    }

    func testDefaultClientRejectsSetTransfers() async {
        struct Bare: RcloneControlClient { func vfsQueue() async throws -> VFSQueue { VFSQueue() } }
        do { try await Bare().setTransfers(4); XCTFail() } catch {}
    }
}

// MARK: - SessionManager wiring

@MainActor
final class TransfersSessionTests: XCTestCase {
    private func fixture(_ banditDir: URL?, client: RcloneControlClient? = nil) throws -> (SessionManager, FakeRclone, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        let rclone = try FakeRclone.make(in: dir)
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: KeychainService(serviceName: "rmount.tests.\(UUID().uuidString)"),
            mounter: FakeMounter(), logsDir: dir.appendingPathComponent("logs"), rcloneBinary: rclone.binary,
            transfersBanditDirectory: banditDir, transfersRandom: { 0.99 },
            controlClient: { s in client ?? URLSessionRcloneControlClient(port: s.rcPort, user: s.rcUser, password: s.rcPassword) })
        addTeardownBlock { @MainActor in
            manager.shutdownAll()
            for s in manager.sessions { try? manager.delete(s.id) }
            try? FileManager.default.removeItem(at: dir)
        }
        return (manager, rclone, dir)
    }
    private let pw = SFTPSecrets(password: "pw", privateKeyPath: nil, keyPassphrase: nil)

    func testMountPassesBestKnownTransfersAndReportsIt() async throws {
        let bandit = try makeTempDir()
        let (m, rclone, _) = try fixture(bandit, client: TransfersClient())
        let r = makeRemote(backend: sftpBackend())
        try m.add(r, sftpSecrets: pw)
        try await m.mount(remoteID: r.id)
        let lines = rclone.recordedLines()
        let i = try XCTUnwrap(lines.firstIndex(of: "--transfers"))
        XCTAssertEqual(lines[i + 1], "4")
        XCTAssertEqual(m.transfersParallelism[r.id], 4)
        try await m.unmount(remoteID: r.id)
        XCTAssertNil(m.transfersParallelism[r.id])
    }

    func testMountUsesLearnedArm() async throws {
        let bandit = try makeTempDir()
        let r = makeRemote(backend: sftpBackend())
        var b = TransfersBandit(random: { 0.99 })
        b.record(UploadBatch(bytes: 600_000_000, duration: 60, fileCount: 2), arm: 12, bucket: .large)
        try TransfersBanditStore(directory: bandit).save(b.state, remote: r.id.uuidString)
        let (m, rclone, _) = try fixture(bandit, client: TransfersClient())
        try m.add(r, sftpSecrets: pw)
        try await m.mount(remoteID: r.id)
        let lines = rclone.recordedLines()
        XCTAssertEqual(lines[try XCTUnwrap(lines.firstIndex(of: "--transfers")) + 1], "12")
        try await m.unmount(remoteID: r.id)
    }

    func testNoTransfersFlagWhenOffReadOnlyOrNoDirectory() async throws {
        for mode in 0..<3 {
            let (m, rclone, _) = try fixture(mode == 2 ? nil : try makeTempDir(), client: TransfersClient())
            var r = makeRemote(backend: sftpBackend())
            if mode == 0 { r.autoTransfers = false }
            if mode == 1 { r.readOnly = true }
            try m.add(r, sftpSecrets: pw)
            try await m.mount(remoteID: r.id)
            XCTAssertFalse(rclone.recordedLines().contains("--transfers"), "mode \(mode)")
            XCTAssertNil(m.transfersParallelism[r.id])
            try await m.unmount(remoteID: r.id)
        }
    }

    func testDeletingARemoteRemovesItsLearnedState() throws {
        let bandit = try makeTempDir()
        let (m, _, _) = try fixture(bandit)
        let r = makeRemote(backend: sftpBackend())
        try m.add(r, sftpSecrets: pw)
        let store = TransfersBanditStore(directory: bandit)
        try store.save(BanditState(), remote: r.id.uuidString)
        try m.delete(r.id)
        XCTAssertNil(store.load(remote: r.id.uuidString))
    }
}
