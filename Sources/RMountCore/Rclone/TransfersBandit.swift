import Foundation

/// What one finished upload batch (queue went empty -> busy -> empty) looked like.
public struct UploadBatch: Equatable {
    public var bytes: Int64
    public var duration: TimeInterval
    public var fileCount: Int
    /// The server answered 429 / "too many requests" / quota throttling during the batch.
    public var rateLimited: Bool
    /// Any other failure; such a batch says nothing about the arm and is ignored.
    public var failed: Bool

    public init(bytes: Int64, duration: TimeInterval, fileCount: Int, rateLimited: Bool = false, failed: Bool = false) {
        self.bytes = bytes; self.duration = duration; self.fileCount = fileCount
        self.rateLimited = rateLimited; self.failed = failed
    }
}

/// Workload context; each bucket learns its own arm statistics.
public enum WorkloadBucket: String, Codable, CaseIterable {
    case small, large
    public static func bucket(bytes: Int64, fileCount: Int, smallFileThreshold: Int64) -> WorkloadBucket {
        let avg = bytes / Int64(max(fileCount, 1))
        return avg < smallFileThreshold ? .small : .large
    }
}

/// EWMA of the reward (MB/s) of one arm, and how many batches fed it.
public struct ArmStats: Codable, Equatable {
    public var mean: Double
    /// Samples that fed the mean, penalties included.
    public var count: Int
    /// Real measured throughput samples (no penalties): what an arm needs to be trusted below the safe floor.
    public var real: Int
    /// The mean before the current run of penalties began; a penalty never goes below a quarter of it.
    public var unpenalised: Double?
    public init(mean: Double = 0, count: Int = 0, real: Int? = nil, unpenalised: Double? = nil) {
        self.mean = mean; self.count = count; self.real = real ?? count; self.unpenalised = unpenalised
    }
    private enum CodingKeys: String, CodingKey { case mean, count, real, unpenalised }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mean = try c.decode(Double.self, forKey: .mean)
        count = try c.decode(Int.self, forKey: .count)
        real = (try? c.decodeIfPresent(Int.self, forKey: .real)) ?? count
        unpenalised = try? c.decodeIfPresent(Double.self, forKey: .unpenalised)
    }
}

public struct BucketState: Codable, Equatable {
    /// Keyed by the arm value as a string so the JSON stays a plain object.
    public var stats: [String: ArmStats] = [:]
    public var lastReward: Double?
    public var lastExplored: Date
    public var batches: Int = 0
    /// Systematic probes handed out so far (bounded, so an arm whose batches are never valid cannot be probed forever).
    public var probes: Int = 0

    public init(lastExplored: Date) { self.lastExplored = lastExplored }

    private enum CodingKeys: String, CodingKey { case stats, lastReward, lastExplored, batches, probes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stats = (try? c.decodeIfPresent([String: ArmStats].self, forKey: .stats)) ?? [:]
        lastReward = try? c.decodeIfPresent(Double.self, forKey: .lastReward)
        lastExplored = (try? c.decodeIfPresent(Date.self, forKey: .lastExplored)) ?? Date()
        batches = (try? c.decodeIfPresent(Int.self, forKey: .batches)) ?? 0
        probes = (try? c.decodeIfPresent(Int.self, forKey: .probes)) ?? 0
    }
}

/// The persisted part of the bandit: one small JSON per remote.
public struct BanditState: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int = BanditState.currentVersion
    public var buckets: [String: BucketState] = [:]

    public init() {}
    private enum CodingKeys: String, CodingKey { case version, buckets }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? BanditState.currentVersion
        buckets = (try? c.decodeIfPresent([String: BucketState].self, forKey: .buckets)) ?? [:]
    }
}

public struct BanditConfiguration: Equatable {
    public var arms: [Int] = BanditConfiguration.defaultArms
    /// Arm used until something was measured; snapped to the nearest arm, and never below `minStartingArm`.
    public var startingArm: Int = 4
    public static let minStartingArm = 4
    /// Exploration never stops: every batch has this chance of trying an adjacent arm of the best.
    public var epsilon: Double = 0.2
    /// When exploring: this share picks an arm next to the best, the rest any other arm uniformly.
    public var adjacentShare: Double = 0.7
    public var ewmaAlpha: Double = 0.3
    /// A reward below this fraction of an arm's mean counts for more (a global drop is not noise).
    public var dropSurprise: Double = 0.7
    public var dropWeight: Double = 0.5
    /// Ageing: when a sample falls far below its own arm's mean (the link may have got slower as a whole), every
    /// other arm whose mean is higher than that sample is pulled this far toward it, so a stale best arm cannot
    /// keep reading best. Arms are corrected upward again as soon as they are sampled.
    public var ageing: Double = 0.5
    /// Below the safe floor an arm is only exploited after this many real samples beating the floor arm by this margin.
    public var trustSamples: Int = 3
    public var trustMargin: Double = 0.15
    /// A penalty never takes an arm below this share of its pre-penalty mean.
    public var penaltyFloor: Double = 0.25
    /// A batch counts when it lasted at least `minBatchDuration` and either moved `minBatchBytes` (a fast arm
    /// finishes a big batch quickly) or ran for `minLongBatchDuration` (a slow one moves fewer bytes).
    public var minBatchBytes: Int64 = 100_000_000
    public var minBatchDuration: TimeInterval = 5
    public var minLongBatchDuration: TimeInterval = 20
    /// Even a long batch must have moved this much, or it measured latency, not throughput.
    public var minLongBatchBytes: Int64 = 10_000_000
    /// Until the best arm and each neighbour have this many samples, probe instead of exploiting.
    public var probeSamples: Int = 2
    /// Upper bound on systematic probes per bucket.
    public var maxProbes: Int = 14
    /// A rate-limited batch multiplies the arm's mean by this.
    public var rateLimitFactor: Double = 0.25
    public var smallFileThreshold: Int64 = 8_000_000

    /// Fine at the low end (where most links peak) and wide enough for slow, high-latency ones.
    public static let defaultArms = [1, 2, 3, 4, 6, 8, 10, 12, 16, 24]

    public init(arms: [Int] = BanditConfiguration.defaultArms, startingArm: Int = 4) {
        self.arms = arms.sorted(); self.startingArm = startingArm
    }

    /// Rough per-backend starting points (a prior only; measurements override it).
    public static func prior(forBackend id: String) -> Int {
        switch id.lowercased() {
        case "sftp", "ftp", "smb": return 4
        // rclone type strings as the app uses them (`BackendDescriptor.type`): "google cloud storage" has spaces.
        case "s3", "azureblob", "b2", "gcs", "google cloud storage", "googlecloudstorage", "drive": return 8
        default: return 4
        }
    }
}

/// Epsilon-greedy bandit choosing rclone's `--transfers` once per upload batch, per remote and workload
/// bucket. Pure: no I/O, clock and randomness are injected; `TransfersController` wires it to a mount.
///
/// Flow: for every slice of upload time (about a minute) call `chooseArm(for:)`, apply the value (live via rc
/// `options/set`, and `--transfers` at the next start), and when the slice ends call `record(_:arm:)` with what it moved. A cold start probes
/// the starting arm and its neighbours first; after that, with a constant probability `epsilon` (1 in 5) it tries
/// a neighbour of the best arm, otherwise the best. Exploration never stops, so the choice follows the link
/// when it changes.
public struct TransfersBandit {
    /// Batches during which the choice stays within one arm of the starting arm.
    static let guardedBatches = 3
    public let configuration: BanditConfiguration
    public private(set) var state: BanditState
    private let clock: () -> Date
    private let random: () -> Double
    /// Buckets whose latest `chooseArm` handed out a systematic probe (so a failed apply can give it back).
    private var probed: Set<String> = []

    /// `random` must return values in [0, 1).
    public init(configuration: BanditConfiguration = BanditConfiguration(), state: BanditState = BanditState(),
                clock: @escaping () -> Date = Date.init, random: @escaping () -> Double) {
        self.configuration = configuration
        self.clock = clock
        self.random = random
        var s = state
        // Drop stats for arms that are no longer configured.
        let valid = Set(configuration.arms.map(String.init))
        for (k, var b) in s.buckets {
            b.stats = b.stats.filter { valid.contains($0.key) }
            s.buckets[k] = b
        }
        self.state = s
    }

    // MARK: Choosing

    public mutating func chooseArm(for bucket: WorkloadBucket) -> Int {
        var b = state.buckets[bucket.rawValue] ?? BucketState(lastExplored: clock())
        let best = bestArm(in: b)
        var chosen = best
        probed.remove(bucket.rawValue)
        if let probe = probeTarget(b, best: best) {
            chosen = probe
            b.probes += 1
            probed.insert(bucket.rawValue)
            b.lastExplored = clock()
        } else if configuration.epsilon > 0, random() < configuration.epsilon {
            // Mostly a step next to the best arm, sometimes a jump anywhere (a link can change a lot).
            let near = neighbours(of: best)
            let far = arms.filter { $0 != best }
            let pool = (random() < configuration.adjacentShare && !near.isEmpty) ? near : far
            if !pool.isEmpty {
                chosen = pool[min(Int(random() * Double(pool.count)), pool.count - 1)]
                b.lastExplored = clock()
            }
        }
        // In the first few batches, never wander more than one arm from the starting arm.
        if b.batches < Self.guardedBatches, let si = arms.firstIndex(of: startArm()), let ci = arms.firstIndex(of: chosen), abs(ci - si) > 1 {
            chosen = startArm()
        }
        state.buckets[bucket.rawValue] = b
        return chosen
    }

    /// The arm chosen last for `bucket` could not be applied: give back the probe it used, so the same probe is
    /// offered again at the next decision.
    public mutating func retract(bucket: WorkloadBucket) {
        guard probed.remove(bucket.rawValue) != nil, var b = state.buckets[bucket.rawValue], b.probes > 0 else { return }
        b.probes -= 1
        state.buckets[bucket.rawValue] = b
    }

    /// The arm with the highest mean, or the (snapped) starting arm when nothing was measured.
    public func bestArm(for bucket: WorkloadBucket) -> Int {
        bestArm(in: state.buckets[bucket.rawValue] ?? BucketState(lastExplored: clock()))
    }

    public func stats(for bucket: WorkloadBucket, arm: Int) -> ArmStats? {
        state.buckets[bucket.rawValue]?.stats[String(arm)]
    }

    private var arms: [Int] { configuration.arms }

    private func startArm() -> Int {
        let target = max(configuration.startingArm, BanditConfiguration.minStartingArm)
        return arms.min { abs($0 - target) < abs($1 - target) } ?? target
    }

    private func bestArm(in b: BucketState) -> Int {
        func top(_ candidates: [Int]) -> Int? {
            var best: (arm: Int, mean: Double)?
            for arm in candidates {
                guard let s = b.stats[String(arm)], s.count > 0 else { continue }
                if best == nil || s.mean > best!.mean { best = (arm, s.mean) }
            }
            return best?.arm
        }
        let floor = startArm()
        // Exploiting below the safe floor (the backend prior, never under 4) needs proof: at least `trustSamples`
        // real measurements that beat the floor arm's own mean by `trustMargin`. Penalties and thin data cannot do it.
        let floorMean = b.stats[String(floor)].flatMap { $0.count > 0 ? $0.mean : nil }
        let eligible = arms.filter { arm in
            if arm >= floor { return true }
            guard let s = b.stats[String(arm)], s.real >= configuration.trustSamples, let f = floorMean else { return false }
            return s.mean >= f * (1 + configuration.trustMargin)
        }
        return top(eligible) ?? floor
    }

    private func neighbours(of arm: Int) -> [Int] {
        guard let i = arms.firstIndex(of: arm) else { return [] }
        return [i - 1, i + 1].filter { arms.indices.contains($0) }.map { arms[$0] }
    }

    /// Systematic cold-start exploration: measure the best arm, then the least-sampled arm next to it
    /// (closest to the backend prior first) until each has `probeSamples`. When the best arm sits at the edge of
    /// what was measured, its unmeasured outer neighbour has no samples yet, so it is probed next: the search
    /// walks outward while it keeps improving and stops at the arm cap.
    private func probeTarget(_ b: BucketState, best: Int) -> Int? {
        guard b.probes < configuration.maxProbes else { return nil }
        if (b.stats[String(best)]?.count ?? 0) == 0 { return best }
        let start = startArm()
        return neighbours(of: best)
            .map { (arm: $0, count: b.stats[String($0)]?.count ?? 0) }
            .filter { $0.count < configuration.probeSamples }
            .min { ($0.count, abs($0.arm - start), $0.arm) < ($1.count, abs($1.arm - start), $1.arm) }?.arm
    }

    // MARK: Learning

    /// Why `record` would ignore this batch (for the debug log), or nil when it counts.
    public func rejectionReason(for batch: UploadBatch, arm: Int) -> String? {
        if !arms.contains(arm) { return "arm \(arm) is not in the arm set" }
        // Nothing measured says nothing about an arm: never a result, not even a penalty.
        if batch.bytes <= 0 || batch.duration <= 0 { return "no data" }
        if batch.rateLimited { return nil }
        if batch.failed { return "failed (not a rate limit)" }
        if batch.duration < configuration.minBatchDuration { return "too short (\(Int(batch.duration)) s)" }
        let enough = batch.bytes >= configuration.minBatchBytes
            || (batch.duration >= configuration.minLongBatchDuration && batch.bytes >= configuration.minLongBatchBytes)
        return enough ? nil : "too little data (\(batch.bytes / 1_000_000) MB in \(Int(batch.duration)) s)"
    }

    /// Records a finished slice (or batch) that ran with `arm`. Samples that are too small or short (see
    /// `rejectionReason`), or failed for other reasons, are ignored; a rate-limited one penalises the arm whatever
    /// its size. A sample far below its arm's mean also ages the other arms (see `BanditConfiguration.ageing`).
    /// Pass the `bucket` the arm was chosen for; by default it is derived from the batch's average file size.
    public mutating func record(_ batch: UploadBatch, arm: Int, bucket: WorkloadBucket? = nil) {
        guard arms.contains(arm) else { return }
        let bucket = bucket ?? WorkloadBucket.bucket(bytes: batch.bytes, fileCount: batch.fileCount,
                                                     smallFileThreshold: configuration.smallFileThreshold)
        var b = state.buckets[bucket.rawValue] ?? BucketState(lastExplored: clock())
        var s = b.stats[String(arm)] ?? ArmStats()
        var last: Double
        guard rejectionReason(for: batch, arm: arm) == nil else { return }
        let reward = Double(batch.bytes) / 1_000_000 / batch.duration
        if batch.rateLimited {
            // One penalty per slice, never below a quarter of the mean before the penalties began.
            let base = s.unpenalised ?? (s.real > 0 ? s.mean : reward)
            s.unpenalised = base
            let current = s.real > 0 ? s.mean : reward
            s.mean = max(current * configuration.rateLimitFactor, base * configuration.penaltyFloor)
            last = s.mean
        } else {
            s.unpenalised = nil
            s.real += 1
            // Count-weighted: early samples average out, later ones follow the EWMA so a drifting link is tracked
            // while one bad sample cannot dominate.
            var weight = s.count == 0 ? 1 : max(configuration.ewmaAlpha, 1 / Double(s.count + 1))
            let surprised = s.count > 0 && reward < s.mean * configuration.dropSurprise
            if surprised { weight = max(weight, configuration.dropWeight) }
            s.mean += weight * (reward - s.mean)
            last = reward
            if surprised {
                for (key, var other) in b.stats where key != String(arm) && other.count > 0 && other.mean > reward {
                    other.mean -= configuration.ageing * (other.mean - reward)
                    b.stats[key] = other
                }
            }
        }
        s.count += 1
        b.stats[String(arm)] = s
        b.lastReward = last
        b.batches += 1
        state.buckets[bucket.rawValue] = b
    }
}

/// A small seedable generator (SplitMix64) for deterministic tests and reproducible runs.
public final class SeededUnitRandom {
    private var s: UInt64
    public init(seed: UInt64) { s = seed }
    public func next() -> Double {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// Reads and writes one remote's `BanditState` as JSON under a directory (the caller picks it).
public struct TransfersBanditStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func fileURL(remote id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).transfers-bandit.json")
    }

    /// Nil when the file is missing, unreadable, corrupt or from a newer version: start fresh.
    public func load(remote id: String) -> BanditState? {
        guard let data = try? Data(contentsOf: fileURL(remote: id)),
              let state = try? Self.decoder.decode(BanditState.self, from: data),
              state.version <= BanditState.currentVersion else { return nil }
        return state
    }

    public func save(_ state: BanditState, remote id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: fileURL(remote: id), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
