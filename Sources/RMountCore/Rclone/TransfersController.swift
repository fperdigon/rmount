import Foundation
import os

public extension BanditConfiguration {
    /// Google Drive rate limits (403/429 user-rate-limit) show up quickly with many parallel uploads, so its
    /// arms stop at 8; other backends can explore up to 16.
    static let maxArmForDrive = 8

    static func forBackend(_ backendID: String) -> BanditConfiguration {
        let all = BanditConfiguration().arms
        let cap = backendID.lowercased() == "drive" ? maxArmForDrive : Int.max
        let arms = all.filter { $0 <= cap }
        return BanditConfiguration(arms: arms, startingArm: min(prior(forBackend: backendID), cap))
    }
}

public extension Remote {
    /// Backend id used for the bandit's prior and arm cap ("sftp", "s3", "ftp", or the rclone type).
    var transfersBackendID: String {
        switch backend {
        case .sftp: return "sftp"
        case .s3: return "s3"
        case .ftp: return "ftp"
        case .rclone(let cfg): return cfg.type
        }
    }
}

/// Drives rclone's `--transfers` for one mounted remote with time-sliced decisions.
///
/// `--transfers` can be changed live (`options/set`, a few seconds), so the choice is not made once per batch but
/// once per slice of about a minute of active uploads: a long copy re-evaluates every minute. A "pull" asks the
/// bandit for an arm and applies it at the start of each slice; the arm for the first slice of a batch is pulled
/// while idle (at mount and as soon as a batch ends), so it is in force when the first byte is written. A batch
/// shorter than a slice counts as one slice. Each slice is measured by `TransfersSliceMeter` from rclone's byte
/// counter (skipping a short warm-up after an arm change) and fed to the bandit under the arm that ran it; the
/// arm only changes at slice edges, so a slice never mixes two arms.
///
/// A batch that starts and ends between two idle polls is never seen as active; it is rebuilt from rclone's own
/// `core/transferred` records (start and completion times) and credited as one slice to the arm in force over
/// its span, unless it overlaps a period the slices already measured.
@MainActor
public final class TransfersController {
    /// When an arm became active: `before` is when we asked rclone, `after` when it answered.
    struct ArmChange: Equatable { var before: Date; var after: Date; var arm: Int }

    public internal(set) var currentArm: Int
    public private(set) var bandit: TransfersBandit
    private var tracker = TransfersBatchTracker()
    private var meter: TransfersSliceMeter
    private var builder = TransfersBatchBuilder()
    private(set) var armLog: [ArmChange]
    private let remoteID: UUID
    private let store: TransfersBanditStore
    private let client: RcloneControlClient
    private let clock: () -> Date
    private let log: (String) -> Void
    private let onChange: (Int) -> Void
    private var bucket: WorkloadBucket = .large
    private var busy = false
    /// The remote was unmounted or deleted: nothing more is applied or saved (its state file may be gone).
    private var stopped = false
    /// Nothing has been chosen for the next batch yet.
    private var needsPrepare = true
    private var sliceFiles = 1
    /// Periods the slices measured (batch start ... last sample), so record-built batches do not count twice.
    private var observed: [(start: Date, end: Date)] = []
    private var batchStart: Date?
    /// At least one slice of the running batch was counted by the bandit.
    private var batchMeasured = false
    private var loggedRetentionDrops = 0

    /// The arm to start rclone with (`--transfers`): the best known one, or the backend's prior.
    public static func startupArm(for remote: Remote, store: TransfersBanditStore) -> Int {
        let config = BanditConfiguration.forBackend(remote.transfersBackendID)
        let state = store.load(remote: remote.id.uuidString) ?? BanditState()
        let bandit = TransfersBandit(configuration: config, state: state, random: { 0 })
        // The bucket with the most history decides; ties and no history fall back to the prior.
        let best = WorkloadBucket.allCases.max { (state.buckets[$0.rawValue]?.batches ?? 0) < (state.buckets[$1.rawValue]?.batches ?? 0) } ?? .large
        return bandit.bestArm(for: best)
    }

    public init(remote: Remote, startingArm: Int, store: TransfersBanditStore, client: RcloneControlClient,
                random: @escaping () -> Double = { Double.random(in: 0..<1) },
                clock: @escaping () -> Date = Date.init,
                sliceLength: TimeInterval = 60,
                log: @escaping (String) -> Void = TransfersController.debugLog,
                onChange: @escaping (Int) -> Void = { _ in }) {
        self.remoteID = remote.id
        self.store = store
        self.client = client
        self.clock = clock
        self.log = log
        self.onChange = onChange
        self.currentArm = startingArm
        var m = TransfersSliceMeter(); m.length = sliceLength; self.meter = m
        self.armLog = [ArmChange(before: .distantPast, after: .distantPast, arm: startingArm)]
        let state = store.load(remote: remote.id.uuidString) ?? BanditState()
        self.bandit = TransfersBandit(configuration: .forBackend(remote.transfersBackendID), state: state,
                                      clock: clock, random: random)
        onChange(startingArm)
    }

    public nonisolated static func debugLog(_ message: String) {
        Logger(subsystem: "ai.rmount", category: "transfers").debug("\(message, privacy: .public)")
    }

    /// Feed one sample: the queue, core stats and (when available) rclone's completed-transfer records.
    /// Samples that arrive while an arm change is in flight are dropped.
    public func observe(queue: VFSQueue, stats: RcloneStats?, transferred: [CompletedTransfer]? = nil) async {
        guard !busy, !stopped else { return }
        let now = clock()
        let entries = queue.queue.filter { !TransferProgress.isSidecar($0.name ?? "") }
        let event = tracker.observe(queue: queue, stats: stats, now: now)
        let flags = tracker.takeFlags()
        if case .started(let files, let bytes)? = event {
            sliceFiles = max(files, 1)
            let newBucket = WorkloadBucket.bucket(bytes: bytes, fileCount: files,
                                                  smallFileThreshold: bandit.configuration.smallFileThreshold)
            if newBucket != bucket {
                // The idle pull chose this arm for the previous batch's bucket: choose again for the bucket this batch
                // really is, so the slice is credited to an arm picked for it.
                bucket = newBucket
                let arm = bandit.chooseArm(for: newBucket)
                if await !apply(arm), arm != currentArm { bandit.retract(bucket: newBucket) }
            }
            batchStart = now
            batchMeasured = false
            needsPrepare = false
            meter.begin(at: now, warmup: 0)
        }
        if meter.isActive {
            let queued = Set(entries.compactMap(\.name))
            let foreign = stats?.transferring.contains { t in
                guard let n = t.name else { return false }
                return !queued.contains(n) && !TransferProgress.isSidecar(n)
            } ?? false
            meter.sample(time: now, bytes: stats?.bytes, contaminated: foreign, rateLimited: flags.rateLimited, failed: flags.failed)
        }
        if let transferred {
            builder.add(transferred)
            if builder.droppedForRetention > loggedRetentionDrops {
                log("transfers \(remoteID.uuidString) \(builder.droppedForRetention - loggedRetentionDrops) records dropped: rclone's list was full")
                loggedRetentionDrops = builder.droppedForRetention
            }
        }
        if case .finished(let batch)? = event {
            closeSlice(extraRateLimited: batch?.rateLimited ?? false, extraFailed: batch?.failed ?? false,
                       stalled: batch == nil, final: true)
            // Only a batch the slices really measured is excluded from the records rebuild: one seen just at its
            // tail (dropped as too short) is still credited from the records; a stalled one is never credited.
            if let s = batchStart, batchMeasured || batch == nil { observed.append((s, now)); if observed.count > 16 { observed.removeFirst() } }
            batchStart = nil
            batchMeasured = false
            needsPrepare = true
        } else if meter.isActive, meter.isDue(now: now) {
            closeSlice()
            await pull(from: now, carry: stats?.bytes)
        }
        if builder.hasPending {
            for built in builder.finish(now: clock(), queueEmpty: entries.isEmpty,
                                        uploading: entries.contains { $0.uploading == true }) {
                learn(built)
            }
        }
        if needsPrepare, entries.isEmpty, !tracker.isActive { await pullIdle() }
    }

    private func closeSlice(extraRateLimited: Bool = false, extraFailed: Bool = false, stalled: Bool = false, final: Bool = false) {
        guard let reading = meter.finish(extraRateLimited: extraRateLimited, extraFailed: extraFailed, stalledOverride: stalled,
                                         endAtLastProgress: final) else {
            log("transfers \(remoteID.uuidString) slice ignored: \(meter.dropReason)")
            return
        }
        let slice = UploadBatch(bytes: reading.bytes, duration: reading.duration, fileCount: sliceFiles,
                                rateLimited: reading.rateLimited, failed: reading.failed)
        if let why = bandit.rejectionReason(for: slice, arm: currentArm) {
            log("transfers \(remoteID.uuidString) slice ignored: \(why)")
            return
        }
        bandit.record(slice, arm: currentArm, bucket: bucket)
        batchMeasured = true
        save()
    }

    /// Slice edge while uploads continue: choose the arm for the next slice, apply it live and start measuring.
    private func pull(from now: Date, carry: Int64?) async {
        let arm = bandit.chooseArm(for: bucket)
        let changed = await apply(arm)
        if !changed, arm != currentArm { bandit.retract(bucket: bucket) }
        // After a change, uploads already running keep their old concurrency for a while: skip the warm-up.
        meter.begin(at: clock(), warmup: changed ? meter.warmup : 0, baseline: changed ? nil : carry)
    }

    /// Chooses the arm for the next batch and puts it in force now, while nothing is uploading.
    private func pullIdle() async {
        needsPrepare = false
        let arm = bandit.chooseArm(for: bucket)
        if await !apply(arm), arm != currentArm { bandit.retract(bucket: bucket) }
    }

    private func apply(_ arm: Int) async -> Bool {
        guard arm != currentArm else { return false }
        busy = true
        defer { busy = false }
        let before = clock()
        do {
            try await client.setTransfers(arm)
            log("transfers \(remoteID.uuidString) bucket=\(bucket.rawValue) \(currentArm) -> \(arm)")
            currentArm = arm
            armLog.append(ArmChange(before: before, after: clock(), arm: arm))
            if armLog.count > 32 { armLog.removeFirst(armLog.count - 32) }
            onChange(arm)
            return true
        } catch {
            log("transfers \(remoteID.uuidString) could not set \(arm), keeping \(currentArm)")
            return false
        }
    }

    /// A batch that happened wholly between two polls: one slice, credited to the arm in force over its span.
    private func learn(_ built: RecordedBatch) {
        needsPrepare = true
        if observed.contains(where: { built.start < $0.end.addingTimeInterval(2) && built.end > $0.start.addingTimeInterval(-2) })
            || (batchStart.map { built.end > $0.addingTimeInterval(-2) } ?? false) {
            log("transfers \(remoteID.uuidString) recorded batch skipped: the slices measured it")
            return
        }
        guard let arm = armInForce(from: built.start, to: built.end) else {
            log("transfers \(remoteID.uuidString) batch discarded (arm changed during it)")
            return
        }
        bucket = WorkloadBucket.bucket(bytes: built.batch.bytes, fileCount: built.batch.fileCount,
                                       smallFileThreshold: bandit.configuration.smallFileThreshold)
        if let why = bandit.rejectionReason(for: built.batch, arm: arm) {
            log("transfers \(remoteID.uuidString) recorded batch ignored: \(why)")
            return
        }
        bandit.record(built.batch, arm: arm, bucket: bucket)
        save()
    }

    /// Stops the controller for good (unmount or delete): later samples are ignored and nothing is saved again.
    public func stop() { stopped = true }

    private func save() {
        guard !stopped else { return }
        do { try store.save(bandit.state, remote: remoteID.uuidString) }
        catch { log("transfers \(remoteID.uuidString) could not save state") }
    }

    /// The arm in force during the whole of `start...end`, or nil when it changed within that span.
    func armInForce(from start: Date, to end: Date) -> Int? {
        guard let i = armLog.lastIndex(where: { $0.after <= start }) else { return nil }
        if armLog.dropFirst(i + 1).contains(where: { $0.before <= end }) { return nil }
        return armLog[i].arm
    }
}
