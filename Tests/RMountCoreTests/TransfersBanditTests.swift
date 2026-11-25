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
        XCTAssertEqual(make(start: 7).bestArm(for: .large), 6)
        XCTAssertEqual(make(start: 9).bestArm(for: .large), 8)
        XCTAssertEqual(make(start: 100).bestArm(for: .large), 24)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "S3"), 8)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "sftp"), 4)
        XCTAssertEqual(BanditConfiguration.prior(forBackend: "other"), 4)
        // The type strings the app really passes (BackendDescriptor.type), not just short names.
        for cloud in ["s3", "azureblob", "b2", "google cloud storage", "drive"] {
            XCTAssertEqual(BanditConfiguration.prior(forBackend: cloud), 8, cloud)
        }
        for other in ["webdav", "smb", "sftp", "ftp"] { XCTAssertEqual(BanditConfiguration.prior(forBackend: other), 4, other) }
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
        XCTAssertEqual(b.bestArm(for: .large), 1)
    }

    func testSlowLinkPeaksHigh() {
        var b = make(start: 4)
        run(&b, 400) { 2 + 0.5 * Double($0) }  // s3-like: more is better
        XCTAssertEqual(b.bestArm(for: .large), 24)
    }

    func testExploresAboutEpsilonOfTheTime() {
        var b = make(start: 8)
        run(&b, 3) { _ in 20 }                      // past the guarded first slices
        var other = 0
        let n = 4000
        let best = b.bestArm(for: .large)
        for _ in 0..<n where b.chooseArm(for: .large) != best { other += 1 }
        let rate = Double(other) / Double(n)
        XCTAssertEqual(rate, 0.2, accuracy: 0.03)
    }

    func testExplorationIsMostlyAdjacentAndSometimesAJumpAnywhere() {
        var b = make(start: 8)
        run(&b, 30) { $0 == 8 ? 40 : 10 }
        XCTAssertEqual(b.bestArm(for: .large), 8)
        let arms = BanditConfiguration.defaultArms
        var adjacent = 0, jumps = 0, picks = 0
        var distinct = Set<Int>()
        for _ in 0..<6000 {
            let a = b.chooseArm(for: .large)
            guard a != 8 else { continue }
            picks += 1
            distinct.insert(a)
            if abs(arms.firstIndex(of: a)! - arms.firstIndex(of: 8)!) == 1 { adjacent += 1 } else { jumps += 1 }
        }
        XCTAssertGreaterThan(jumps, 0)
        // 70% adjacent picks plus the adjacent arms' share of the uniform 30% (2 of 9).
        XCTAssertEqual(Double(adjacent) / Double(picks), 0.7 + 0.3 * 2 / 9, accuracy: 0.04)
        XCTAssertEqual(distinct, Set(arms).subtracting([8]))       // every other arm is tried
    }

    func testCappedArmSetIsNeverExceeded() {
        var b = make(start: 8) { $0.arms = $0.arms.filter { $0 <= 8 } }     // Google Drive
        run(&b, 400) { 10 + Double($0) }
        var seen = Set<Int>()
        for _ in 0..<2000 { seen.insert(b.chooseArm(for: .large)) }
        XCTAssertEqual(seen.max(), 8)
        XCTAssertEqual(b.bestArm(for: .large), 8)
    }

    func testEdgeArmExploresItsOnlyNeighbourOrJumps() {
        var b = make(start: 4)
        run(&b, 60) { $0 == 1 ? 50 : 5 }          // arm 1 is by far the best
        XCTAssertEqual(b.bestArm(for: .large), 1)
        var seen = Set<Int>()
        for _ in 0..<2000 { seen.insert(b.chooseArm(for: .large)) }
        XCTAssertTrue(seen.contains(2) && seen.contains(1))
    }

    func testExplorationNeverStops() {
        var b = make(start: 4)
        let curve: (Int) -> Double = { $0 == 4 ? 40 : 5 }     // an overwhelming winner, as clear as it gets
        run(&b, 300, curve: curve)
        let late = run(&b, 1000, curve: curve)
        let other = Double(late.filter { $0 != 4 }.count) / Double(late.count)
        XCTAssertEqual(other, 0.2, accuracy: 0.04)
    }

    func testStartNeverBelowFourAndFirstBatchesStayNearThePrior() {
        XCTAssertEqual(make(start: 2).bestArm(for: .large), 4)
        XCTAssertEqual(make(start: 1).bestArm(for: .large), 4)
        XCTAssertEqual(make(start: 3).bestArm(for: .large), 4)
        for seed in 0..<40 as Range<UInt64> {
            var b = make(seed: seed, start: 8)
            let first = run(&b, 3) { _ in 20 }
            XCTAssertEqual(first.first, 8)
            XCTAssertTrue(first.allSatisfy { [6, 8, 10].contains($0) }, "\(first)")
        }
        for seed in 0..<40 as Range<UInt64> {
            var b = make(seed: seed, start: 4)
            XCTAssertTrue(run(&b, 3) { _ in 20 }.allSatisfy { [3, 4, 6].contains($0) })
        }
    }

    func testFollowsTheLinkWhenTheBestArmChanges() {
        var b = make(start: 4)
        run(&b, 150) { $0 == 4 ? 40 : 5 }
        XCTAssertEqual(b.bestArm(for: .large), 4)
        run(&b, 300) { $0 == 8 ? 40 : 5 }                      // the link changed: 8 is the best now
        XCTAssertEqual(b.bestArm(for: .large), 8)
    }

    func testSmallOrShortBatchesIgnored() {
        var b = make()
        b.record(UploadBatch(bytes: 3_000_000, duration: 60, fileCount: 1), arm: 4)
        b.record(UploadBatch(bytes: 500_000_000, duration: 3, fileCount: 1), arm: 4)      // too short
        b.record(UploadBatch(bytes: 60_000_000, duration: 15, fileCount: 1), arm: 4)      // few bytes, not long
        b.record(UploadBatch(bytes: 1_000_000, duration: 60, fileCount: 1), arm: 4)       // long but latency only
        b.record(UploadBatch(bytes: 500_000_000, duration: 60, fileCount: 1, failed: true), arm: 4)
        b.record(batch(mbps: 10), arm: 99)
        XCTAssertNil(b.stats(for: .large, arm: 4))
        b.record(batch(mbps: 10), arm: 4)
        XCTAssertEqual(b.stats(for: .large, arm: 4)?.count, 1)
        XCTAssertEqual(b.stats(for: .large, arm: 4)!.mean, 10, accuracy: 0.001)
    }

    func testFastBatchesCountByBytesAndSlowOnesByDuration() {
        var b = make()
        b.record(UploadBatch(bytes: 600_000_000, duration: 6, fileCount: 3), arm: 8)      // fast arm, short batch
        XCTAssertEqual(b.stats(for: .large, arm: 8)?.count, 1)
        XCTAssertEqual(b.stats(for: .large, arm: 8)!.mean, 100, accuracy: 0.001)
        b.record(UploadBatch(bytes: 40_000_000, duration: 25, fileCount: 3), arm: 2)      // slow arm, long batch
        XCTAssertEqual(b.stats(for: .large, arm: 2)?.count, 1)
        b.record(UploadBatch(bytes: 600_000_000, duration: 4.9, fileCount: 3), arm: 12)   // under the minimum duration
        XCTAssertNil(b.stats(for: .large, arm: 12))
    }

    func testColdStartProbesNeighboursSystematically() {
        var b = make(start: 4)
        var seen: [Int] = []
        for _ in 0..<3 {
            now = now.addingTimeInterval(120)
            let arm = b.chooseArm(for: .large)
            seen.append(arm)
            b.record(batch(mbps: 10 * Double(arm), seconds: 30), arm: arm)
        }
        // Prior first, then the closer neighbour, then the other one; best (8) is then probed outward.
        XCTAssertEqual(seen, [4, 3, 6])
        now = now.addingTimeInterval(120)
        XCTAssertEqual(b.chooseArm(for: .large), 8)
    }

    func testProbeBudgetIsBoundedWhenBatchesNeverCount() {
        var b = make(start: 4)
        var probes = 0
        for _ in 0..<200 where b.chooseArm(for: .large) != 4 { probes += 1 }
        // Nothing is ever recorded: after the budget, only epsilon-greedy exploration remains.
        XCTAssertEqual(Double(probes) / 200, 0.2, accuracy: 0.07)
        XCTAssertEqual(b.state.buckets["large"]?.probes, b.configuration.maxProbes)
    }

    func testReachesTheBestArmFastFromTheVMScenarioAndStaysThere() {
        // The curve seen in the VM: 2 -> 10, 4 -> 20, 8 -> 40 MB/s over 600 MB batches (S3-like prior of 4).
        let curve: [Int: Double] = [1: 5, 2: 10, 3: 15, 4: 20, 6: 30, 8: 40, 10: 38, 12: 32, 16: 25, 24: 15]
        var b = make(seed: 11, start: 4)
        var arms: [Int] = []
        for _ in 0..<60 {
            now = now.addingTimeInterval(120)
            let arm = b.chooseArm(for: .large)
            arms.append(arm)
            let mbps = curve[arm]!
            b.record(UploadBatch(bytes: 600_000_000, duration: 600 / mbps, fileCount: 6), arm: arm)
        }
        XCTAssertTrue(arms.prefix(10).contains(8), "\(arms)")
        XCTAssertEqual(b.bestArm(for: .large), 8)
        let after = arms.dropFirst(12)
        let share = Double(after.filter { $0 == 8 }.count) / Double(after.count)
        XCTAssertGreaterThanOrEqual(share, 0.7, "\(arms)")
    }

    func testProbesFurtherWhenTheBestArmIsAtTheEdgeAndStopsAtTheCap() {
        var b = make(start: 12)
        var seen: [Int] = []
        for _ in 0..<10 {
            now = now.addingTimeInterval(120)
            let arm = b.chooseArm(for: .large)
            seen.append(arm)
            b.record(batch(mbps: 5 * Double(arm), seconds: 30), arm: arm)   // keeps improving up to 16
        }
        XCTAssertTrue(seen.contains(24))
        XCTAssertEqual(b.bestArm(for: .large), 24)
        XCTAssertTrue(seen.allSatisfy { BanditConfiguration.defaultArms.contains($0) })
    }

    func testEwmaMean() {
        var b = make()
        b.record(batch(mbps: 10), arm: 4)
        b.record(batch(mbps: 20), arm: 4)
        XCTAssertEqual(b.stats(for: .large, arm: 4)!.mean, 15, accuracy: 0.001)      // early samples weigh 1/(n+1)
        for _ in 0..<20 { b.record(batch(mbps: 20), arm: 4) }
        b.record(batch(mbps: 0.5), arm: 4)                                          // one bad sample cannot erase the history
        XCTAssertGreaterThan(b.stats(for: .large, arm: 4)!.mean, 8)
    }

    func testAStaleBestArmAgesOutWhenTheWholeLinkGetsSlower() {
        // History: a high plateau, best at arm 10 (65 MB/s).
        var b = make(seed: 4, start: 8)
        let before: [Int: Double] = [4: 40, 6: 50, 8: 55, 10: 65, 12: 45]
        for _ in 0..<6 { for (arm, mbps) in before { b.record(batch(mbps: mbps, seconds: 30), arm: arm) } }
        XCTAssertEqual(b.bestArm(for: .large), 10)
        // A global cap: every arm now delivers 20.
        var pulls: [Int] = []
        for _ in 0..<6 {
            now = now.addingTimeInterval(60)
            let arm = b.chooseArm(for: .large)
            pulls.append(arm)
            b.record(batch(mbps: 20, seconds: 30), arm: arm)
        }
        let means = BanditConfiguration.defaultArms.compactMap { b.stats(for: .large, arm: $0)?.mean }
        XCTAssertLessThan(means.max()!, 27, "\(pulls) \(means)")
        XCTAssertGreaterThan(means.max()!, 19)
        // Exploration stayed at its constant rate: not more than 1 slice in 5 on average was off the best.
    }

    func testAgeingNeverRaisesAnArmAndLeavesAStableLinkAlone() {
        var b = make(start: 4)
        let arms = BanditConfiguration.defaultArms
        let curve: (Int) -> Double = { max(5, 40 - 8 * Double(abs(arms.firstIndex(of: $0)! - arms.firstIndex(of: 8)!))) }
        run(&b, 150, curve: curve)
        XCTAssertEqual(b.bestArm(for: .large), 8)
        // Noise-free rewards never fall below 70% of an arm's own mean, so nothing is aged: means are exact.
        for a in arms { if let s = b.stats(for: .large, arm: a) { XCTAssertEqual(s.mean, curve(a), accuracy: 0.001, "arm \(a)") } }
    }

    func testRejectionReasonsAreReported() {
        let b = make()
        XCTAssertNil(b.rejectionReason(for: batch(mbps: 10), arm: 4))
        XCTAssertNotNil(b.rejectionReason(for: batch(mbps: 10), arm: 99))
        XCTAssertNotNil(b.rejectionReason(for: UploadBatch(bytes: 900_000_000, duration: 2, fileCount: 1), arm: 4)?.range(of: "short"))
        XCTAssertNotNil(b.rejectionReason(for: UploadBatch(bytes: 1_000_000, duration: 60, fileCount: 1), arm: 4)?.range(of: "little"))
        XCTAssertNotNil(b.rejectionReason(for: UploadBatch(bytes: 900_000_000, duration: 60, fileCount: 1, failed: true), arm: 4)?.range(of: "failed"))
        XCTAssertNil(b.rejectionReason(for: UploadBatch(bytes: 1, duration: 1, fileCount: 1, rateLimited: true), arm: 4))
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
