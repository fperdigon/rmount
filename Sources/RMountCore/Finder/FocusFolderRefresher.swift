import Foundation
import Darwin
import os

/// Keeps the folders open in Finder fresh. The Finder extension reports which folders Finder shows
/// (`focus.json`); for each one this calls rclone's `vfs/refresh` (non-recursive) when it gains
/// focus and then every `interval` while it stays focused, so server-side changes appear without
/// waiting for the directory cache to expire.
@MainActor
public final class FocusFolderRefresher {
    public struct Timing: Equatable {
        public var interval: TimeInterval = 15
        public var debounce: TimeInterval = 3
        public var poll: TimeInterval = 5
        public var maxFoldersPerRemote = 8
        /// The extension re-stamps focus.json at least this often while a folder is observed.
        public var maxSnapshotAge: TimeInterval = 30
        public init() {}
    }

    private struct Key: Hashable { let remoteID: UUID; let dir: String }
    private struct Registration { let mountpoint: String; let client: RcloneControlClient }

    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { updateDriver(); if isEnabled { poll() } } }
    }

    private let timing: Timing
    private let clock: () -> Date
    private let focusURL: URL?
    private let readFocus: () -> Data?
    private let log = Logger(subsystem: "ai.rmount", category: "focus-refresh")
    private var remotes: [UUID: Registration] = [:]
    private var focused: Set<Key> = []
    private var lastRefresh: [Key: Date] = [:]
    private var inFlight: [UUID: UUID] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?

    /// `focusURL` is the extension container's focus.json. `readFocus` replaces reading it (tests).
    public init(focusURL: URL? = nil, timing: Timing = Timing(), isEnabled: Bool = true,
                clock: @escaping () -> Date = Date.init, readFocus: (() -> Data?)? = nil,
                extensionBundleID: String = FinderBadgeConstants.extensionBundleID()) {
        let url = focusURL ?? FinderBadgeStatusWriter.containerDirectory(
            extensionBundleID: extensionBundleID, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(FinderFocusSnapshot.fileName)
        self.focusURL = url
        self.readFocus = readFocus ?? { try? Data(contentsOf: url) }
        self.timing = timing
        self.isEnabled = isEnabled
        self.clock = clock
    }

    public func register(remoteID: UUID, mountpoint: String, client: RcloneControlClient) {
        unregister(remoteID: remoteID)
        remotes[remoteID] = Registration(mountpoint: finderBadgeNormalizedPath(mountpoint), client: client)
        updateDriver()
        poll()
    }

    public func unregister(remoteID: UUID) {
        remotes.removeValue(forKey: remoteID)
        inFlight.removeValue(forKey: remoteID)
        refreshTasks.removeValue(forKey: remoteID)?.cancel()
        focused = focused.filter { $0.remoteID != remoteID }
        lastRefresh = lastRefresh.filter { $0.key.remoteID != remoteID }
        updateDriver()
    }

    /// Stop everything (app quit).
    public func stop() {
        for id in Array(remotes.keys) { unregister(remoteID: id) }
    }

    /// Read the focus file and refresh what is due. The returned task finishes when the refresh
    /// calls started by this poll are done (tests await it).
    @discardableResult
    public func poll() -> Task<Void, Never> {
        let idle = Task<Void, Never> {}
        guard isEnabled, !remotes.isEmpty else { focused = []; return idle }
        armWatcher()
        let now = clock()
        var directories: [String] = []
        if let snapshot = FinderFocusSnapshot.decode(readFocus()), snapshot.isFresh(now: now, maxAge: timing.maxSnapshotAge) {
            directories = snapshot.directories
        }
        let wanted = focusedByRemote(directories)
        var nextFocused: Set<Key> = []
        var work: [Task<Void, Never>] = []
        for (remoteID, dirs) in wanted {
            guard let registration = remotes[remoteID] else { continue }
            if inFlight[remoteID] != nil {
                // Busy: keep what we knew, handle new arrivals on the next poll.
                nextFocused.formUnion(focused.filter { $0.remoteID == remoteID && dirs.contains($0.dir) })
                continue
            }
            var due: [String] = []
            for dir in dirs {
                let key = Key(remoteID: remoteID, dir: dir)
                nextFocused.insert(key)
                let elapsed = lastRefresh[key].map { now.timeIntervalSince($0) }
                let isDue: Bool
                if focused.contains(key) { isDue = (elapsed ?? .infinity) >= timing.interval }
                else { isDue = (elapsed ?? .infinity) >= timing.debounce }
                if isDue { due.append(dir); lastRefresh[key] = now }
            }
            if !due.isEmpty { work.append(refresh(due, remoteID: remoteID, client: registration.client)) }
        }
        focused = nextFocused
        lastRefresh = lastRefresh.filter { now.timeIntervalSince($0.value) < 120 && remotes[$0.key.remoteID] != nil }
        guard !work.isEmpty else { return idle }
        return Task { for task in work { await task.value } }
    }

    private func refresh(_ dirs: [String], remoteID: UUID, client: RcloneControlClient) -> Task<Void, Never> {
        let token = UUID()
        inFlight[remoteID] = token
        let task = Task { @MainActor [weak self] in
            // One call: the NFS client takes a folder's mtime from its parent's listing, so the
            // parent has to be re-read together with the folder or the kernel keeps its old listing.
            if !Task.isCancelled {
                do { try await client.vfsRefresh(dirs: Self.withParents(dirs)) }
                catch { self?.log.debug("vfs/refresh failed (code \((error as NSError).code))") }
            }
            if self?.inFlight[remoteID] == token { self?.inFlight.removeValue(forKey: remoteID); self?.refreshTasks.removeValue(forKey: remoteID) }
        }
        refreshTasks[remoteID] = task
        return task
    }

    /// Each folder preceded by its parent ("" = root, whose parent is itself), without duplicates.
    nonisolated static func withParents(_ dirs: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for dir in dirs {
            let parent = dir.contains("/") ? String(dir[..<dir.lastIndex(of: "/")!]) : ""
            for path in [parent, dir] where seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    // MARK: mapping

    private func focusedByRemote(_ directories: [String]) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for path in directories {
            guard let (remoteID, relative) = map(path) else { continue }
            if !(result[remoteID]?.contains(relative) ?? false) { result[remoteID, default: []].append(relative) }
        }
        // The newest folders win when Finder shows more than the cap.
        return result.mapValues { Array($0.suffix(timing.maxFoldersPerRemote)) }
    }

    private func map(_ path: String) -> (UUID, String)? {
        let normalized = finderBadgeNormalizedPath(path)
        var best: (UUID, String, Int)?
        for (id, registration) in remotes {
            guard let relative = Self.relativeDirectory(of: normalized, in: registration.mountpoint) else { continue }
            if best == nil || registration.mountpoint.count > best!.2 { best = (id, relative, registration.mountpoint.count) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// The path inside the remote ("" = the remote root), or nil when `path` is not under `mountpoint`.
    /// Finder and the file system can disagree on Unicode normalization, so a second try compares precomposed.
    nonisolated static func relativeDirectory(of path: String, in mountpoint: String) -> String? {
        func relative(_ path: String, _ root: String) -> String? {
            if path == root { return "" }
            let prefix = root == "/" ? "/" : root + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return relative(path, mountpoint)
            ?? relative(path.precomposedStringWithCanonicalMapping, mountpoint.precomposedStringWithCanonicalMapping)
    }

    // MARK: driver (file watch + fallback poll, only while something is mounted)

    private func updateDriver() {
        let shouldRun = isEnabled && !remotes.isEmpty
        if shouldRun, pollTask == nil {
            let delay = max(0.01, timing.poll)
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                    self?.poll()
                }
            }
            armWatcher()
        } else if !shouldRun {
            pollTask?.cancel(); pollTask = nil
            watcher?.cancel(); watcher = nil
            if !isEnabled { refreshTasks.values.forEach { $0.cancel() }; refreshTasks = [:]; inFlight.removeAll(); focused = []; lastRefresh = [:] }
        }
    }

    private func armWatcher() {
        guard watcher == nil, let directory = focusURL?.deletingLastPathComponent() else { return }
        // Watch the parent directory: an atomic write replaces the file's inode.
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let flags = source?.data, !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.watcher?.cancel()
                    self.watcher = nil
                }
                self.poll()
            }
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
    }

    deinit {
        pollTask?.cancel()
        watcher?.cancel()
    }
}
