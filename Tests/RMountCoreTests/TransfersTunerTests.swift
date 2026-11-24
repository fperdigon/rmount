import XCTest
@testable import RMountCore

final class TransfersTunerTests: XCTestCase {
    private var time = Date(timeIntervalSince1970: 1_000_000)

    private func makeTuner(_ config: TransfersTuner.Configuration = .init()) -> TransfersTuner {
        TransfersTuner(configuration: config, clock: { [unowned self] in self.time })
    }

    /// Feeds one tick 30 s after the previous one.
    private func tick(_ t: inout TransfersTuner, _ bps: Double?, active: Int = 3) -> Int {
        time = time.addingTimeInterval(30)
        return t.observe(bytesPerSecond: bps, activeUploads: active)
    }

    /// Concave curve peaking at 8 transfers.
    private func curve(_ n: Int) -> Double { 10_000_000 - 100_000 * Double((n - 8) * (n - 8)) }

    func testBytesPerSecond() {
        let a = ThroughputSample(totalBytes: 1_000, at: Date(timeIntervalSince1970: 0))
        let b = ThroughputSample(totalBytes: 31_000, at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(ThroughputSample.bytesPerSecond(from: a, to: b), 1_000)
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: b, to: a))
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: a, to: a))
        let reset = ThroughputSample(totalBytes: 10, at: Date(timeIntervalSince1970: 60))
        XCTAssertNil(ThroughputSample.bytesPerSecond(from: b, to: reset))
    }

    func testStartsAtDefaultAndClamps() {
        XCTAssertEqual(makeTuner().current, 4)
        XCTAssertEqual(makeTuner(.init(defaultValue: 99)).current, 16)
        XCTAssertEqual(makeTuner(.init(defaultValue: 0)).current, 1)
    }

    func testFirstTickStepsUp() {
        var t = makeTuner()
        XCTAssertEqual(tick(&t, 1_000_000), 5)
    }

    func testKeepsImprovingMoveAndContinues() {
        var t = makeTuner()
        _ = tick(&t, 1_000_000)               // 4 -> 5
        XCTAssertEqual(tick(&t, 1_200_000), 6) // improved: keep, step again
    }

    func testRevertsAndReversesWhenNotBetter() {
        var t = makeTuner()
        _ = tick(&t, 1_000_000)               // 4 -> 5
        XCTAssertEqual(tick(&t, 1_000_000), 4) // no gain: back to 4
        XCTAssertEqual(tick(&t, 1_000_000), 3) // re-measure at 4, then go down
    }

    func testGainInsideNoiseMarginIsNotKept() {
        var t = makeTuner()
        _ = tick(&t, 1_000_000)
        XCTAssertEqual(tick(&t, 1_040_000), 4)
    }

    func testConvergesOnConcaveCurve() {
        var t = makeTuner()
        var n = t.current
        var seen: [Int] = []
        for _ in 0..<40 {
            n = tick(&t, curve(n))
            seen.append(n)
        }
        // Gains near the peak are inside the noise margin, so it settles close to, not exactly on, the peak.
        XCTAssertTrue(seen.suffix(10).allSatisfy { curve($0) >= 0.9 * curve(8) }, "\(seen)")
    }

    func testConvergesDownwardFromHighStart() {
        var t = makeTuner(.init(defaultValue: 14))
        var n = t.current
        var seen: [Int] = []
        for _ in 0..<40 { n = tick(&t, curve(n)); seen.append(n) }
        XCTAssertTrue(seen.suffix(10).allSatisfy { curve($0) >= 0.9 * curve(8) }, "\(seen)")
    }

    func testToleratesSmallNoise() {
        var t = makeTuner()
        var n = t.current
        let noise: [Double] = [1.02, 0.98, 1.01, 0.99, 1.02, 0.98]
        var seen: [Int] = []
        for i in 0..<60 { n = tick(&t, curve(n) * noise[i % noise.count]); seen.append(n) }
        XCTAssertTrue(seen.suffix(10).allSatisfy { curve($0) >= 0.9 * curve(8) }, "\(seen)")
    }

    func testNeverLeavesRange() {
        var t = makeTuner(.init(range: 2...5))
        var n = t.current
        for i in 0..<50 {
            n = tick(&t, 1_000_000 + Double(i % 3) * 400_000)
            XCTAssertTrue((2...5).contains(n))
        }
    }

    func testUpperEdgeTurnsAround() {
        var t = makeTuner(.init(defaultValue: 16))
        XCTAssertEqual(tick(&t, 1_000_000), 15)
    }

    func testSingleValueRangeNeverMoves() {
        var t = makeTuner(.init(defaultValue: 3, range: 3...3))
        XCTAssertEqual(tick(&t, 1_000_000), 3)
        XCTAssertEqual(tick(&t, 2_000_000), 3)
    }

    func testIdleResetsToDefault() {
        var t = makeTuner()
        _ = tick(&t, 1_000_000); _ = tick(&t, 2_000_000)
        XCTAssertEqual(t.current, 6)
        XCTAssertEqual(tick(&t, nil, active: 0), 4)
        XCTAssertEqual(tick(&t, 1_000_000), 5, "fresh start after reset")
    }

    func testIgnoresTooLittleOrMissingData() {
        var t = makeTuner()
        XCTAssertEqual(tick(&t, nil), 4)
        XCTAssertEqual(tick(&t, 100), 4)
        XCTAssertEqual(tick(&t, .nan), 4)
        XCTAssertEqual(tick(&t, 1_000_000), 5)
        XCTAssertEqual(tick(&t, nil), 5, "ignored tick keeps the pending move")
        XCTAssertEqual(tick(&t, 1_500_000), 6)
    }

    func testIgnoresTicksCloserThanMinInterval() {
        var t = makeTuner()
        time = time.addingTimeInterval(30)
        XCTAssertEqual(t.observe(bytesPerSecond: 1_000_000, activeUploads: 1), 5)
        time = time.addingTimeInterval(5)
        XCTAssertEqual(t.observe(bytesPerSecond: 5_000_000, activeUploads: 1), 5)
        time = time.addingTimeInterval(25)
        XCTAssertEqual(t.observe(bytesPerSecond: 5_000_000, activeUploads: 1), 6)
    }

    func testDeterministic() {
        func run() -> [Int] {
            var t = makeTuner(); var n = t.current; var out: [Int] = []
            for _ in 0..<20 { n = tick(&t, curve(n)); out.append(n) }
            return out
        }
        XCTAssertEqual(run(), run())
    }
}
