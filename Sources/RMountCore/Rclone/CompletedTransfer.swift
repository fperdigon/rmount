import Foundation

/// One finished transfer from rclone's rc `core/transferred` (a VFS write-back upload is one of these).
/// rclone keeps only the most recent ~100, oldest first, and stamps them with its own clock, so a batch can be
/// timed exactly however late it is polled.
public struct CompletedTransfer: Equatable {
    public var name: String
    public var size: Int64
    public var bytes: Int64
    public var error: String
    public var started: Date
    public var completed: Date

    public init(name: String, size: Int64, bytes: Int64, error: String = "", started: Date, completed: Date) {
        self.name = name; self.size = size; self.bytes = bytes; self.error = error
        self.started = started; self.completed = completed
    }

    /// Identity of a record between two polls (names repeat when a file is uploaded again).
    var key: String { "\(name)|\(started.timeIntervalSince1970)|\(completed.timeIntervalSince1970)" }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parseDate(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    /// Tolerant parse of the `core/transferred` response body: records that are malformed, have no usable
    /// timestamps (an unfinished transfer carries year 1) or end before they start are skipped.
    public static func parse(_ data: Data) -> [CompletedTransfer] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["transferred"] as? [Any] else { return [] }
        let floor = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01
        return list.compactMap { item in
            guard let o = item as? [String: Any],
                  let s = (o["started_at"] as? String).flatMap(parseDate),
                  let c = (o["completed_at"] as? String).flatMap(parseDate),
                  s > floor, c >= s else { return nil }
            func int(_ k: String) -> Int64 { (o[k] as? NSNumber)?.int64Value ?? 0 }
            return CompletedTransfer(name: o["name"] as? String ?? "", size: int("size"), bytes: int("bytes"),
                                     error: o["error"] as? String ?? "", started: s, completed: c)
        }
    }
}

/// A batch rebuilt from rclone's own transfer records.
public struct RecordedBatch: Equatable {
    public var start: Date
    public var end: Date
    public var batch: UploadBatch
}

/// Turns completed-transfer records into batches: transfers that follow each other with gaps of at most `gap`
/// seconds are one batch, spanning the earliest start to the latest completion. Pure; the caller passes the
/// clock. Records are de-duplicated between polls. If a poll returns a full list of nothing but new records,
/// older ones may have been pushed out of rclone's retention, so those records are dropped rather than
/// timed as a partial batch.
public struct TransfersBatchBuilder {
    public var gap: TimeInterval = 10
    public var retention = 100
    /// A batch with transfers still in the queue is closed after this long without a completion.
    public var closeAfter: TimeInterval = 30

    private var seen: Set<String> = []
    private var buffer: [CompletedTransfer] = []
    /// True once a batch was built from records (so an empty or missing list is not mistaken for support).
    public private(set) var hasProduced = false
    public private(set) var droppedForRetention = 0

    public init() {}

    public var hasPending: Bool { !buffer.isEmpty }

    public mutating func add(_ records: [CompletedTransfer]) {
        let useful = records.filter { !TransferProgress.isSidecar($0.name) }
        let fresh = useful.filter { !seen.contains($0.key) }
        if !seen.isEmpty, records.count >= retention, records.allSatisfy({ !seen.contains($0.key) }) {
            droppedForRetention += fresh.count
        } else {
            buffer += fresh
        }
        seen = Set(records.map(\.key))
    }

    /// Batches that are complete: all but the newest cluster always (a gap follows them), and the newest one once
    /// the queue is empty, or nothing uploads and it ended `closeAfter` ago.
    public mutating func finish(now: Date, queueEmpty: Bool, uploading: Bool) -> [RecordedBatch] {
        guard !buffer.isEmpty else { return [] }
        let sorted = buffer.sorted { $0.started < $1.started }
        var clusters: [[CompletedTransfer]] = []
        var end = Date.distantPast
        for r in sorted {
            if let last = clusters.last, !last.isEmpty, r.started.timeIntervalSince(end) <= gap {
                clusters[clusters.count - 1].append(r)
            } else {
                clusters.append([r])
                end = .distantPast
            }
            end = max(end, r.completed)
        }
        var out: [RecordedBatch] = []
        for (i, c) in clusters.enumerated() {
            let cEnd = c.map(\.completed).max()!
            let isLast = i == clusters.count - 1
            if isLast, !(queueEmpty || (!uploading && now.timeIntervalSince(cEnd) > closeAfter)) { break }
            out.append(Self.batch(from: c))
        }
        let keep = clusters.dropFirst(out.count).flatMap { $0 }
        buffer = Array(keep)
        if !out.isEmpty { hasProduced = true }
        return out
    }

    private static func batch(from c: [CompletedTransfer]) -> RecordedBatch {
        let start = c.map(\.started).min()!
        let end = c.map(\.completed).max()!
        let ok = c.filter { $0.error.isEmpty }
        let errors = c.filter { !$0.error.isEmpty }
        let throttled = errors.contains { TransfersBatchTracker.looksRateLimited($0.error) }
        let failed = !errors.isEmpty && !throttled
        let bytes = ok.reduce(Int64(0)) { $0 + $1.bytes }
        return RecordedBatch(start: start, end: end,
                             batch: UploadBatch(bytes: bytes, duration: end.timeIntervalSince(start), fileCount: ok.count,
                                                rateLimited: throttled, failed: failed))
    }
}
