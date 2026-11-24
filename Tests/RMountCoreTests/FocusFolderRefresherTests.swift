import XCTest
@testable import RMountCore

private actor RefreshRecorder: RcloneControlClient {
    private(set) var dirs: [String?] = []
    private(set) var forgets = 0
    var fails = false
    var gate: CheckedContinuation<Void, Never>?
    var blocking = false
    func vfsQueue() async throws -> VFSQueue { VFSQueue() }
    func vfsRefresh(dir: String?) async throws {
        dirs.append(dir)
        if blocking { await withCheckedContinuation { gate = $0 } }
        if fails { throw URLError(.cannotConnectToHost) }
    }
    func vfsForgetAll() async throws { forgets += 1 }
    func setFails(_ value: Bool) { fails = value }
    func block() { blocking = true }
    func release() { blocking = false; gate?.resume(); gate = nil }
}

private final class FocusFile {
    var directories: [String] = []
    var corrupt = false
    var missing = false
    var stamp: Date?
    var clock: () -> Date = Date.init
    func read() -> Data? {
        if missing { return nil }
        if corrupt { return Data("{nope".utf8) }
        let snapshot = FinderFocusSnapshot(directories: directories,
                                           writtenAt: (stamp ?? clock()).timeIntervalSince1970)
        return try? JSONEncoder().encode(snapshot)
    }
}

@MainActor
final class FocusFolderRefresherTests: DebugTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private let file = FocusFile()
    private let remoteA = UUID()
    private let remoteB = UUID()

    private func makeRefresher(enabled: Bool = true, timing: FocusFolderRefresher.Timing = .init()) -> FocusFolderRefresher {
        var slow = timing
        slow.poll = 3600     // drive polls by hand
        file.clock = { [unowned self] in self.now }
        return FocusFolderRefresher(focusURL: URL(fileURLWithPath: "/nonexistent-rmount-test/focus.json"),
                                    timing: slow, isEnabled: enabled, clock: { [unowned self] in self.now },
                                    readFocus: { [unowned self] in self.file.read() })
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    // MARK: path mapping

    func testRelativeDirectoryMapping() {
        XCTAssertEqual(FocusFolderRefresher.relativeDirectory(of: "/Users/u/rmount/box", in: "/Users/u/rmount/box"), "")
        XCTAssertEqual(FocusFolderRefresher.relativeDirectory(of: "/Users/u/rmount/box/a/b", in: "/Users/u/rmount/box"), "a/b")
        XCTAssertEqual(FocusFolderRefresher.relativeDirectory(of: "/Users/u/rmount/box/My Docs/ñandú", in: "/Users/u/rmount/box"), "My Docs/ñandú")
        XCTAssertNil(FocusFolderRefresher.relativeDirectory(of: "/Users/u/rmount/box2/a", in: "/Users/u/rmount/box"))
        XCTAssertNil(FocusFolderRefresher.relativeDirectory(of: "/elsewhere", in: "/Users/u/rmount/box"))
        XCTAssertEqual(FocusFolderRefresher.relativeDirectory(of: "/a/b", in: "/"), "a/b")
        // Decomposed (NFD) Finder path against a precomposed mountpoint.
        let nfd = "/Users/u/rmount/caf\u{65}\u{301}/x"
        XCTAssertEqual(FocusFolderRefresher.relativeDirectory(of: nfd, in: "/Users/u/rmount/caf\u{E9}"), "x")
    }

    func testRefreshesRootAndNestedFoldersWithExactParameters() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/Users/u/rmount/box", client: client)
        file.directories = ["/Users/u/rmount/box", "/Users/u/rmount/box/My Docs/ñandú/2024"]
        await r.poll().value
        let dirs = await client.dirs
        XCTAssertEqual(dirs.count, 2)
        XCTAssertTrue(dirs.contains(where: { $0 == nil }), "root is refreshed with no dir parameter")
        XCTAssertTrue(dirs.contains("My Docs/ñandú/2024"))
    }

    func testFoldersOutsideMountsAreIgnoredAndLongestMountWins() async throws {
        let outer = RefreshRecorder(), inner = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/outer", client: outer)
        r.register(remoteID: remoteB, mountpoint: "/m/outer/inner", client: inner)
        file.directories = ["/Users/u/Documents", "/m/outer/x", "/m/outer/inner/y", "/m/outerish/z"]
        await r.poll().value
        let outerDirs = await outer.dirs, innerDirs = await inner.dirs
        XCTAssertEqual(outerDirs, ["x"])
        XCTAssertEqual(innerDirs, ["y"])
    }

    // MARK: timing

    func testRepeatsEveryFifteenSecondsWhileFocused() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        advance(5); await r.poll().value
        advance(5); await r.poll().value
        var count = await client.dirs.count
        XCTAssertEqual(count, 1)
        advance(5); await r.poll().value
        count = await client.dirs.count
        XCTAssertEqual(count, 2)
        advance(15); await r.poll().value
        count = await client.dirs.count
        XCTAssertEqual(count, 3)
    }

    func testRefocusWithinDebounceIsIgnoredButLaterRefocusRefreshes() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        file.directories = []
        advance(1); await r.poll().value
        file.directories = ["/m/a/docs"]
        advance(1); await r.poll().value          // 2 s after the last refresh: debounced
        var count = await client.dirs.count
        XCTAssertEqual(count, 1)
        file.directories = []
        advance(1); await r.poll().value
        file.directories = ["/m/a/docs"]
        advance(2); await r.poll().value          // 5 s after: refocus refreshes at once
        count = await client.dirs.count
        XCTAssertEqual(count, 2)
    }

    func testStopsWhenUnfocused() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        file.directories = []
        for _ in 0..<5 { advance(20); await r.poll().value }
        let count = await client.dirs.count
        XCTAssertEqual(count, 1)
    }

    func testStopsOnUnregisterAndStop() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        r.unregister(remoteID: remoteA)
        advance(30); await r.poll().value
        var count = await client.dirs.count
        XCTAssertEqual(count, 1)
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)   // registers and polls at once
        try await Task.sleep(nanoseconds: 100_000_000)
        r.stop()
        advance(30); await r.poll().value
        count = await client.dirs.count
        XCTAssertEqual(count, 2)
    }

    func testStaleOrBrokenFocusFileMeansNoRefresh() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        file.stamp = now.addingTimeInterval(-120)      // extension gone
        await r.poll().value
        file.stamp = nil; file.corrupt = true
        await r.poll().value
        file.corrupt = false; file.missing = true
        await r.poll().value
        let count = await client.dirs.count
        XCTAssertEqual(count, 0)
    }

    func testCapsFoldersPerRemoteKeepingNewest() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = (0..<12).map { "/m/a/d\($0)" }
        await r.poll().value
        let dirs = await client.dirs.compactMap { $0 }
        XCTAssertEqual(dirs.count, 8)
        XCTAssertEqual(Set(dirs), Set((4..<12).map { "d\($0)" }))
    }

    func testOneInFlightRefreshPerRemote() async throws {
        let client = RefreshRecorder()
        await client.block()
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/one"]
        let first = r.poll()
        try await Task.sleep(nanoseconds: 50_000_000)
        file.directories = ["/m/a/one", "/m/a/two"]
        advance(20)
        await r.poll().value                    // busy: nothing new starts
        var dirs = await client.dirs
        XCTAssertEqual(dirs, ["one"])
        await client.release()
        await first.value
        await client.release()
        advance(1)
        await r.poll().value                    // idle again: one is due (21 s) and two is new
        dirs = await client.dirs.compactMap { $0 }
        XCTAssertEqual(Set(dirs), ["one", "two"])
    }

    func testFailuresAreSwallowedAndNotRetriedBeforeTheInterval() async throws {
        let client = RefreshRecorder()
        await client.setFails(true)
        let r = makeRefresher()
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        advance(5); await r.poll().value
        let count = await client.dirs.count
        XCTAssertEqual(count, 1)
    }

    func testPreferenceOffStopsAndOnResumes() async throws {
        let client = RefreshRecorder()
        let r = makeRefresher(enabled: false)
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        file.directories = ["/m/a/docs"]
        await r.poll().value
        var count = await client.dirs.count
        XCTAssertEqual(count, 0)
        r.isEnabled = true                       // polls immediately
        try await Task.sleep(nanoseconds: 100_000_000)
        count = await client.dirs.count
        XCTAssertEqual(count, 1)
        r.isEnabled = false
        advance(60); await r.poll().value
        count = await client.dirs.count
        XCTAssertEqual(count, 1)
        r.stop()
    }

    // MARK: driver

    func testDriverPollsOnItsOwnAndReactsToFileChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(FinderFocusSnapshot.fileName)
        let client = RefreshRecorder()
        var timing = FocusFolderRefresher.Timing()
        timing.poll = 0.05
        let r = FocusFolderRefresher(focusURL: url, timing: timing)
        r.register(remoteID: remoteA, mountpoint: "/m/a", client: client)
        defer { r.stop() }
        try JSONEncoder().encode(FinderFocusSnapshot(directories: ["/m/a/live"])).write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, await client.dirs.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let dirs = await client.dirs
        XCTAssertEqual(dirs, ["live"])
    }

    // MARK: snapshot decoding

    func testFocusSnapshotDecodingIsTolerant() throws {
        XCTAssertNil(FinderFocusSnapshot.decode(nil))
        XCTAssertNil(FinderFocusSnapshot.decode(Data("{nope".utf8)))
        XCTAssertNil(FinderFocusSnapshot.decode(Data("[1,2]".utf8)))
        XCTAssertEqual(FinderFocusSnapshot.decode(Data("{}".utf8)), FinderFocusSnapshot(directories: [], writtenAt: 0))
        let mixed = FinderFocusSnapshot.decode(Data(#"{"directories":["/a","relative","/b"],"writtenAt":5,"extra":1}"#.utf8))
        XCTAssertEqual(mixed?.directories, ["/a", "/b"])
        let round = FinderFocusSnapshot(directories: ["/x y/ñ"], writtenAt: 7)
        XCTAssertEqual(FinderFocusSnapshot.decode(try JSONEncoder().encode(round)), round)
        XCTAssertTrue(FinderFocusSnapshot(writtenAt: 100).isFresh(now: Date(timeIntervalSince1970: 120), maxAge: 30))
        XCTAssertFalse(FinderFocusSnapshot(writtenAt: 100).isFresh(now: Date(timeIntervalSince1970: 131), maxAge: 30))
    }

    func testKeepOpenFoldersFreshPreference() {
        let name = "rmount.focus-pref.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = UserPreferences(defaults: defaults)
        XCTAssertTrue(prefs.keepOpenFoldersFresh)
        let posted = expectation(forNotification: UserPreferences.keepOpenFoldersFreshDidChange, object: prefs)
        prefs.keepOpenFoldersFresh = false
        wait(for: [posted], timeout: 1)
        XCTAssertFalse(UserPreferences(defaults: defaults).keepOpenFoldersFresh)
    }
}
