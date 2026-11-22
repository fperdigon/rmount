import Foundation

@MainActor
public final class FinderBadgeTracker {
    public var isEnabled: Bool {
        didSet { if !isEnabled { clearAll() } }
    }
    private struct Entry {
        var state: FinderBadgeState
        var missingSamples = 0
        var completedAt: Date?
        var hasError = false
    }
    private struct Remote {
        var root: String
        var items: [String: Entry] = [:]
        var isStale = false
    }
    private let writer: FinderBadgeStatusWriting
    private let doneRetention: TimeInterval
    private let limit: Int
    private let clock: () -> Date
    private var remotes: [UUID: Remote] = [:]

    public init(writer: FinderBadgeStatusWriting? = nil, doneRetention: TimeInterval = 600,
                limit: Int = 2000, clock: @escaping () -> Date = Date.init, isEnabled: Bool = true) {
        self.writer = writer ?? FinderBadgeStatusWriter()
        self.doneRetention = max(0, doneRetention)
        self.limit = max(0, limit)
        self.clock = clock
        self.isEnabled = isEnabled
        self.writer.flush(FinderBadgeSnapshot(writtenAt: clock().timeIntervalSince1970))
    }

    public var snapshot: FinderBadgeSnapshot {
        let roots = Array(Set(remotes.values.map(\.root))).sorted()
        let items = remotes.values.flatMap { remote in
            remote.items.map { path, entry in
                FinderBadgeSnapshot.Item(path: path, state: remote.isStale ? .offline : entry.state)
            }
        }.sorted { $0.path < $1.path }
        return FinderBadgeSnapshot(roots: roots, items: items, writtenAt: clock().timeIntervalSince1970)
    }

    public func sync(remoteID: UUID, remoteName: String, mountpoint: String?, status: UploadStatus) {
        guard isEnabled else { return }
        guard let mountpoint else { clear(remoteID: remoteID); return }
        let root = finderBadgeNormalizedPath(mountpoint)
        var remote = remotes[remoteID].flatMap { $0.root == root ? $0 : nil } ?? Remote(root: root)
        let now = clock()
        remote.items = remote.items.filter { $0.value.completedAt.map { now.timeIntervalSince($0) < doneRetention } ?? true }
        remote.isStale = status.isStale
        if status.isStale {
            // An unreachable sample cannot confirm a consecutive successful absence.
            for path in Array(remote.items.keys) { remote.items[path]?.missingSamples = 0 }
        } else {
            let transfers = status.transfers.compactMap { transfer -> (String, TransferProgress)? in
                let path = finderBadgeNormalizedPath(URL(fileURLWithPath: root).appendingPathComponent(transfer.path).path)
                guard !transfer.path.hasPrefix("/"), path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
                return (path, transfer)
            }
            let paths = Set(transfers.map { $0.0 })
            for path in Array(remote.items.keys) where !paths.contains(path) {
                guard var entry = remote.items[path], entry.completedAt == nil else { continue }
                entry.missingSamples += 1
                if entry.missingSamples >= 2 {
                    entry.state = .done
                    entry.hasError = false
                    entry.completedAt = now
                }
                remote.items[path] = entry
            }
            for (path, transfer) in transfers {
                if remote.items[path] == nil, remote.items.count >= limit {
                    let oldestDone = remote.items.filter { $0.value.completedAt != nil }.min {
                        if $0.value.completedAt == $1.value.completedAt { return $0.key < $1.key }
                        return $0.value.completedAt! < $1.value.completedAt!
                    }?.key
                    if let oldestDone { remote.items.removeValue(forKey: oldestDone) }
                }
                guard remote.items[path] != nil || remote.items.count < limit else { continue }
                var entry = remote.items[path] ?? Entry(state: .waiting)
                entry.missingSamples = 0
                entry.completedAt = nil
                if transfer.state == .finishing { entry.hasError = false }
                else if (transfer.tries ?? 0) >= 3 { entry.hasError = true }
                if entry.hasError { entry.state = .error }
                else {
                    switch transfer.state {
                    case .queued: entry.state = .waiting
                    case .uploading:
                        let value = transfer.fraction ?? 0
                        entry.state = .uploading(value.isFinite ? min(1, max(0, value)) : 0)
                    case .retrying: entry.state = .retrying
                    case .finishing: entry.state = .uploading(1)
                    }
                }
                remote.items[path] = entry
            }
        }
        remotes[remoteID] = remote
        writer.write(snapshot)
    }

    public func clear(remoteID: UUID) {
        remotes.removeValue(forKey: remoteID)
        writer.write(snapshot)
    }

    public func clearAll() {
        remotes.removeAll()
        writer.flush(snapshot)
    }
}
