import XCTest
@testable import RMountCore

@MainActor
final class RecordingBadgeWriter: FinderBadgeStatusWriting {
    var writes: [FinderBadgeSnapshot] = []
    var flushes: [FinderBadgeSnapshot] = []
    func write(_ snapshot: FinderBadgeSnapshot) { writes.append(snapshot) }
    func flush(_ snapshot: FinderBadgeSnapshot) { flushes.append(snapshot) }
}

final class FinderBadgeTrackerTests: DebugTestCase {
    private func transfer(_ path: String = "file", _ state: TransferProgress.State = .queued,
                          fraction: Double? = nil, tries: Int? = nil) -> TransferProgress {
        TransferProgress(path: path, state: state, bytesDone: nil, totalBytes: nil,
                         fraction: fraction, speed: nil, eta: nil, tries: tries)
    }

    @MainActor
    func testStateMappingPathsAndRootLifecycle() {
        let writer = RecordingBadgeWriter(), id = UUID()
        let tracker = FinderBadgeTracker(writer: writer)
        XCTAssertEqual(writer.flushes.count, 1)
        let values: [(TransferProgress.State, Double?, FinderBadgeState)] = [
            (.queued, nil, .waiting), (.uploading, nil, .uploading(0)),
            (.uploading, 0.42, .uploading(0.42)), (.retrying, nil, .retrying),
            (.finishing, nil, .uploading(1)), (.uploading, .nan, .uploading(0)),
            (.uploading, 2, .uploading(1)), (.uploading, -2, .uploading(0))
        ]
        for (state, fraction, expected) in values {
            tracker.sync(remoteID: id, remoteName: "Test", mountpoint: "/Volumes/My Remote",
                         status: UploadStatus(transfers: [transfer("sub folder/日本語/café", state, fraction: fraction)]))
            XCTAssertEqual(tracker.snapshot.items, [.init(path: "/Volumes/My Remote/sub folder/日本語/café", state: expected)])
        }
        tracker.sync(remoteID: UUID(), remoteName: "empty", mountpoint: "/other", status: UploadStatus())
        XCTAssertEqual(tracker.snapshot.roots, ["/Volumes/My Remote", "/other"])
        tracker.sync(remoteID: id, remoteName: "Test", mountpoint: nil, status: UploadStatus(isStale: true))
        XCTAssertEqual(tracker.snapshot.roots, ["/other"])
        tracker.clearAll()
        XCTAssertTrue(writer.flushes.last!.roots.isEmpty)
        XCTAssertTrue(writer.flushes.last!.items.isEmpty)
    }

    @MainActor
    func testTwoConsecutiveAbsencesReappearanceStaleAndRetention() {
        var now = Date(timeIntervalSince1970: 100)
        let tracker = FinderBadgeTracker(writer: RecordingBadgeWriter(), doneRetention: 10, clock: { now })
        let id = UUID()
        func sync(_ status: UploadStatus) { tracker.sync(remoteID: id, remoteName: "Test", mountpoint: "/mount", status: status) }
        let present = UploadStatus(transfers: [transfer()])
        sync(present); sync(UploadStatus()); sync(present); sync(UploadStatus())
        XCTAssertEqual(tracker.snapshot.items.first?.state, .waiting)
        sync(UploadStatus(isStale: true))
        XCTAssertEqual(tracker.snapshot.items.first?.state, .offline)
        sync(UploadStatus())
        XCTAssertEqual(tracker.snapshot.items.first?.state, .waiting)
        sync(UploadStatus())
        XCTAssertEqual(tracker.snapshot.items.first?.state, .done)
        now.addTimeInterval(9)
        sync(UploadStatus(isStale: true))
        XCTAssertEqual(tracker.snapshot.items.first?.state, .offline)
        now.addTimeInterval(1)
        sync(UploadStatus())
        XCTAssertTrue(tracker.snapshot.items.isEmpty)
        XCTAssertEqual(tracker.snapshot.roots, ["/mount"])
    }

    @MainActor
    func testRepeatedErrorsStickyUntilCompletionOrConfirmedDeparture() {
        let tracker = FinderBadgeTracker(writer: RecordingBadgeWriter()), id = UUID()
        func sync(_ entries: [TransferProgress]) { tracker.sync(remoteID: id, remoteName: "Test", mountpoint: "/mount", status: UploadStatus(transfers: entries)) }
        sync([transfer("file", .retrying, tries: 2)])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .retrying)
        sync([transfer("file", .retrying, tries: 3)])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .error)
        sync([transfer("file", .uploading, fraction: 0.8)])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .error)
        sync([transfer("file", .finishing)])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .uploading(1))
        sync([transfer("file", .retrying, tries: 4)]); sync([])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .error)
        sync([])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .done)
        sync([transfer()])
        XCTAssertEqual(tracker.snapshot.items.first?.state, .waiting)
    }

    @MainActor
    func testCapDropsOldestDoneBeforeActiveAndIsPerRemote() {
        var now = Date()
        let tracker = FinderBadgeTracker(writer: RecordingBadgeWriter(), limit: 2, clock: { now }), id = UUID()
        func sync(_ names: [String]) { tracker.sync(remoteID: id, remoteName: "Test", mountpoint: "/mount", status: UploadStatus(transfers: names.map { transfer($0) })) }
        sync(["old", "new", "overflow"])
        XCTAssertEqual(tracker.snapshot.items.map(\.path), ["/mount/new", "/mount/old"])
        sync(["new"]); sync(["new"])
        now.addTimeInterval(1)
        sync([]); sync([])
        sync(["active"])
        XCTAssertEqual(tracker.snapshot.items.map(\.path), ["/mount/active", "/mount/new"])
        tracker.sync(remoteID: UUID(), remoteName: "Other", mountpoint: "/other", status: UploadStatus(transfers: [transfer("a"), transfer("b")]))
        XCTAssertEqual(tracker.snapshot.items.count, 4)
        sync(["active", "../escape", "/absolute", "../../outside"])
        XCTAssertTrue(tracker.snapshot.items.allSatisfy { $0.path.hasPrefix("/mount/") || $0.path.hasPrefix("/other/") })
    }

    @MainActor
    func testCapEvictsDoneOldestFirstWithManyOverflowingTransfers() {
        var now = Date(timeIntervalSince1970: 1000)
        let tracker = FinderBadgeTracker(writer: RecordingBadgeWriter(), limit: 4, clock: { now }), id = UUID()
        func sync(_ names: [String]) { tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus(transfers: names.map { transfer($0) })) }
        sync(["a", "b"]); sync([]); sync([])           // a, b done at t=1000
        now.addTimeInterval(1)
        sync(["c", "d"]); sync([]); sync([])           // c, d done at t=1001
        now.addTimeInterval(1)
        sync(["e", "f", "g"])                          // 3 new into a full cap: evicts a, b, c in order
        XCTAssertEqual(tracker.snapshot.items.map(\.path), ["/m/d", "/m/e", "/m/f", "/m/g"])
        sync(["e", "f", "g", "h"])                     // d evicted, active never evicted
        XCTAssertEqual(tracker.snapshot.items.map(\.path), ["/m/e", "/m/f", "/m/g", "/m/h"])
        sync(["e", "f", "g", "h", "i"])                // full of active items: new one dropped
        XCTAssertEqual(tracker.snapshot.items.count, 4)
    }

    @MainActor
    func testTenThousandQueuedItemsSyncQuickly() {
        let tracker = FinderBadgeTracker(writer: RecordingBadgeWriter(), limit: 10_000), id = UUID()
        let all = (0..<10_000).map { transfer("f\($0)") }
        let start = Date()
        tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus(queuedCount: all.count, transfers: all))
        tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus(queuedCount: all.count, transfers: all))
        XCTAssertEqual(tracker.snapshot.items.count, 10_000)
        // Near-linear work takes well under a second; the old quadratic scan took far longer.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        // Full of done items: every new transfer evicts one without a rescan.
        tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus())
        tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus())
        let fresh = (0..<10_000).map { transfer("n\($0)") }
        let start2 = Date()
        tracker.sync(remoteID: id, remoteName: "T", mountpoint: "/m", status: UploadStatus(queuedCount: fresh.count, transfers: fresh))
        XCTAssertLessThan(Date().timeIntervalSince(start2), 10)
        XCTAssertTrue(tracker.snapshot.items.allSatisfy { $0.path.hasPrefix("/m/n") })
    }

    @MainActor
    func testDisablingClearsAndMountpointChangeReplacesOldPaths() {
        let writer = RecordingBadgeWriter()
        let tracker = FinderBadgeTracker(writer: writer, isEnabled: false), id = UUID()
        func sync(_ mount: String) { tracker.sync(remoteID: id, remoteName: "Test", mountpoint: mount, status: UploadStatus(transfers: [transfer()])) }
        sync("/mount"); XCTAssertTrue(tracker.snapshot.roots.isEmpty)
        tracker.isEnabled = true
        sync("/mount"); sync("/new")
        XCTAssertEqual(tracker.snapshot.items.map(\.path), ["/new/file"])
        tracker.isEnabled = false
        XCTAssertTrue(writer.flushes.last!.roots.isEmpty)
        let zero = FinderBadgeTracker(writer: writer, limit: -1)
        zero.sync(remoteID: id, remoteName: "Test", mountpoint: "/mount", status: UploadStatus(transfers: [transfer()]))
        XCTAssertTrue(zero.snapshot.items.isEmpty)
        XCTAssertEqual(zero.snapshot.roots, ["/mount"])
    }

    func testSharedSchemaRoundTripAndValidation() throws {
        let states: [FinderBadgeState] = [.waiting, .uploading(0), .uploading(0.5), .uploading(1), .done, .error, .retrying, .offline]
        let snapshot = FinderBadgeSnapshot(roots: ["/root/./", "/root"], items: states.enumerated().map { .init(path: "/root/\($0.offset)", state: $0.element) }, writtenAt: 123)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(try snapshot.validated().roots, ["/root"])
        XCTAssertEqual(snapshot.items.map(\.badgeIdentifier), ["waiting", "uploading-0", "uploading-50", "uploading-75", "done", "error", "retrying", "offline"])
        XCTAssertEqual(FinderBadgeSnapshot.Item(path: "/a", state: .uploading(.nan)).badgeIdentifier, "uploading-0")
        XCTAssertThrowsError(try FinderBadgeSnapshot(roots: ["relative"]).validated())
        XCTAssertThrowsError(try FinderBadgeSnapshot(items: [.init(path: "/a", state: .uploading(2))]).validated())
        XCTAssertThrowsError(try FinderBadgeSnapshot(items: [.init(path: "/a", state: .done), .init(path: "/./a", state: .done)]).validated())
        XCTAssertThrowsError(try JSONDecoder().decode(FinderBadgeSnapshot.Item.self, from: Data(#"{"path":"/a","state":"unknown"}"#.utf8)))
        let item = try JSONDecoder().decode(FinderBadgeSnapshot.Item.self, from: Data(#"{"path":"/a","state":"uploading"}"#.utf8))
        XCTAssertEqual(item.state, .uploading(0))
        XCTAssertEqual(FinderBadgeConstants.extensionBundleID(for: "ai.rmount.lite"), "ai.rmount.lite.findersync")
        XCTAssertEqual(FinderBadgeConstants.extensionBundleID(for: nil), FinderBadgeConstants.extensionBundleID)
    }
}
