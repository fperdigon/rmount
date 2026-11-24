import Foundation

/// Two readings of rclone's cumulative uploaded-bytes counter (`core/stats`), turned into bytes/s.
public struct ThroughputSample: Equatable {
    public let totalBytes: Int64
    public let at: Date
    public init(totalBytes: Int64, at: Date) { self.totalBytes = totalBytes; self.at = at }

    /// Bytes per second between two snapshots. Nil when no time passed, time went backwards, or the counter
    /// dropped (rclone restarted or stats were reset), because the window is then meaningless.
    public static func bytesPerSecond(from earlier: ThroughputSample, to later: ThroughputSample) -> Double? {
        let elapsed = later.at.timeIntervalSince(earlier.at)
        let delta = later.totalBytes - earlier.totalBytes
        guard elapsed > 0, delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }
}

/// Hill-climbing controller for rclone's `--transfers` while uploads are active. Pure and deterministic: it
/// holds no timers, does no I/O and uses no randomness; the caller feeds one throughput sample per tick
/// (about every 30 s) and gets the value to use next.
///
/// Each valid tick records a baseline at the current value, then moves by one step in the current direction.
/// The next tick judges that move: kept (and the direction remembered) when throughput improved by more than
/// `noiseMargin`, otherwise reverted and the direction reversed. The value is clamped to `range`; hitting an
/// edge turns the climber around. Ticks with no active uploads reset it to `defaultValue`; ticks with too
/// little data or arriving sooner than `minTickInterval` after the previous one are ignored.
///
/// Applying the result (not decided here): rclone cannot change `--transfers` on a running `rclone mount`
/// or `serve` through `options/set` for the VFS write-back queue, so the options are (a) restart the rclone
/// process with the new value when the queue is idle or between uploads, (b) `core/command`/`options/set`
/// if a future rclone honours it live, or (c) tune only for the next mount. A restart costs a remount, so
/// the caller should also rate-limit applied changes.
public struct TransfersTuner {
    public struct Configuration: Equatable {
        public var defaultValue: Int
        public var range: ClosedRange<Int>
        /// Relative gain needed to keep a move (0.05 = 5%).
        public var noiseMargin: Double
        /// Samples below this many bytes/s carry no signal and are ignored.
        public var minBytesPerSecond: Double
        /// Ticks closer together than this are ignored (needs the injected clock).
        public var minTickInterval: TimeInterval

        public init(defaultValue: Int = 4, range: ClosedRange<Int> = 1...16, noiseMargin: Double = 0.05,
                    minBytesPerSecond: Double = 64 * 1024, minTickInterval: TimeInterval = 20) {
            self.defaultValue = defaultValue; self.range = range; self.noiseMargin = noiseMargin
            self.minBytesPerSecond = minBytesPerSecond; self.minTickInterval = minTickInterval
        }
    }

    private struct Trial { let previous: Int; let baseline: Double }

    public let configuration: Configuration
    public private(set) var current: Int
    private var direction = 1
    private var baseline: Double?
    private var trial: Trial?
    private var lastTick: Date?
    private let clock: () -> Date

    public init(configuration: Configuration = Configuration(), clock: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.clock = clock
        self.current = Self.clamp(configuration.defaultValue, configuration.range)
    }

    /// Feed one tick and get the `--transfers` value to use next (unchanged when the tick is ignored).
    @discardableResult
    public mutating func observe(bytesPerSecond: Double?, activeUploads: Int) -> Int {
        let now = clock()
        guard activeUploads > 0 else { reset(); return current }
        if let lastTick, now.timeIntervalSince(lastTick) < configuration.minTickInterval { return current }
        guard let sample = bytesPerSecond, sample.isFinite, sample >= configuration.minBytesPerSecond else {
            return current
        }
        lastTick = now

        if let t = trial {
            trial = nil
            if sample > t.baseline * (1 + configuration.noiseMargin) {
                baseline = sample
            } else {
                // Revert, turn around, and re-measure the old value before the next move.
                current = t.previous
                direction = -direction
                baseline = nil
                return current
            }
        } else {
            baseline = sample
        }
        propose(from: sample)
        return current
    }

    /// Back to the default value with no memory, as when the upload queue empties.
    public mutating func reset() {
        current = Self.clamp(configuration.defaultValue, configuration.range)
        direction = 1; baseline = nil; trial = nil; lastTick = nil
    }

    private mutating func propose(from sample: Double) {
        var next = current + direction
        if !configuration.range.contains(next) {
            direction = -direction
            next = current + direction
        }
        guard configuration.range.contains(next) else { return }
        trial = Trial(previous: current, baseline: sample)
        current = next
    }

    private static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
}
