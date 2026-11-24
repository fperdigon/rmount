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
    public var count: Int
    public init(mean: Double = 0, count: Int = 0) { self.mean = mean; self.count = count }
}

public struct BucketState: Codable, Equatable {
    /// Keyed by the arm value as a string so the JSON stays a plain object.
    public var stats: [String: ArmStats] = [:]
    public var lastReward: Double?
    public var lastExplored: Date
    public var batches: Int = 0

    public init(lastExplored: Date) { self.lastExplored = lastExplored }

    private enum CodingKeys: String, CodingKey { case stats, lastReward, lastExplored, batches }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stats = (try? c.decodeIfPresent([String: ArmStats].self, forKey: .stats)) ?? [:]
        lastReward = try? c.decodeIfPresent(Double.self, forKey: .lastReward)
        lastExplored = (try? c.decodeIfPresent(Date.self, forKey: .lastExplored)) ?? Date()
        batches = (try? c.decodeIfPresent(Int.self, forKey: .batches)) ?? 0
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
    public var arms: [Int] = [2, 4, 8, 12, 16]
    /// Arm used until something was measured; snapped to the nearest arm.
    public var startingArm: Int = 4
    public var epsilon: Double = 0.2
    /// The best arm "leads clearly" when it beats every neighbour by this fraction...
    public var clearLead: Double = 0.15
    /// ...and the best arm and each neighbour have at least this many samples.
    public var minSamplesToSettle: Int = 3
    public var ewmaAlpha: Double = 0.3
    /// Batches smaller or shorter than this are too noisy to learn from.
    public var minBatchBytes: Int64 = 50_000_000
    public var minBatchDuration: TimeInterval = 15
    /// A rate-limited batch multiplies the arm's mean by this.
    public var rateLimitFactor: Double = 0.25
    /// Exploring resumes when the last reward falls this far below the best mean...
    public var dropFraction: Double = 0.3
    /// ...or when this long passed without exploring.
    public var resumeAfter: TimeInterval = 7 * 24 * 3600
    public var smallFileThreshold: Int64 = 8_000_000

    public init(arms: [Int] = [2, 4, 8, 12, 16], startingArm: Int = 4) {
        self.arms = arms.sorted(); self.startingArm = startingArm
    }

    /// Rough per-backend starting points (a prior only; measurements override it).
    public static func prior(forBackend id: String) -> Int {
        switch id.lowercased() {
        case "sftp", "ftp", "smb": return 4
        case "s3", "azureblob", "b2", "gcs", "drive": return 8
        default: return 4
        }
    }
}

/// Epsilon-greedy bandit choosing rclone's `--transfers` once per upload batch, per remote and workload
/// bucket. Pure: no I/O, clock and randomness are injected. Not wired into mounts yet.
///
/// Flow: when the queue goes empty -> busy call `chooseArm(for:)`, apply the value (restart rclone or next
/// mount; see the options discussed in #123), and when the batch finishes call `record(_:arm:)`. With
/// probability `epsilon` it tries a neighbour of the best arm, otherwise the best. Exploration stops once
/// the best arm clearly leads its neighbours, and resumes after a long time or when the recent reward drops.
public struct TransfersBandit {
    public let configuration: BanditConfiguration
    public private(set) var state: BanditState
    private let clock: () -> Date
    private let random: () -> Double

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
        let eps = effectiveEpsilon(b, best: best)
        if eps > 0, random() < eps {
            let n = neighbours(of: best)
            if !n.isEmpty {
                chosen = n[min(Int(random() * Double(n.count)), n.count - 1)]
                b.lastExplored = clock()
            }
        }
        state.buckets[bucket.rawValue] = b
        return chosen
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
        arms.min { abs($0 - configuration.startingArm) < abs($1 - configuration.startingArm) } ?? configuration.startingArm
    }

    private func bestArm(in b: BucketState) -> Int {
        var best: (arm: Int, mean: Double)?
        for arm in arms {
            guard let s = b.stats[String(arm)], s.count > 0 else { continue }
            if best == nil || s.mean > best!.mean { best = (arm, s.mean) }
        }
        return best?.arm ?? startArm()
    }

    private func neighbours(of arm: Int) -> [Int] {
        guard let i = arms.firstIndex(of: arm) else { return [] }
        return [i - 1, i + 1].filter { arms.indices.contains($0) }.map { arms[$0] }
    }

    private func leadsClearly(_ b: BucketState, best: Int) -> Bool {
        guard let top = b.stats[String(best)], top.count >= configuration.minSamplesToSettle else { return false }
        let n = neighbours(of: best)
        guard !n.isEmpty else { return false }
        return n.allSatisfy { arm in
            guard let s = b.stats[String(arm)], s.count >= configuration.minSamplesToSettle else { return false }
            return top.mean > s.mean * (1 + configuration.clearLead)
        }
    }

    private func effectiveEpsilon(_ b: BucketState, best: Int) -> Double {
        guard leadsClearly(b, best: best) else { return configuration.epsilon }
        if clock().timeIntervalSince(b.lastExplored) >= configuration.resumeAfter { return configuration.epsilon }
        if let last = b.lastReward, let top = b.stats[String(best)],
           last < top.mean * (1 - configuration.dropFraction) { return configuration.epsilon }
        return 0
    }

    // MARK: Learning

    /// Records a finished batch that ran with `arm`. Batches that are too small or short, or failed for other
    /// reasons, are ignored; a rate-limited batch penalises the arm whatever its size.
    /// Pass the `bucket` the arm was chosen for; by default it is derived from the batch's average file size.
    public mutating func record(_ batch: UploadBatch, arm: Int, bucket: WorkloadBucket? = nil) {
        guard arms.contains(arm) else { return }
        let bucket = bucket ?? WorkloadBucket.bucket(bytes: batch.bytes, fileCount: batch.fileCount,
                                                     smallFileThreshold: configuration.smallFileThreshold)
        var b = state.buckets[bucket.rawValue] ?? BucketState(lastExplored: clock())
        var s = b.stats[String(arm)] ?? ArmStats()
        var last: Double
        if batch.rateLimited {
            s.mean *= configuration.rateLimitFactor
            last = s.mean
        } else {
            guard !batch.failed, batch.bytes >= configuration.minBatchBytes,
                  batch.duration >= configuration.minBatchDuration else { return }
            let reward = Double(batch.bytes) / 1_000_000 / batch.duration
            s.mean = s.count == 0 ? reward : s.mean + configuration.ewmaAlpha * (reward - s.mean)
            last = reward
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
