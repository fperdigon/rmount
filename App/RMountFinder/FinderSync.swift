import Cocoa
import FinderSync
import Darwin
import os.log

@objc(FinderSync)
final class FinderSync: FIFinderSync {
    private var statusURL: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var lastData: Data?
    private var badges: [String: String] = [:]
    private var requestedPaths: Set<String> = []
    private var roots: Set<URL> = []
    private var lastError: String?
    private var focusURL: URL?
    private var observed: [String] = []
    private var heartbeat: DispatchSourceTimer?

    override init() {
        super.init()
        // Serialize all state and Finder controller calls on the main queue.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    private func start() {
        FIFinderSyncController.default().directoryURLs = []
        for (id, label) in BadgeImages.definitions {
            FIFinderSyncController.default().setBadgeImage(BadgeImages.image(for: id), label: label, forBadgeIdentifier: id)
        }
        do {
            // In this sandbox this resolves to the extension's own container.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            statusURL = support.appendingPathComponent("status.json")
            focusURL = support.appendingPathComponent(FinderFocusSnapshot.fileName)
            publishFocus()
            Trace.event("extension start status=\(statusURL!.path)")
        } catch {
            Trace.event("extension support-directory error=\(error.localizedDescription)")
        }
        armWatcher()
        reload(reason: "startup")
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.statusURL == nil {
                self.statusURL = try? FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("status.json")
            }
            if self.watcher == nil { self.armWatcher() }
            self.reload(reason: "timer")
        }
        timer = source
        source.resume()
    }

    private func armWatcher() {
        guard watcher == nil, let directory = statusURL?.deletingLastPathComponent() else { return }
        // Watch the parent directory: an atomic write replaces the file's inode.
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let flags = source?.data, !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.watcher?.cancel()
                self.watcher = nil
            }
            self.reload(reason: "watcher")
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
    }

    private func reload(reason: String) {
        guard let statusURL else { return }
        do {
            let data: Data
            do { data = try Data(contentsOf: statusURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                data = try JSONEncoder().encode(FinderBadgeSnapshot(roots: [], items: [], writtenAt: 0))
            }
            guard data != lastData else { return }
            let snapshot = try JSONDecoder().decode(FinderBadgeSnapshot.self, from: data).validated()
            let nextRoots = Set(snapshot.roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let next = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.path, $0.badgeIdentifier) })
            let old = badges
            let rootsChanged = nextRoots != roots
            Trace.event("extension reload reason=\(reason) items=\(next.count) roots=\(nextRoots.count)")
            // Clear removed/excluded items while old roots are still registered.
            for path in requestedPaths where old[path] != nil && (next[path] == nil || !contains(path, in: nextRoots)) {
                apply("", to: URL(fileURLWithPath: path), reason: "clear")
            }
            badges = next
            roots = nextRoots
            if rootsChanged { FIFinderSyncController.default().directoryURLs = roots }
            for (path, badge) in next where requestedPaths.contains(path) && contains(path, in: roots) && (rootsChanged || old[path] != badge) {
                apply(badge, to: URL(fileURLWithPath: path), reason: "change")
            }
            lastData = data
            lastError = nil
        } catch {
            let message = error.localizedDescription
            if message != lastError { Trace.event("extension reload error=\(message); retaining last valid snapshot") }
            lastError = message
        }
    }

    private func contains(_ path: String, in roots: Set<URL>) -> Bool {
        roots.contains { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
    }

    private func apply(_ badge: String, to url: URL, reason: String) {
        FIFinderSyncController.default().setBadgeIdentifier(badge, for: url)
        Trace.event("extension setBadge reason=\(reason) badge=\(badge.isEmpty ? "<clear>" : badge) path=\(url.path)")
    }

    override func beginObservingDirectory(at url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observe(url.standardizedFileURL.path, begin: true)
            self.reload(reason: "beginObserving")
            Trace.event("extension beginObserving path=\(url.path)")
            let directory = url.standardizedFileURL.path
            for (path, badge) in self.badges where self.requestedPaths.contains(path) && self.contains(path, in: self.roots) &&
                (path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")) {
                self.apply(badge, to: URL(fileURLWithPath: path), reason: "beginObserving")
            }
        }
    }

    override func endObservingDirectory(at url: URL) {
        DispatchQueue.main.async { [weak self] in
            self?.observe(url.standardizedFileURL.path, begin: false)
        }
    }

    /// Tell the app which folders Finder shows (focus.json, atomic). The app unsandboxed reads it.
    private func observe(_ path: String, begin: Bool) {
        observed.removeAll { $0 == path }
        if begin { observed.append(path) }
        publishFocus()
        if observed.isEmpty { heartbeat?.cancel(); heartbeat = nil }
        else if heartbeat == nil {
            // Re-stamp so the app can tell a live extension from one that exited with folders open.
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
            source.setEventHandler { [weak self] in self?.publishFocus() }
            heartbeat = source
            source.resume()
        }
    }

    private func publishFocus() {
        guard let focusURL else { return }
        let snapshot = FinderFocusSnapshot(directories: observed)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: focusURL, options: .atomic)
    }

    override func requestBadgeIdentifier(for url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let path = url.standardizedFileURL.path
            self.requestedPaths.insert(path)
            self.apply(self.contains(path, in: self.roots) ? (self.badges[path] ?? "") : "", to: url, reason: "request")
        }
    }

    deinit {
        watcher?.cancel()
        timer?.cancel()
        heartbeat?.cancel()
    }
}

// File paths and errors remain private debug diagnostics.
private enum Trace {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.rmount.findersync", category: "badges")
    static func event(_ message: String) {
        log.debug("\(message, privacy: .private)")
    }
}
