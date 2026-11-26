import Foundation

/// Turns the stream of `vfs/queue` + `core/stats` samples into upload batches for the `TransfersBandit`.
///
/// A batch starts when the queue goes empty -> non-empty and ends when it drains. Pure: the caller passes
/// the clock. Bytes are the growth of rclone's cumulative `core/stats` counter (capped by the queued file
/// sizes, so a download that runs meanwhile cannot inflate the reward).
///
/// Rate limits: rclone's pacer retries 429s silently, so a sustained retry signal in the queue (an entry's `tries` or
/// backoff `delay` rising at least twice; one retry alone is not enough, and a `delay` that merely waits out the
/// write-back time is not a signal) or a rising
/// error count whose new `lastError` looks like throttling marks the batch as rate limited. A `lastError` that
/// did not come with a rising error count is stale and ignored. Another error marks it failed. A hung backend shows no error at all: bytes stop while items are uploading; such a stalled
/// batch (and one with no progress for a long time) is dropped, never recorded as good or bad.
public struct TransfersBatchTracker {
    public enum Event: Equatable {
        /// A batch began with this many files / bytes in the queue; choose an arm now.
        case started(fileCount: Int, bytes: Int64)
        /// The batch ended. `nil` = ignored (stalled, idle too long, or no byte counter).
        case finished(UploadBatch?)
    }

    public var stallTimeout: TimeInterval = 90
    public var idleTimeout: TimeInterval = 600

    private struct Active {
        var start: Date
        var lastProgress: Date
        var lastCounter: Int64?
        var counted: Int64 = 0
        var files: [String: Int64] = [:]
        var baselineErrors: Int?
        /// Times an entry's `tries` or backoff `delay` went up between polls.
        /// A queue entry showed `tries` of at least 3 on two polls in a row: rclone keeps retrying the same upload.
        var heavyRetry = false
        var triesSeen: [String: Int] = [:]
        var throttled = false
        var failed = false
        var stalled = false
    }
    private var active: Active?

    public var isActive: Bool { active != nil }

    public init() {}

    /// Anchored throttling signals only: an HTTP 429 status, "rate limit", "too many requests", "slow down",
    /// "throttl". Not a bare "429" (a file name) and not "quota" (Drive's storageQuotaExceeded means the account
    /// is full).
    public static func looksRateLimited(_ text: String) -> Bool {
        let t = text.lowercased()
        if ["ratelimit", "rate limit", "rate_limit", "too many requests", "throttl", "slow down", "slowdown"].contains(where: { t.contains($0) }) {
            return true
        }
        return t.range(of: #"(http|https|status|code|error|response)[^a-z0-9]{0,8}429(?![0-9])|(?<![a-z0-9.])429 (too|error)"#,
                       options: .regularExpression) != nil
    }

    /// What last raised a rate-limit signal, for the debug log (no names or secrets).
    public private(set) var lastSignal = ""

    private static func retrying(_ a: Active) -> Bool { a.heavyRetry }

    public mutating func observe(queue: VFSQueue, stats: RcloneStats?, now: Date) -> Event? {
        let entries = queue.queue.filter { !TransferProgress.isSidecar($0.name ?? "") }
        if active == nil {
            guard !entries.isEmpty else { return nil }
            var a = Active(start: now, lastProgress: now, lastCounter: stats?.bytes)
            a.baselineErrors = stats?.errors
            active = a
            absorb(entries, stats: stats, now: now)
            let a2 = active!
            return .started(fileCount: a2.files.count, bytes: a2.files.values.reduce(0, +))
        }
        absorb(entries, stats: stats, now: now)
        guard var a = active else { return nil }
        if entries.isEmpty {
            active = nil
            if a.stalled || a.lastCounter == nil { return .finished(nil) }
            let queued = a.files.values.reduce(0, +)
            let bytes = queued > 0 ? min(a.counted, queued) : a.counted
            let end = a.lastProgress > a.start ? a.lastProgress : now
            return .finished(UploadBatch(bytes: bytes, duration: end.timeIntervalSince(a.start),
                                         fileCount: a.files.count,
                                         rateLimited: a.throttled || (Self.retrying(a) && !a.failed),
                                         failed: a.failed))
        }
        if stats?.bytes != nil {
            let quiet = now.timeIntervalSince(a.lastProgress)
            if quiet >= idleTimeout { active = nil; return .finished(nil) }
            if quiet >= stallTimeout, entries.contains(where: { $0.uploading == true }) {
                a.stalled = true
                active = a
            }
        }
        return nil
    }

    /// Rate-limit and failure signals seen since the last call (then cleared), so each time slice gets its own.
    public mutating func takeFlags() -> (rateLimited: Bool, failed: Bool) {
        guard var a = active else { return (false, false) }
        let flags = (a.throttled || (Self.retrying(a) && !a.failed), a.failed)
        a.throttled = false; a.heavyRetry = false; a.failed = false
        active = a
        return flags
    }

    private mutating func absorb(_ entries: [VFSQueue.Entry], stats: RcloneStats?, now: Date) {
        guard var a = active else { return }
        for e in entries {
            let key = e.id.map(String.init) ?? e.name ?? "?"
            a.files[key] = max(a.files[key] ?? 0, e.size ?? 0)
            let tries = e.tries ?? 0
            if let before = a.triesSeen[key], before >= 3, tries >= 3 {
                a.heavyRetry = true
                lastSignal = "tries \(tries) on one upload across polls"
            }
            a.triesSeen[key] = tries
        }
        if let counter = stats?.bytes {
            if let last = a.lastCounter {
                if counter > last {
                    a.counted += counter - last
                    a.lastProgress = now
                    a.stalled = false
                }
            } else {
                a.lastProgress = now
            }
            a.lastCounter = counter
        }
        if let errors = stats?.errors {
            if let base = a.baselineErrors, errors > base {
                if let text = stats?.lastError, Self.looksRateLimited(text) { a.throttled = true; lastSignal = "new error with a throttling message" } else { a.failed = true }
                a.baselineErrors = errors
            } else if a.baselineErrors == nil {
                a.baselineErrors = errors
            }
        }
        active = a
    }
}
