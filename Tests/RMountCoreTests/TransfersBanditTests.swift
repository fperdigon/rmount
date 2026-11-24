import XCTest
@testable import RMountCore

final class TransfersBanditTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(seed: UInt64 = 7, start: Int = 4, state: BanditState = BanditState(),
                      tweak: (inout BanditConfiguration) -> Void = { _ in }) -> TransfersBandit {
        var c = BanditConfiguration(startingArm: start)
        tweak(&c)
        let rng = SeededUnitRandom(seed: seed)
        return TransfersBandit(configuration: c, state: state, clock: { [unowned self] in self.now },
                               random: { rng.next() })
    }

    private func batch(mbps: Double, files: Int = 10, seconds: TimeInterval = 60, rateLimited: Bool = false) -> UploadBatch {
        UploadBatch(bytes: Int64(mbps * 1_000_000 * seconds), duration: seconds, fileCount: files, rateLimited: rateLimited)
    }

    /// Runs `n` batches against a throughput curve; returns the arms chosen.
    @discardableResult
    private func run(_ b: inout TransfersBandit, _ n: Int, files: Int = 10, curve: (Int) -> Double) -> [Int] {
        var chosen: [Int] = []
        let bucket = WorkloadBucket.bucket(bytes: Int64(files) * 100_000_000, fileCount: files, smallFileThreshold: 8_000_000)
        for _ in 0..<n {
            now = now.addingTimeInterval(120)
            let arm = b.chooseArm(for: bucket)
            b.record(batch(mbps: curve(arm), files: files), arm: arm)
            chosen.append(arm)
        }
        return chosen
    }

    func testBucketSplit() {
        XCTAssertEqual(WorkloadBucket.bucket(bytes: 100_000_000, fileCount: 100, smallFileThreshold: 8_000_000), .small)
        XCTAssertEqual(WorkloadBucket.bucket(bytes: 100_000_000, fileCount: 2, smallFileThreshold: 8_000_000), .large)
        XCTAssertEqual(WorkloadBucket.bucket(bytes: 100_000_000, fileCount: 0, smallFileThreshold: 8_000_000), .large)
    }

    func testStartsAtSnappedPriorAndPriors() {
        XCTAssertEqual(make(start: 5).bestArm(for: .large), 4)
        XCTAssertEqual(make(start: 100).bestArm(for: .large), 16)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "S3"), 8)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "sftp"), 4)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "other"), 4)
    }

    func testConvergesOnConcaveCurve() {
        var b = make(start: 4)
        let curve: (Int) -> Double = { 20 - 0.2 * Double(($0 - 12) * ($0 - 12)) }  // peak at 12
        run(&b, 300, curve: curve)
        XCTAssertEqual(b.bestArm(for: .large), 12)
    }

    func testFastLinkPeaksLow() {
        var b = make(start: 8)
        run(&b, 300) { 50 - 3 * Double($0) }   // sftp-like: fewer is better
        XCTAssertEqual(b.bestArm(for: .large), 2)
    }

    func testSlowLinkPeaksHigh() {
        var b = make(start: 4)
        run(&b, 400) { 2 + 0.5 * Double($0) }  // s3-like: more is better
        XCTAssertEqual(b.bestArm(for: .large), 16)
    }

    func testSettlesAndStopsExploring() {
        var b = make(start: 4)
        let curve: (Int) -> Double = { $0 == 4 ? 20 : 5 }
        run(&b, 200, curve: curve)
        let late = run(&b, 200, curve: curve)
        XCTAssertTrue(late.allSatisfy { $0 == 4 })
    }

    func testExploresAboutEpsilonOfTheTime() {
        var b = make(start: 8)
        var other = 0
        let n = 4000
        for _ in 0..<n where b.chooseArm(for: .large) != 8 { other += 1 }
        let rate = Double(other) / Double(n)
        XCTAssertEqual(rate, 0.2, accuracy: 0.03)
    }

    func testExplorationIsOnlyAdjacent() {
        var b = make(start: 8)
        run(&b, 5) { _ in 10 }
        let best = b.bestArm(for: .large)
        let idx = [2, 4, 8, 12, 16].firstIndex(of: best)!
        let allowed = Set([idx - 1, idx, idx + 1].compactMap { [2, 4, 8, 12, 16].indices.contains($0) ? [2, 4, 8, 12, 16][$0] : nil })
        for _ in 0..<500 { XCTAssertTrue(allowed.contains(b.chooseArm(for: .large))) }
    }

    func testEdgeArmOnlyExploresInward() {
        var b = make(start: 2)
        for _ in 0..<300 { XCTAssertTrue([2, 4].contains(b.chooseArm(for: .large))) }
    }

    func testSmallOrShortBatchesIgnored() {
        var b = make()
        b.record(UploadBatch(bytes: 10_000_000, duration: 60, fileCount: 1), arm: 4)
        b.record(UploadBatch(bytes: 500_000_000, duration: 5, fileCount: 1), arm: 4)
        b.record(UploadBatch(bytes: 500_000_000, duration: 60, fileCount: 1, failed: true), arm: 4)
        b.record(batch(mbps: 10), arm: 99)
        XCTAssertNil(b.stats(for: .large, arm: 4))
        b.record(batch(mbps: 10), arm: 4)
        XCTAssertEqual(b.stats(for: .large, arm: 4)?.count, 1)
        XCTAssertEqual(b.stats(for: .large, arm: 4)!.mean, 10, accuracy: 0.001)
    }

    func testEwmaMean() {
        var b = make()
        b.record(batch(mbps: 10), arm: 4)
        b.record(batch(mbps: 20), arm: 4)
        XCTAssertEqual(b.stats(for: .large, arm: 4)!.mean, 13, accuracy: 0.001)
    }

    func testRateLimitPenalisesEvenTinyBatches() {
        var b = make()
        b.record(batch(mbps: 10), arm: 8)
        b.record(UploadBatch(bytes: 1_000, duration: 1, fileCount: 1, rateLimited: true), arm: 8, bucket: .large)
        XCTAssertEqual(b.stats(for: .large, arm: 8)!.mean, 2.5, accuracy: 0.001)
        // Penalised arm loses to a healthy one.
        b.record(batch(mbps: 6), arm: 4)
        XCTAssertEqual(b.bestArm(for: .large), 4)
    }

    func testBucketsAreIndependent() {
        var b = make()
        b.record(batch(mbps: 30, files: 2), arm: 12)          // large
        b.record(batch(mbps: 5, files: 5000), arm: 2)         // small (avg 60 KB)
        XCTAssertEqual(b.bestArm(for: .large), 12)
        XCTAssertEqual(b.bestArm(for: .small), 2)
        XCTAssertNil(b.stats(for: .small, arm: 12))
    }

    func testExplorationResumesAfterRewardDrop() {
        var b = make(start: 4)
        let curve: (Int) -> Double = { $0 == 4 ? 20 : 5 }
        run(&b, 200, curve: curve)
        XCTAssertTrue((0..<300).allSatisfy { _ in b.chooseArm(for: .large) == 4 })
        b.record(batch(mbps: 4), arm: 4)   // last reward collapses well below the mean
        let drop = (0..<300).filter { _ in b.chooseArm(for: .large) != 4 }.count
        XCTAssertGreaterThan(drop, 20)
    }

    func testExplorationResumesAfterLongTime() {
        var b = make(start: 4)
        let curve: (Int) -> Double = { $0 == 4 ? 20 : 5 }
        run(&b, 200, curve: curve)
        XCTAssertTrue((0..<300).allSatisfy { _ in b.chooseArm(for: .large) == 4 })
        now = now.addingTimeInterval(8 * 24 * 3600)
        let n = (0..<300).filter { _ in b.chooseArm(for: .large) != 4 }.count
        XCTAssertGreaterThanOrEqual(n, 1, "one probe after a quiet week, then quiet again")
    }

    func testDeterministic() {
        func go() -> [Int] { var b = make(); return run(&b, 50) { 10 + Double($0) } }
        XCTAssertEqual(go(), go())
    }

    // MARK: persistence

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bandit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testStoreRoundTrip() throws {
        var b = make()
        run(&b, 20) { 10 + Double($0) }
        let store = TransfersBanditStore(directory: tempDir())
        XCTAssertNil(store.load(remote: "my remote/1"))
        try store.save(b.state, remote: "my remote/1")
        XCTAssertEqual(store.fileURL(remote: "my remote/1").lastPathComponent, "my_remote_1.transfers-bandit.json")
        let loaded = try XCTUnwrap(store.load(remote: "my remote/1"))
        XCTAssertEqual(loaded.buckets["large"]?.stats, b.state.buckets["large"]?.stats)
        let restored = make(state: loaded)
        XCTAssertEqual(restored.bestArm(for: .large), b.bestArm(for: .large))
        try store.save(b.state, remote: "my remote/1")   // overwrite is fine
    }

    func testCorruptAndFutureFilesAreIgnored() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TransfersBanditStore(directory: dir)
        try Data("not json {".utf8).write(to: store.fileURL(remote: "a"))
        XCTAssertNil(store.load(remote: "a"))
        try Data("{\"version\":99}".utf8).write(to: store.fileURL(remote: "b"))
        XCTAssertNil(store.load(remote: "b"))
    }

    func testTolerantDecodeOfPartialState() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TransfersBanditStore(directory: dir)
        try Data("{\"version\":1}".utf8).write(to: store.fileURL(remote: "c"))
        XCTAssertEqual(store.load(remote: "c")?.buckets.count, 0)
        try Data("{\"buckets\":{\"large\":{\"stats\":{\"8\":{\"mean\":9,\"count\":2},\"99\":{\"mean\":1,\"count\":1}}}}}".utf8)
            .write(to: store.fileURL(remote: "d"))
        let s = try XCTUnwrap(store.load(remote: "d"))
        let b = make(state: s)
        XCTAssertEqual(b.bestArm(for: .large), 8)
        XCTAssertNil(b.stats(for: .large, arm: 99), "unknown arms are dropped")
    }

    func testThroughputSample() {
        let a = ThroughputSample(totalBytes: 1_000, at: Date(timeIntervalSince1970: 0))
        let c = ThroughputSample(totalBytes: 31_000, at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(ThroughputSample.bytesPerSecond(from: a, to: c), 1_000)
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: c, to: a))
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: a, to: a))
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: c, to: ThroughputSample(totalBytes: 5, at: Date(timeIntervalSince1970: 60))))
    }
}
