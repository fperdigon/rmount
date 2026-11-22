import XCTest
@testable import RMountCore

private final class FailingBadgeFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

final class FinderBadgeStatusWriterTests: DebugTestCase {
    @MainActor
    func testAtomicWriteCreatesDirectoryReplacesFileAndLeavesNoTemporaryFiles() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("nested/support")
        let writer = FinderBadgeStatusWriter(baseDirectory: destination)
        let first = FinderBadgeSnapshot(roots: ["/root"], items: [.init(path: "/root/a", state: .waiting)], writtenAt: 1)
        writer.flush(first)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)), first)
        let second = FinderBadgeSnapshot(roots: ["/other"], writtenAt: 2)
        writer.flush(second)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["status.json"])
    }

    @MainActor
    func testCoalescingGuaranteesTrailingLatestSnapshotAndSkipsUnchanged() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FinderBadgeStatusWriter(baseDirectory: directory, interval: 0.10)
        let first = FinderBadgeSnapshot(roots: ["/first"], writtenAt: 1)
        writer.write(first)
        writer.waitForSubmittedWrites()
        writer.write(FinderBadgeSnapshot(roots: ["/discarded"], writtenAt: 2))
        let latest = FinderBadgeSnapshot(roots: ["/latest"], writtenAt: 3)
        writer.write(latest)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)), first)
        try await Task.sleep(nanoseconds: 200_000_000)
        writer.waitForSubmittedWrites()
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)), latest)
        writer.flush(FinderBadgeSnapshot(roots: latest.roots, writtenAt: 99))
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)).writtenAt, 3)
    }

    @MainActor
    func testOverdueTimerCannotConsumeANewerPendingWriteEarly() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FinderBadgeStatusWriter(baseDirectory: directory, interval: 0.1)
        writer.write(FinderBadgeSnapshot(roots: ["/first"]))
        writer.write(FinderBadgeSnapshot(roots: ["/old-pending"]))
        // Model a busy main run loop that cannot resume its trailing task on time.
        func blockRunLoop() { Thread.sleep(forTimeInterval: 0.15) }
        blockRunLoop()
        writer.write(FinderBadgeSnapshot(roots: ["/immediate"]))
        writer.write(FinderBadgeSnapshot(roots: ["/new-pending"]))
        try await Task.sleep(nanoseconds: 20_000_000)
        writer.waitForSubmittedWrites()
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)).roots, ["/immediate"])
        try await Task.sleep(nanoseconds: 150_000_000)
        writer.waitForSubmittedWrites()
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: Data(contentsOf: writer.statusURL)).roots, ["/new-pending"])
    }

    @MainActor
    func testFlushCancelsTrailingAndEmptiesBeforeReturning() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FinderBadgeStatusWriter(baseDirectory: directory, interval: 0.1)
        writer.write(FinderBadgeSnapshot(roots: ["/root"]))
        writer.write(FinderBadgeSnapshot(roots: ["/pending"]))
        writer.flush(FinderBadgeSnapshot(writtenAt: 42))
        let data = try Data(contentsOf: writer.statusURL)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: data).roots, [])
        try await Task.sleep(nanoseconds: 150_000_000)
        writer.waitForSubmittedWrites()
        XCTAssertEqual(try Data(contentsOf: writer.statusURL), data)
    }

    @MainActor
    func testDiskAndEncodingFailuresAreDroppedWithoutThrowing() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FinderBadgeStatusWriter(baseDirectory: directory.appendingPathComponent("missing"), fileManager: FailingBadgeFileManager())
        writer.flush(FinderBadgeSnapshot(roots: ["/root"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.statusURL.path))
        let encoding = FinderBadgeStatusWriter(baseDirectory: directory)
        encoding.flush(FinderBadgeSnapshot(items: [.init(path: "/a", state: .uploading(.nan))]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: encoding.statusURL.path))
    }

    @MainActor
    func testContainerPathUsesMatchingFlavorAndInjectedHome() {
        let path = FinderBadgeStatusWriter.containerDirectory(extensionBundleID: "ai.rmount.lite.findersync", homeDirectory: URL(fileURLWithPath: "/test/home"))
        XCTAssertEqual(path.path, "/test/home/Library/Containers/ai.rmount.lite.findersync/Data/Library/Application Support")
        let writer = FinderBadgeStatusWriter(extensionBundleID: "test.findersync")
        XCTAssertTrue(writer.statusURL.path.hasSuffix("/Library/Containers/test.findersync/Data/Library/Application Support/status.json"))
    }
}
