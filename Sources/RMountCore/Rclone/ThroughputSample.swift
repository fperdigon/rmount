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
