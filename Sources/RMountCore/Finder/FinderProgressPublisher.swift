import Foundation

@MainActor
public protocol FinderProgressHandle {
    func update(completed: Int64, total: Int64)
    func finish()
}

@MainActor
public protocol FinderProgressFactory {
    func makeHandle(for fileURL: URL, total: Int64) -> FinderProgressHandle
}

@MainActor
public struct FoundationFinderProgressFactory: FinderProgressFactory {
    public init() {}

    public func makeHandle(for fileURL: URL, total: Int64) -> FinderProgressHandle {
        FoundationFinderProgressHandle(fileURL: fileURL, total: total)
    }
}

@MainActor
private final class FoundationFinderProgressHandle: FinderProgressHandle {
    private let progress: Progress

    init(fileURL: URL, total: Int64) {
        progress = Progress(totalUnitCount: total)
        progress.kind = .file
        progress.fileOperationKind = .uploading
        progress.fileURL = fileURL
        progress.isCancellable = false
        progress.isPausable = false
        progress.publish()
    }

    func update(completed: Int64, total: Int64) {
        progress.totalUnitCount = total
        progress.completedUnitCount = min(max(0, completed), total)
    }

    func finish() {
        progress.completedUnitCount = progress.totalUnitCount
        progress.unpublish()
    }
}

/// Publications and all updates stay on the main thread, whose run loop serves Foundation Progress.
@MainActor
public final class FinderProgressPublisher {
    public static let defaultLimit = 150

    public var isEnabled: Bool {
        didSet { if !isEnabled { clearAll() } }
    }

    private struct Publication {
        let handle: FinderProgressHandle
        var missingSamples = 0
    }

    private let factory: FinderProgressFactory
    private let limit: Int
    private var publications: [UUID: [String: Publication]] = [:]

    public init(factory: FinderProgressFactory? = nil, limit: Int? = nil, isEnabled: Bool = true) {
        self.factory = factory ?? FoundationFinderProgressFactory()
        self.limit = max(0, limit ?? Self.defaultLimit)
        self.isEnabled = isEnabled
    }

    public func sync(remoteID: UUID, mountpoint: String?, status: UploadStatus) {
        guard isEnabled, !status.isStale else { return }
        guard let mountpoint else { clear(remoteID: remoteID); return }

        var remote = publications[remoteID] ?? [:]
        let paths = Set(status.transfers.map(\.path))
        for path in Array(remote.keys) {
            guard var publication = remote[path] else { continue }
            if paths.contains(path) {
                publication.missingSamples = 0
                remote[path] = publication
            } else {
                publication.missingSamples += 1
                if publication.missingSamples >= 2 {
                    publication.handle.finish()
                    remote.removeValue(forKey: path)
                } else {
                    remote[path] = publication
                }
            }
        }

        // Preserve queue order within each priority, and never evict an existing publication.
        let ordered = status.transfers.filter { $0.state == .uploading }
            + status.transfers.filter { $0.state == .queued }
            + status.transfers.filter { $0.state != .uploading && $0.state != .queued }
        let root = URL(fileURLWithPath: mountpoint)
        for transfer in ordered {
            guard let total = transfer.totalBytes, total > 0 else { continue }
            if remote[transfer.path] == nil, remote.count < limit {
                let handle = factory.makeHandle(for: root.appendingPathComponent(transfer.path), total: total)
                remote[transfer.path] = Publication(handle: handle)
            }
            // A lower byte count means rclone restarted the upload; accept the new count.
            remote[transfer.path]?.handle.update(completed: min(max(0, transfer.bytesDone ?? 0), total), total: total)
        }
        publications[remoteID] = remote.isEmpty ? nil : remote
    }

    public func clear(remoteID: UUID) {
        let remote = publications.removeValue(forKey: remoteID)
        remote?.values.forEach { $0.handle.finish() }
    }

    public func clearAll() {
        for remoteID in Array(publications.keys) { clear(remoteID: remoteID) }
    }
}
