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

    func testNextArmIsAppliedWhileIdleSoItIsInForceBeforeTheBatch() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        // At startup the first batch measures the prior itself: nothing to change.
        await c.observe(queue: VFSQueue(), stats: stats(0))
        var applied = await client.applied
        XCTAssertTrue(applied.isEmpty)
        await runBatch(c)
        // The batch drained: the next arm (closest neighbour of the prior) is set now, with the queue empty.
        applied = await client.applied
        XCTAssertEqual(applied, [2])
        XCTAssertEqual(c.currentArm, 2)
        XCTAssertTrue(logs.contains { $0.contains("4 -> 2") })
        // The following batch starts without any change and is credited to arm 2.
        await runBatch(c)
        applied = await client.applied
        XCTAssertEqual(applied.first, 2)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 2)?.count, 1)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 1)
    }

    func testIdleSampleAtStartupAppliesTheChoiceAfterRestart() async throws {
        // A remote that already measured arm 4 (and has arm 2 next to probe): the probe is applied on the first idle sample.
        let remote = makeRemote(backend: sftpBackend())
        var seed = TransfersBandit(clock: { self.now }, random: { 0.99 })
        seed.record(UploadBatch(bytes: 600_000_000, duration: 30, fileCount: 6), arm: 4)
        try TransfersBanditStore(directory: dir).save(seed.state, remote: remote.id.uuidString)
        let client = TransfersClient()
        let c = make(remote, client: client)
        await c.observe(queue: VFSQueue(), stats: stats(0))
        let applied = await client.applied
        XCTAssertEqual(applied, [2])
        XCTAssertEqual(c.currentArm, 2)
    }

    func testNothingIsAppliedWhileABatchIsRunning() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        // First sample already has a batch in flight: it runs with the arm rclone started with.
        let q = VFSQueue(queue: [entry(1, size: 600_000_000)])
        await c.observe(queue: q, stats: stats(0))
        now = now.addingTimeInterval(20)
        await c.observe(queue: q, stats: stats(300_000_000))
        var applied = await client.applied
        XCTAssertTrue(applied.isEmpty)
        now = now.addingTimeInterval(20)
        await c.observe(queue: VFSQueue(), stats: stats(600_000_000))
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 1)
        applied = await client.applied
        XCTAssertEqual(applied, [2])      // chosen only once the queue drained
    }

    func testNoApplyWhenArmUnchanged() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client, random: { 0.99 })
        await c.observe(queue: VFSQueue(), stats: stats(0))
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
        await runBatch(c)
        XCTAssertEqual(c.currentArm, 4)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 2)
        XCTAssertNil(c.bandit.stats(for: .large, arm: 2))
        XCTAssertTrue(logs.contains { $0.contains("could not set") })
    }

    func testArmChangedDuringABatchDiscardsTheSample() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        let q = VFSQueue(queue: [entry(1, size: 600_000_000)])
        await c.observe(queue: q, stats: stats(0))
        now = now.addingTimeInterval(30)
        await c.observe(queue: q, stats: stats(300_000_000))
        c.currentArm = 8                                       // e.g. changed from outside mid-batch
        now = now.addingTimeInterval(30)
        await c.observe(queue: VFSQueue(), stats: stats(600_000_000))
        XCTAssertNil(c.bandit.stats(for: .large, arm: 4))
        XCTAssertNil(c.bandit.stats(for: .large, arm: 8))
        XCTAssertTrue(logs.contains { $0.contains("discarded") })
    }

    func testBatchOfAnotherBucketIsCreditedToTheArmItRanWith() async {
        let client = TransfersClient()
        let c = make(makeRemote(backend: sftpBackend()), client: client)
        let files = (1...200).map { entry(UInt64($0), size: 500_000) }     // small files: avg 0.5 MB
        let q = VFSQueue(queue: files)
        await c.observe(queue: q, stats: stats(0))
        now = now.addingTimeInterval(120)
        await c.observe(queue: q, stats: stats(100_000_000))
        await c.observe(queue: VFSQueue(), stats: stats(100_000_000))
        XCTAssertEqual(c.bandit.stats(for: .small, arm: 4)?.count, 1)
        XCTAssertNil(c.bandit.stats(for: .large, arm: 4))
    }

    func testFinishedBatchIsRecordedAndPersisted() async throws {
        let client = TransfersClient()
        let remote = makeRemote(backend: sftpBackend())
        let c = make(remote, client: client)
        await runBatch(c)
        let saved = try XCTUnwrap(TransfersBanditStore(directory: dir).load(remote: remote.id.uuidString))
        XCTAssertEqual(saved.buckets["large"]?.stats["4"]?.count, 1)
        XCTAssertEqual(try XCTUnwrap(saved.buckets["large"]?.stats["4"]).mean, 10, accuracy: 0.01)   // 600 MB / 60 s
    }

    /// The VM scenario: 600 MB batches at 2 -> 10, 4 -> 20, 8 -> 40 MB/s, driven through the controller.
    func testControllerFindsTheFastArmThroughTheWholePipeline() async {
        let client = TransfersClient()
        let rng = SeededUnitRandom(seed: 5)
        let c = make(makeRemote(backend: s3Backend()), arm: 4, client: client, random: { rng.next() })
        let curve: [Int: Double] = [2: 10, 4: 20, 8: 40, 12: 32, 16: 25]
        var armsUsed: [Int] = []
        for _ in 0..<40 {
            let arm = c.currentArm
            armsUsed.append(arm)
            await runBatch(c, bytes: 600_000_000, seconds: 600 / curve[arm]!)
            now = now.addingTimeInterval(30)
            await c.observe(queue: VFSQueue(), stats: stats(0))
        }
        XCTAssertTrue(armsUsed.prefix(10).contains(8), "\(armsUsed)")
        let tail = armsUsed.dropFirst(10)
        XCTAssertGreaterThanOrEqual(Double(tail.filter { $0 == 8 }.count) / Double(tail.count), 0.7, "\(armsUsed)")
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
        RecordingURLProtocol.status = 200
        let records = try await client.coreTransferred()
        XCTAssertEqual(RecordingURLProtocol.seen?.url?.absoluteString, "http://127.0.0.1:43210/core/transferred")
        XCTAssertTrue(records.isEmpty)
        RecordingURLProtocol.status = 500
        do { _ = try await client.coreTransferred(); XCTFail("expected failure") } catch {}
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
            for s in manager.sessions { try? await manager.delete(s.id) }
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

    func testDeletingARemoteRemovesItsLearnedState() async throws {
        let bandit = try makeTempDir()
        let (m, _, _) = try fixture(bandit)
        let r = makeRemote(backend: sftpBackend())
        try m.add(r, sftpSecrets: pw)
        let store = TransfersBanditStore(directory: bandit)
        try store.save(BanditState(), remote: r.id.uuidString)
        try await m.delete(r.id)
        XCTAssertNil(store.load(remote: r.id.uuidString))
    }
}

// MARK: - Records (core/transferred)

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func rec(_ name: String, _ start: TimeInterval, _ end: TimeInterval, bytes: Int64 = 100_000_000,
                 error: String = "") -> CompletedTransfer {
    CompletedTransfer(name: name, size: bytes, bytes: bytes, error: error,
                      started: t0.addingTimeInterval(start), completed: t0.addingTimeInterval(end))
}

final class CompletedTransferTests: XCTestCase {
    func testParsesRcloneOutputWithOffsetsAndNanoseconds() {
        let json = """
        {"transferred":[
         {"error":"","name":"a.bin","size":41943040,"bytes":41943040,"checked":false,"what":"transferring",
          "started_at":"2026-11-24T20:38:59.18202-05:00","completed_at":"2026-11-24T20:38:59.292729123-05:00","group":"g"},
         {"error":"boom","name":"b","size":10,"bytes":3,"started_at":"2026-11-24T20:39:00Z","completed_at":"2026-11-24T20:39:02Z"},
         {"name":"open","started_at":"2026-11-24T20:39:00Z","completed_at":"0001-01-01T00:00:00Z"},
         {"name":"reversed","started_at":"2026-11-24T20:39:05Z","completed_at":"2026-11-24T20:39:00Z"},
         {"name":"nodates"}, 7
        ]}
        """
        let list = CompletedTransfer.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["a.bin", "b"])
        XCTAssertEqual(list[0].completed.timeIntervalSince(list[0].started), 0.110, accuracy: 0.002)   // millisecond precision
        XCTAssertEqual(list[0].bytes, 41_943_040)
        XCTAssertEqual(list[1].error, "boom")
        XCTAssertEqual(list[1].completed.timeIntervalSince(list[1].started), 2, accuracy: 0.001)
    }

    func testGarbageParsesToNothing() {
        XCTAssertTrue(CompletedTransfer.parse(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(CompletedTransfer.parse(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(CompletedTransfer.parse(Data("{\"transferred\":null}".utf8)).isEmpty)
    }
}

final class TransfersBatchBuilderTests: XCTestCase {
    func testTransfersCloseTogetherFormOneBatchSpanningFirstStartToLastCompletion() {
        var b = TransfersBatchBuilder()
        b.add([rec("a", 2, 10, bytes: 200_000_000), rec("b", 3, 14, bytes: 400_000_000)])
        let out = b.finish(now: t0.addingTimeInterval(20), queueEmpty: true, uploading: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].batch, UploadBatch(bytes: 600_000_000, duration: 12, fileCount: 2))
        XCTAssertEqual(out[0].start, t0.addingTimeInterval(2))
        XCTAssertTrue(b.hasProduced)
        XCTAssertFalse(b.hasPending)
    }

    func testGapSplitsBatchesAndTheNewestOneWaitsWhileUploadsRun() {
        var b = TransfersBatchBuilder()
        b.add([rec("a", 0, 10), rec("b", 40, 50)])
        let out = b.finish(now: t0.addingTimeInterval(52), queueEmpty: false, uploading: true)
        XCTAssertEqual(out.count, 1)                       // "b" may still grow
        XCTAssertTrue(b.hasPending)
        XCTAssertTrue(b.finish(now: t0.addingTimeInterval(60), queueEmpty: false, uploading: true).isEmpty)
        XCTAssertTrue(b.finish(now: t0.addingTimeInterval(100), queueEmpty: false, uploading: true).isEmpty)   // still uploading
        XCTAssertEqual(b.finish(now: t0.addingTimeInterval(100), queueEmpty: false, uploading: false).count, 1)  // waiting only
    }

    func testRecordsSeenBeforeAreNotCountedTwice() {
        var b = TransfersBatchBuilder()
        b.add([rec("a", 0, 10)])
        XCTAssertEqual(b.finish(now: t0.addingTimeInterval(11), queueEmpty: true, uploading: false).count, 1)
        b.add([rec("a", 0, 10), rec("b", 60, 70)])
        let out = b.finish(now: t0.addingTimeInterval(71), queueEmpty: true, uploading: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].batch.fileCount, 1)
        XCTAssertEqual(out[0].start, t0.addingTimeInterval(60))
    }

    func testSidecarsAreIgnored() {
        var b = TransfersBatchBuilder()
        b.add([rec("dir/._x", 0, 10), rec("a/._b", 0, 10)])
        XCTAssertFalse(b.hasPending)
    }

    func testErrorsFlagRateLimitOrFailureAndDoNotCountBytes() {
        var b = TransfersBatchBuilder()
        b.add([rec("a", 0, 10), rec("a", 1, 3, bytes: 5_000_000, error: "HTTP 429 Too Many Requests")])
        var out = b.finish(now: t0.addingTimeInterval(11), queueEmpty: true, uploading: false)
        XCTAssertTrue(out[0].batch.rateLimited)
        XCTAssertFalse(out[0].batch.failed)
        XCTAssertEqual(out[0].batch.bytes, 100_000_000)
        b.add([rec("c", 100, 110, error: "connection reset")])
        out = b.finish(now: t0.addingTimeInterval(111), queueEmpty: true, uploading: false)
        XCTAssertTrue(out[0].batch.failed)
        XCTAssertFalse(out[0].batch.rateLimited)
    }

    func testAFullListOfNothingButNewRecordsMayHaveLostOlderOnesAndIsDropped() {
        var b = TransfersBatchBuilder()
        b.add([rec("first", 0, 10)])
        _ = b.finish(now: t0.addingTimeInterval(11), queueEmpty: true, uploading: false)
        let flood = (0..<100).map { rec("f\($0)", 100 + Double($0), 101 + Double($0), bytes: 1_000) }
        b.add(flood)
        XCTAssertFalse(b.hasPending)
        XCTAssertEqual(b.droppedForRetention, 100)
        // The next poll overlaps the previous one, so its new records count again.
        b.add(Array(flood.suffix(99)) + [rec("g", 300, 310)])
        XCTAssertEqual(b.finish(now: t0.addingTimeInterval(311), queueEmpty: true, uploading: false).count, 1)
    }
}

@MainActor
final class TransfersRecordsControllerTests: XCTestCase {
    private var dir: URL!
    private var now = t0
    private var logs: [String] = []

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func make(backend: Backend = sftpBackend(), arm: Int = 4, client: TransfersClient,
                      seed: UInt64 = 5) -> TransfersController {
        let rng = SeededUnitRandom(seed: seed)
        return TransfersController(remote: makeRemote(backend: backend), startingArm: arm,
                                   store: TransfersBanditStore(directory: dir), client: client, random: { rng.next() },
                                   clock: { [unowned self] in self.now }, log: { [unowned self] in self.logs.append($0) })
    }

    private func poll(_ c: TransfersController, _ records: [CompletedTransfer], bytes: Int64 = 0) async {
        await c.observe(queue: VFSQueue(), stats: RcloneStats(bytes: bytes), transferred: records)
    }

    func testABatchEntirelyBetweenTwoIdlePollsIsTimedFromRclonesOwnRecords() async throws {
        let client = TransfersClient()
        let c = make(client: client)
        await poll(c, [])
        now = t0.addingTimeInterval(15)                                         // next idle poll
        await poll(c, [rec("f", 2, 14.5, bytes: 600_000_000)], bytes: 600_000_000)
        let s = try XCTUnwrap(c.bandit.stats(for: .large, arm: 4))
        XCTAssertEqual(s.mean, 600 / 12.5, accuracy: 48 * 0.05)                 // bytes / span, not the poll gap
        XCTAssertEqual(s.count, 1)
    }

    func testBatchStraddlingAnArmChangeIsDroppedAndLaterOnesAreCreditedToTheNewArm() async throws {
        let client = TransfersClient()
        let c = make(client: client)
        await poll(c, [])
        now = t0.addingTimeInterval(15)
        let first = rec("f", 2, 14.5, bytes: 600_000_000)
        await poll(c, [first], bytes: 600_000_000)           // credited to 4; arm 2 is applied now (t0+15)
        XCTAssertEqual(c.currentArm, 2)
        now = t0.addingTimeInterval(25)
        let straddling = rec("g", 10, 20, bytes: 300_000_000)   // started before the change at 15, ended after it
        await poll(c, [first, straddling], bytes: 900_000_000)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 1)
        XCTAssertNil(c.bandit.stats(for: .large, arm: 2))
        XCTAssertTrue(logs.contains { $0.contains("discarded") })
        now = t0.addingTimeInterval(60)
        let later = rec("h", 40, 50, bytes: 100_000_000)
        await poll(c, [first, straddling, later], bytes: 1_000_000_000)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 2)?.count, 1)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 2)!.mean, 10, accuracy: 0.5)
    }

    func testRecordsFlowNoMoreFallsBackToTimingFromPollsOnlyBeforeAnyBatchWasBuilt() async {
        let client = TransfersClient()
        let c = make(client: client)
        // Empty (not missing) records: the polled batch is used.
        let q = VFSQueue(queue: [entry(1, size: 600_000_000)])
        await c.observe(queue: q, stats: RcloneStats(bytes: 0), transferred: [])
        now = now.addingTimeInterval(30)
        await c.observe(queue: q, stats: RcloneStats(bytes: 300_000_000), transferred: [])
        now = now.addingTimeInterval(30)
        await c.observe(queue: VFSQueue(), stats: RcloneStats(bytes: 600_000_000), transferred: [])
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 1)
        // Once records produce batches, a polled finish is not counted a second time.
        now = now.addingTimeInterval(100)
        let q2 = VFSQueue(queue: [entry(2, size: 600_000_000)])
        await c.observe(queue: q2, stats: RcloneStats(bytes: 600_000_000), transferred: [])
        now = now.addingTimeInterval(20)
        let r = rec("x", 130, 148, bytes: 600_000_000)
        await c.observe(queue: VFSQueue(), stats: RcloneStats(bytes: 1_200_000_000), transferred: [r])
        let total = [2, 4, 8].compactMap { c.bandit.stats(for: .large, arm: $0)?.count }.reduce(0, +)
        XCTAssertEqual(total, 2)
    }

    func testStalledVerdictFromThePollsDropsTheRecordedBatch() async {
        let client = TransfersClient()
        let c = make(client: client)
        let q = VFSQueue(queue: [entry(1)])
        await c.observe(queue: q, stats: RcloneStats(bytes: 0), transferred: [])
        now = now.addingTimeInterval(200)
        await c.observe(queue: q, stats: RcloneStats(bytes: 0), transferred: [])
        await c.observe(queue: VFSQueue(), stats: RcloneStats(bytes: 0), transferred: [rec("a", 0, 200)])
        XCTAssertNil(c.bandit.stats(for: .large, arm: 4))
        XCTAssertTrue(logs.contains { $0.contains("ignored") })
    }

    func testThrottledRecordPenalisesTheArm() async {
        let client = TransfersClient()
        let c = make(client: client)
        await poll(c, [])
        now = t0.addingTimeInterval(15)
        await poll(c, [rec("f", 2, 12, bytes: 600_000_000), rec("f", 3, 5, bytes: 1_000, error: "429 rate limit")],
                   bytes: 600_000_000)
        XCTAssertEqual(c.bandit.stats(for: .large, arm: 4)?.count, 1)
        XCTAssertLessThan(c.bandit.stats(for: .large, arm: 4)!.mean, 20)    // 60 MB/s x 0.25
    }

    /// Replays 600 MB batches against a throughput curve through the controller, using only rclone-style
    /// records; the poll comes `delay` seconds (0-15) after each batch, as an idle poll would.
    private func replay(_ c: TransfersController, curve: [Int: Double], batches: Int) async -> [Int] {
        var arms: [Int] = []
        var all: [CompletedTransfer] = []
        var clockTime = 100.0
        for i in 0..<batches {
            let arm = c.currentArm
            arms.append(arm)
            let start = clockTime + 1
            let end = start + 600 / curve[arm]!
            all.append(rec("b\(i)", start, end, bytes: 600_000_000))
            clockTime = end + Double(i % 11) * 1.5
            now = t0.addingTimeInterval(clockTime)
            await poll(c, Array(all.suffix(100)), bytes: Int64(i + 1) * 600_000_000)
            clockTime += 5
        }
        return arms
    }

    func testReachesArm8ForTheVMCurveWhateverTheFirstSightingDelay() async throws {
        let c = make(client: TransfersClient())
        let curve: [Int: Double] = [2: 10, 4: 20, 8: 40, 12: 32, 16: 25]
        let arms = await replay(c, curve: curve, batches: 50)
        XCTAssertTrue(arms.prefix(10).contains(8), "\(arms)")
        XCTAssertEqual(c.bandit.bestArm(for: .large), 8)
        let tail = arms.dropFirst(10)
        XCTAssertGreaterThanOrEqual(Double(tail.filter { $0 == 8 }.count) / Double(tail.count), 0.7, "\(arms)")
        for (arm, mbps) in curve {
            if let s = c.bandit.stats(for: .large, arm: arm) { XCTAssertEqual(s.mean, mbps, accuracy: mbps * 0.05, "arm \(arm)") }
        }
    }

    func testReachesArm16WhenMoreParallelismKeepsHelping() async throws {
        let c = make(backend: s3Backend(), arm: 8, client: TransfersClient())
        let curve: [Int: Double] = [2: 5, 4: 10, 8: 20, 12: 30, 16: 40]
        let arms = await replay(c, curve: curve, batches: 60)
        XCTAssertTrue(arms.prefix(14).contains(16), "\(arms)")
        XCTAssertEqual(c.bandit.bestArm(for: .large), 16)
        let tail = arms.dropFirst(14)
        XCTAssertGreaterThanOrEqual(Double(tail.filter { $0 == 16 }.count) / Double(tail.count), 0.7, "\(arms)")
    }
}

private final class RecordsClient: RcloneControlClient, @unchecked Sendable {
    var queue = VFSQueue()
    var bytes: Int64 = 0
    var fetches = 0
    func vfsQueue() async throws -> VFSQueue { queue }
    func coreStats() async throws -> RcloneStats { RcloneStats(bytes: bytes) }
    func coreTransferred() async throws -> [CompletedTransfer] { fetches += 1; return [rec("a", 0, 1)] }
}

@MainActor
final class UploadMonitorRecordsTests: XCTestCase {
    func testTransferRecordsAreFetchedOnlyWhenBusyOrBytesMoved() async {
        let client = RecordsClient()
        var got: [Bool] = []
        let monitor = UploadMonitor(client: client, intervals: .init(pending: 100, idle: 100),
                                    onSample: { _, _, t in got.append(t != nil) }, onStatus: { _ in })
        await monitor.refresh()
        let first = client.fetches
        XCTAssertGreaterThanOrEqual(first, 1)
        await monitor.refresh()                                    // idle, counter unchanged
        XCTAssertEqual(client.fetches, first)
        client.bytes = 10
        await monitor.refresh()                                    // counter moved: a batch may have happened
        XCTAssertEqual(client.fetches, first + 1)
        client.queue = VFSQueue(queue: [VFSQueue.Entry(name: "f", id: 1, size: 10, uploading: true)])
        await monitor.refresh()                                    // busy
        XCTAssertEqual(client.fetches, first + 2)
        XCTAssertEqual(got.last, true)
        monitor.stop()
    }
}
