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

/// Drives rclone's `--transfers` for one mounted remote: watches its upload queue, picks a value with the
/// bandit when a batch starts (applied live with `options/set`), and learns from the batch when it ends.
@MainActor
public final class TransfersController {
    public private(set) var currentArm: Int
    public private(set) var bandit: TransfersBandit
    private var tracker = TransfersBatchTracker()
    private let remoteID: UUID
    private let store: TransfersBanditStore
    private let client: RcloneControlClient
    private let clock: () -> Date
    private let log: (String) -> Void
    private let onChange: (Int) -> Void
    private var bucket: WorkloadBucket = .large
    private var busy = false

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
        let state = store.load(remote: remote.id.uuidString) ?? BanditState()
        self.bandit = TransfersBandit(configuration: .forBackend(remote.transfersBackendID), state: state,
                                      clock: clock, random: random)
        onChange(startingArm)
    }

    public nonisolated static func debugLog(_ message: String) {
        Logger(subsystem: "ai.rmount", category: "transfers").debug("\(message, privacy: .public)")
    }

    /// Feed one queue/stats sample. Samples that arrive while an arm change is in flight are dropped.
    public func observe(queue: VFSQueue, stats: RcloneStats?) async {
        guard !busy else { return }
        guard let event = tracker.observe(queue: queue, stats: stats, now: clock()) else { return }
        switch event {
        case .started(let files, let bytes):
            bucket = WorkloadBucket.bucket(bytes: bytes, fileCount: files,
                                           smallFileThreshold: bandit.configuration.smallFileThreshold)
            let arm = bandit.chooseArm(for: bucket)
            guard arm != currentArm else { return }
            busy = true
            defer { busy = false }
            do {
                try await client.setTransfers(arm)
                log("transfers \(remoteID.uuidString) bucket=\(bucket.rawValue) \(currentArm) -> \(arm)")
                currentArm = arm
                onChange(arm)
            } catch {
                log("transfers \(remoteID.uuidString) could not set \(arm), keeping \(currentArm)")
            }
        case .finished(let batch):
            guard let batch else {
                log("transfers \(remoteID.uuidString) batch ignored (stalled or no counter)")
                return
            }
            bandit.record(batch, arm: currentArm, bucket: bucket)
            do { try store.save(bandit.state, remote: remoteID.uuidString) }
            catch { log("transfers \(remoteID.uuidString) could not save state") }
        }
    }
}
