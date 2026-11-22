import Foundation
import Darwin
import os

@MainActor
public protocol FinderBadgeStatusWriting {
    func write(_ snapshot: FinderBadgeSnapshot)
    /// Complete the final write before the application exits.
    func flush(_ snapshot: FinderBadgeSnapshot)
}

@MainActor
public final class FinderBadgeStatusWriter: FinderBadgeStatusWriting {
    public let statusURL: URL
    private let fileManager: FileManager
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "ai.rmount.finder-badge-writer", qos: .utility)
    private let log = Logger(subsystem: "ai.rmount", category: "finder-badges")
    private var lastContent: FinderBadgeSnapshot?
    private var lastWrite: Date?
    private var pending: FinderBadgeSnapshot?
    private var trailing: Task<Void, Never>?

    /// baseDirectory is the extension's Application Support directory when supplied.
    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default,
                extensionBundleID: String = FinderBadgeConstants.extensionBundleID(),
                interval: TimeInterval = 0.25) {
        self.fileManager = fileManager
        self.interval = max(0, interval)
        statusURL = (baseDirectory ?? Self.containerDirectory(extensionBundleID: extensionBundleID,
                                                             homeDirectory: fileManager.homeDirectoryForCurrentUser))
            .appendingPathComponent("status.json")
    }

    public static func containerDirectory(extensionBundleID: String, homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Containers")
            .appendingPathComponent(extensionBundleID)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
    }

    public func write(_ snapshot: FinderBadgeSnapshot) {
        pending = snapshot
        if let lastWrite, Date().timeIntervalSince(lastWrite) < interval {
            guard trailing == nil else { return }
            let delay = max(0, interval - Date().timeIntervalSince(lastWrite))
            trailing = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.trailing = nil
                self.submitPending()
            }
        } else {
            trailing?.cancel()
            trailing = nil
            submitPending()
        }
    }

    public func flush(_ snapshot: FinderBadgeSnapshot) {
        trailing?.cancel()
        trailing = nil
        pending = snapshot
        submitPending()
        queue.sync {}
    }

    private func submitPending() {
        guard let snapshot = pending else { return }
        pending = nil
        // writtenAt is diagnostic: changing it alone must not rewrite status.json.
        guard lastContent?.roots != snapshot.roots || lastContent?.items != snapshot.items else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            lastContent = snapshot
            lastWrite = Date()
            let directory = statusURL.deletingLastPathComponent()
            let destination = statusURL
            let fileManager = fileManager
            let log = log
            queue.async {
                let temporary = directory.appendingPathComponent(".status-\(UUID().uuidString).json")
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? fileManager.removeItem(at: temporary) }
                    try data.write(to: temporary)
                    guard rename(temporary.path, destination.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    log.error("Could not write Finder badge status (code \((error as NSError).code, privacy: .public))")
                }
            }
        } catch {
            log.error("Could not encode Finder badge status")
        }
    }

    // Tests can drain already submitted disk work without forcing a pending trailing write.
    func waitForSubmittedWrites() { queue.sync {} }
}
