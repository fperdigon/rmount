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

/// Drives rclone's `--transfers` for one mounted remote. The value for the next batch is chosen with the bandit
/// while idle (first sample after mount, and right after a batch ends) and applied live with `options/set`, so it
/// is in force when the first byte is written.
///
/// Learning uses rclone's own transfer records (`core/transferred`, with start and completion times), not the
/// timing of our polls: transfers that follow each other form a batch whose span is first start to last
/// completion, however late it is noticed (a whole batch can happen between two idle polls). The batch is
/// credited to the arm that was in force over its whole span; one that straddles an arm change is dropped. When
/// the records are missing or empty, it falls back to timing batches from the queue and stats polls.
@MainActor
public final class TransfersController {
    /// When an arm became active: `before` is when we asked rclone, `after` when it answered.
    struct ArmChange: Equatable { var before: Date; var after: Date; var arm: Int }

    public internal(set) var currentArm: Int
    public private(set) var bandit: TransfersBandit
    private var tracker = TransfersBatchTracker()
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
    /// Nothing has been chosen for the next batch yet.
    private var needsPrepare = true
    /// Fallback mode only: the arm in force when the running batch started.
    private var armAtStart: Int?
    /// Rate-limit / failure / stall verdicts from the queue tracker, applied to the next batch built from records.
    private var pendingRateLimited = false
    private var pendingFailed = false
    private var pendingIgnore = false

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
                log: @escaping (String) -> Void = TransfersController.debugLog,
                onChange: @escaping (Int) -> Void = { _ in }) {
        self.remoteID = remote.id
        self.store = store
        self.client = client
        self.clock = clock
        self.log = log
        self.onChange = onChange
        self.currentArm = startingArm
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
        guard !busy else { return }
        let entries = queue.queue.filter { !TransferProgress.isSidecar($0.name ?? "") }
        let event = tracker.observe(queue: queue, stats: stats, now: clock())
        switch event {
        case .started?:
            pendingRateLimited = false; pendingFailed = false; pendingIgnore = false
            armAtStart = currentArm
            needsPrepare = false
        case .finished(let batch)?:
            if let batch { pendingRateLimited = batch.rateLimited; pendingFailed = batch.failed } else { pendingIgnore = true }
        case nil:
            break
        }
        if let transferred { builder.add(transferred) }
        if builder.hasPending {
            for built in builder.finish(now: clock(), queueEmpty: entries.isEmpty,
                                        uploading: entries.contains { $0.uploading == true }) {
                learn(built)
            }
        }
        if case .finished(let batch)? = event {
            needsPrepare = true
            if !builder.hasProduced { learnFromPolling(batch) }   // no usable records: time it from the polls
            armAtStart = nil
        }
        if needsPrepare, entries.isEmpty, !tracker.isActive { await prepareNext() }
    }

    private func learn(_ built: RecordedBatch) {
        needsPrepare = true
        var batch = built.batch
        batch.rateLimited = batch.rateLimited || pendingRateLimited
        batch.failed = batch.failed || pendingFailed
        let ignore = pendingIgnore
        pendingRateLimited = false; pendingFailed = false; pendingIgnore = false
        guard !ignore else { log("transfers \(remoteID.uuidString) batch ignored (stalled or no counter)"); return }
        guard let arm = armInForce(from: built.start, to: built.end) else {
            log("transfers \(remoteID.uuidString) batch discarded (arm changed during it)")
            return
        }
        bucket = WorkloadBucket.bucket(bytes: batch.bytes, fileCount: batch.fileCount,
                                       smallFileThreshold: bandit.configuration.smallFileThreshold)
        bandit.record(batch, arm: arm, bucket: bucket)
        save()
    }

    private func learnFromPolling(_ batch: UploadBatch?) {
        guard let batch else { log("transfers \(remoteID.uuidString) batch ignored (stalled or no counter)"); return }
        guard let startArm = armAtStart, startArm == currentArm else {
            log("transfers \(remoteID.uuidString) batch discarded (arm changed during it)")
            return
        }
        bucket = WorkloadBucket.bucket(bytes: batch.bytes, fileCount: batch.fileCount,
                                       smallFileThreshold: bandit.configuration.smallFileThreshold)
        bandit.record(batch, arm: startArm, bucket: bucket)
        save()
    }

    private func save() {
        do { try store.save(bandit.state, remote: remoteID.uuidString) }
        catch { log("transfers \(remoteID.uuidString) could not save state") }
    }

    /// The arm in force during the whole of `start...end`, or nil when it changed within that span.
    func armInForce(from start: Date, to end: Date) -> Int? {
        guard let i = armLog.lastIndex(where: { $0.after <= start }) else { return nil }
        if armLog.dropFirst(i + 1).contains(where: { $0.before <= end }) { return nil }
        return armLog[i].arm
    }

    /// Chooses the arm for the next batch and puts it in force now, while nothing is uploading.
    private func prepareNext() async {
        needsPrepare = false
        let arm = bandit.chooseArm(for: bucket)
        guard arm != currentArm else { return }
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
        } catch {
            log("transfers \(remoteID.uuidString) could not set \(arm), keeping \(currentArm)")
        }
    }
}
