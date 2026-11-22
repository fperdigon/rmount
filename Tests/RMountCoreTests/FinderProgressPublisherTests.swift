import XCTest
@testable import RMountCore

@MainActor
private final class RecordingFinderHandle: FinderProgressHandle {
    let fileURL: URL
    let initialTotal: Int64
    var updates: [(completed: Int64, total: Int64)] = []
    var finishCount = 0

    init(fileURL: URL, total: Int64) { self.fileURL = fileURL; initialTotal = total }
    func update(completed: Int64, total: Int64) { updates.append((completed, total)) }
    func finish() { finishCount += 1 }
}

@MainActor
private final class RecordingFinderFactory: FinderProgressFactory {
    var handles: [RecordingFinderHandle] = []
    func makeHandle(for fileURL: URL, total: Int64) -> FinderProgressHandle {
        let handle = RecordingFinderHandle(fileURL: fileURL, total: total)
        handles.append(handle)
        return handle
    }
}

final class FinderProgressPublisherTests: DebugTestCase {
    private func transfer(_ path: String, state: TransferProgress.State = .queued,
                          done: Int64? = nil, total: Int64? = 100) -> TransferProgress {
        TransferProgress(path: path, state: state, bytesDone: done, totalBytes: total,
                         fraction: nil, speed: nil, eta: nil)
    }

    @MainActor
    func testPublishesQueuedAndUploadingThenUpdatesAndAcceptsRestart() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let id = UUID()
        publisher.sync(remoteID: id, mountpoint: "/Volumes/Test", status: UploadStatus(transfers: [
            transfer("queued"), transfer("upload", state: .uploading, done: 40)
        ]))
        XCTAssertEqual(factory.handles.map(\.fileURL.lastPathComponent), ["upload", "queued"])
        XCTAssertEqual(factory.handles.map(\.initialTotal), [100, 100])
        let uploading = factory.handles[0]
        XCTAssertEqual(uploading.updates.last?.completed, 40)
        XCTAssertEqual(factory.handles[1].updates.last?.completed, 0)
        for bytes in [Int64(80), 20, -10, 300] {
            publisher.sync(remoteID: id, mountpoint: "/Volumes/Test", status: UploadStatus(transfers: [
                transfer("upload", state: .uploading, done: bytes, total: 200), transfer("queued")
            ]))
        }
        XCTAssertEqual(factory.handles.count, 2)
        XCTAssertEqual(uploading.updates.map(\.completed), [40, 80, 20, 0, 200])
        XCTAssertEqual(uploading.updates.last?.total, 200)
        publisher.clearAll()
    }

    @MainActor
    func testStaleSyncNeitherUpdatesCreatesNorFinishes() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let id = UUID()
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(transfers: [transfer("file", done: 10)]))
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(transfers: [
            transfer("file", done: 80), transfer("new")
        ], isStale: true))
        publisher.sync(remoteID: id, mountpoint: nil, status: UploadStatus(isStale: true))
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(isStale: true))
        XCTAssertEqual(factory.handles.count, 1)
        XCTAssertEqual(factory.handles[0].updates.count, 1)
        XCTAssertEqual(factory.handles[0].finishCount, 0)
        publisher.clearAll()
    }

    @MainActor
    func testRequiresTwoNonStaleAbsencesAndReappearanceResetsConfirmation() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let id = UUID()
        let present = UploadStatus(transfers: [transfer("file", state: .retrying)])
        publisher.sync(remoteID: id, mountpoint: "/mount", status: present)
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus())
        XCTAssertEqual(factory.handles[0].finishCount, 0)
        publisher.sync(remoteID: id, mountpoint: "/mount", status: present)
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus())
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(isStale: true))
        XCTAssertEqual(factory.handles[0].finishCount, 0)
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus())
        XCTAssertEqual(factory.handles[0].finishCount, 1)
        publisher.clearAll()
        XCTAssertEqual(factory.handles[0].finishCount, 1)
    }

    @MainActor
    func testClearIsPerRemoteAndClearAllFinishesTheRest() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let first = UUID(), second = UUID()
        let status = UploadStatus(transfers: [transfer("file")])
        publisher.sync(remoteID: first, mountpoint: "/first", status: status)
        publisher.sync(remoteID: second, mountpoint: "/second", status: status)
        publisher.clear(remoteID: first)
        publisher.clear(remoteID: first)
        XCTAssertEqual(factory.handles.map(\.finishCount), [1, 0])
        publisher.clearAll()
        XCTAssertEqual(factory.handles.map(\.finishCount), [1, 1])
    }

    @MainActor
    func testCapPrioritizesUploadingThenQueueOrderAndFillsFreedSlot() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory, limit: 2)
        let id = UUID()
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(transfers: [
            transfer("queued-first"), transfer("queued-second"), transfer("upload", state: .uploading)
        ]))
        XCTAssertEqual(factory.handles.map(\.fileURL.lastPathComponent), ["upload", "queued-first"])
        let remaining = UploadStatus(transfers: [transfer("queued-second"), transfer("upload", state: .uploading)])
        publisher.sync(remoteID: id, mountpoint: "/mount", status: remaining)
        XCTAssertEqual(factory.handles.count, 2)
        publisher.sync(remoteID: id, mountpoint: "/mount", status: remaining)
        XCTAssertEqual(factory.handles.map(\.fileURL.lastPathComponent), ["upload", "queued-first", "queued-second"])
        XCTAssertEqual(factory.handles[1].finishCount, 1)
        publisher.clearAll()
    }

    @MainActor
    func testDefaultCapIsPerRemoteAndZeroLimitPublishesNothing() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let status = UploadStatus(transfers: (0...150).map { transfer("file\($0)") })
        publisher.sync(remoteID: UUID(), mountpoint: "/first", status: status)
        publisher.sync(remoteID: UUID(), mountpoint: "/second", status: status)
        XCTAssertEqual(factory.handles.count, 300)
        let disabledByLimit = FinderProgressPublisher(factory: factory, limit: -1)
        disabledByLimit.sync(remoteID: UUID(), mountpoint: "/third", status: status)
        XCTAssertEqual(factory.handles.count, 300)
        publisher.clearAll()
    }

    @MainActor
    func testSkipsUnknownAndEmptySizesButKeepsExistingHandleWhenSizeUnknown() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let id = UUID()
        publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(transfers: [
            transfer("known"), transfer("unknown", total: nil), transfer("zero", total: 0), transfer("negative", total: -1)
        ]))
        for _ in 0..<2 {
            publisher.sync(remoteID: id, mountpoint: "/mount", status: UploadStatus(transfers: [transfer("known", total: nil)]))
        }
        XCTAssertEqual(factory.handles.count, 1)
        XCTAssertEqual(factory.handles[0].finishCount, 0)
        XCTAssertEqual(factory.handles[0].updates.count, 1)
        publisher.clearAll()
    }

    @MainActor
    func testMountpointAndPathMapping() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory)
        let id = UUID()
        let status = UploadStatus(transfers: [transfer("sub folder/日本語/café file.txt")])
        publisher.sync(remoteID: id, mountpoint: nil, status: status)
        XCTAssertTrue(factory.handles.isEmpty)
        publisher.sync(remoteID: id, mountpoint: "/Volumes/My Remote", status: status)
        XCTAssertEqual(factory.handles[0].fileURL.path, "/Volumes/My Remote/sub folder/日本語/café file.txt")
        XCTAssertTrue(factory.handles[0].fileURL.isFileURL)
        publisher.sync(remoteID: id, mountpoint: nil, status: status)
        XCTAssertEqual(factory.handles[0].finishCount, 1)
    }

    @MainActor
    func testDisablingClearsEveryRemoteAndEnablingPublishesAgain() {
        let factory = RecordingFinderFactory()
        let publisher = FinderProgressPublisher(factory: factory, isEnabled: false)
        let id = UUID()
        let status = UploadStatus(transfers: [transfer("file")])
        publisher.sync(remoteID: id, mountpoint: "/mount", status: status)
        XCTAssertTrue(factory.handles.isEmpty)
        publisher.isEnabled = true
        publisher.sync(remoteID: id, mountpoint: "/mount", status: status)
        publisher.sync(remoteID: UUID(), mountpoint: "/other", status: status)
        publisher.isEnabled = false
        XCTAssertEqual(factory.handles.map(\.finishCount), [1, 1])
        publisher.sync(remoteID: id, mountpoint: "/mount", status: status)
        XCTAssertEqual(factory.handles.count, 2)
        publisher.isEnabled = true
        publisher.sync(remoteID: id, mountpoint: "/mount", status: status)
        XCTAssertEqual(factory.handles.count, 3)
        publisher.clearAll()
    }

    @MainActor
    func testFoundationFactoryPublishesUpdatesAndFinishesForTemporaryFile() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("upload.txt")
        try Data("upload".utf8).write(to: file)
        let handle = FoundationFinderProgressFactory().makeHandle(for: file, total: 6)
        handle.update(completed: 3, total: 6)
        handle.finish()
    }
}
