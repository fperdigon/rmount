import Foundation

/// Measures how fast uploads ran during one time slice (about a minute of active uploads) for the bandit.
///
/// Source of truth: rclone's cumulative `core/stats` byte counter, sampled by the poll that runs every second or
/// two while uploads are active. Unlike `core/transferred` (a record appears only when a file completes, so a
/// big file would land in a single slice), the counter moves continuously, so slices inside one long copy get
/// fair numbers. Only uploads are meant to count: a sample taken while rclone also transfers a file that is not
/// in the upload queue (a download) marks the slice contaminated and it is dropped. The reward is the counter's
/// growth between the first sample after the warm-up and the last sample of the slice, divided by the time
/// between those two samples, so a pause in the middle of the slice counts as the slow time it was (a running
/// rate would hide it). Only when the batch itself ended in this slice, the end is the last sample that showed
/// progress, so the tail where the queue drains is not counted. Right after an arm change
/// the first `warmup` seconds are skipped: uploads already running keep their old concurrency until they finish.
/// A slice with no progress for `stallGap` seconds is stalled (a hung backend says nothing about the arm); a pause
/// shorter than that stays in the average.
/// Pure: the caller passes the times.
public struct TransfersSliceMeter {
    public var length: TimeInterval = 60
    public var warmup: TimeInterval = 10
    public var stallGap: TimeInterval = 45

    public struct Reading: Equatable {
        public var bytes: Int64
        public var duration: TimeInterval
        public var rateLimited: Bool
        public var failed: Bool
    }

    private var start: Date?
    private var windowStart: Date?
    private var baseline: (time: Date, bytes: Int64)?
    private var last: (time: Date, bytes: Int64)?
    private var lastProgress: (time: Date, bytes: Int64)?
    private var contaminated = false
    private var stalled = false
    private var rateLimited = false
    private var failed = false
    /// Why the last `finish` returned nil, for the debug log.
    public private(set) var dropReason = ""

    public init() {}

    public var isActive: Bool { start != nil }

    public func isDue(now: Date) -> Bool {
        guard let start else { return false }
        return now.timeIntervalSince(start) >= length
    }

    /// Starts a slice. `warmup` is skipped from the measurement (use 0 when the arm did not change);
    /// `baseline` is the counter at `at` when the previous slice ran on without a change.
    public mutating func begin(at: Date, warmup: TimeInterval, baseline: Int64? = nil) {
        start = at
        windowStart = at.addingTimeInterval(warmup)
        self.baseline = nil
        last = nil
        lastProgress = nil
        contaminated = false; stalled = false; rateLimited = false; failed = false
        if let baseline, warmup <= 0 {
            self.baseline = (at, baseline); last = (at, baseline); lastProgress = (at, baseline)
        }
    }

    public mutating func sample(time: Date, bytes: Int64?, contaminated: Bool, rateLimited: Bool, failed: Bool) {
        guard start != nil else { return }
        if contaminated { self.contaminated = true }
        if rateLimited { self.rateLimited = true }
        if failed { self.failed = true }
        guard let bytes else { return }
        if let l = last, bytes < l.bytes { self.stalled = true }          // counter reset: unusable
        if baseline == nil, let ws = windowStart, time >= ws {
            baseline = (time, bytes); last = (time, bytes); lastProgress = (time, bytes)
            return
        }
        guard let l = last else { return }
        if bytes > l.bytes {
            lastProgress = (time, bytes)
        } else if let p = lastProgress, time.timeIntervalSince(p.time) >= stallGap {
            stalled = true
        }
        last = (time, bytes)
    }

    /// Ends the slice. Nil when it cannot be used (nothing measured, stalled, contaminated, no counter), whatever the
    /// rate-limit flags say: a penalty needs the data of the slice it applies to.
    public mutating func finish(extraRateLimited: Bool = false, extraFailed: Bool = false, stalledOverride: Bool = false,
                                endAtLastProgress: Bool = false) -> Reading? {
        defer { start = nil; windowStart = nil; baseline = nil; last = nil; lastProgress = nil }
        dropReason = ""
        guard start != nil else { dropReason = "no slice running"; return nil }
        let limited = rateLimited || extraRateLimited
        let bad = failed || extraFailed
        if stalled || stalledOverride { dropReason = "stalled"; return nil }
        if contaminated { dropReason = "a download ran during the slice"; return nil }
        guard let b = baseline else { dropReason = "no data"; return nil }
        guard let end = endAtLastProgress ? lastProgress : last, end.time > b.time, end.bytes > b.bytes else {
            dropReason = "no data"; return nil          // a slice that measured nothing is neither a reward nor a penalty
        }
        return Reading(bytes: end.bytes - b.bytes, duration: end.time.timeIntervalSince(b.time), rateLimited: limited, failed: bad && !limited)
    }

    /// The counter at the last sample, to carry a slice on into the next one unchanged.
    public var lastBytes: Int64? { last?.bytes }
}
