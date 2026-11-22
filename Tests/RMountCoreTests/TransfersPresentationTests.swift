import XCTest
@testable import RMountCore

final class TransfersPresentationTests: XCTestCase {
    private func status(_ paths: [String], uploading: Bool = false) -> UploadStatus {
        VFSQueue(queue: paths.map { .init(name: $0, size: 100, uploading: uploading) }).status
    }

    func testAllRemotesIncludesPendingAndStaleInConfiguredOrder() {
        let remotes = (0..<5).map { makeRemote(name: "Server \($0)", backend: sftpBackend()) }
        let pending = status(["a", "b"], uploading: true)
        let stale = UploadStatus(isStale: true)
        let rowsOnly = UploadStatus(transfers: status(["file"]).transfers)
        let model = TransfersPresentation(remotes: remotes, statuses: [
            remotes[0].id: pending, remotes[1].id: stale,
            remotes[2].id: UploadStatus(), remotes[3].id: rowsOnly
        ], selectedRemoteID: nil)

        XCTAssertNil(model.selectedRemoteID)
        XCTAssertEqual(model.options.map(\.id), remotes.map(\.id))
        XCTAssertEqual(model.options.map(\.label), ["Server 0 (2 active)", "Server 1 (0 active)",
                                                      "Server 2 (0 active)", "Server 3 (0 active)",
                                                      "Server 4 (0 active)"])
        XCTAssertEqual(model.sections.map(\.id), [remotes[0].id, remotes[1].id, remotes[3].id])
        XCTAssertEqual(model.sections[0].name, remotes[0].name)
        XCTAssertEqual(model.sections[0].status, pending)
        XCTAssertEqual(model.sections[1].status, stale)
        XCTAssertEqual(model.sections[2].rows.map(\.transfer.path), ["file"])
    }

    func testFilterShowsOnlySelectedRemoteIncludingIdleRemote() {
        let active = makeRemote(name: "Same name", backend: sftpBackend())
        let idle = makeRemote(name: "Same name", backend: sftpBackend())
        let statuses = [active.id: status(["a"])]
        for remote in [active, idle] {
            let model = TransfersPresentation(remotes: [active, idle], statuses: statuses,
                                              selectedRemoteID: remote.id)
            XCTAssertEqual(model.selectedRemoteID, remote.id)
            XCTAssertEqual(model.sections.map(\.id), [remote.id])
            XCTAssertEqual(model.sections[0].rows.count, remote.id == active.id ? 1 : 0)
        }
    }

    func testEmptyAndRemovedSelectionFallsBackToAll() {
        let remote = makeRemote(backend: sftpBackend())
        let empty = TransfersPresentation(remotes: [], statuses: [:], selectedRemoteID: UUID())
        XCTAssertNil(empty.selectedRemoteID)
        XCTAssertTrue(empty.options.isEmpty)
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertTrue(TransfersPresentation(remotes: [remote], statuses: [:], selectedRemoteID: nil).sections.isEmpty)
        let removed = TransfersPresentation(remotes: [remote], statuses: [remote.id: status(["a"])],
                                            selectedRemoteID: UUID())
        XCTAssertNil(removed.selectedRemoteID)
        XCTAssertEqual(removed.sections.map(\.id), [remote.id])
    }

    func testStableUniqueIDsSurviveUnrelatedInsertionReorderAndProgress() {
        let remote = makeRemote(backend: sftpBackend())
        func rows(_ paths: [String], uploading: Bool = false) -> [TransfersPresentation.FileRow] {
            TransfersPresentation(remotes: [remote], statuses: [remote.id: status(paths, uploading: uploading)],
                                  selectedRemoteID: nil).sections[0].rows
        }
        let before = rows(["dir/a", "b", "dir/a", "dir/a#1", "other/a", ""])
        let after = rows(["new", "b", "dir/a", "dir/a", "dir/a#1", "other/a", ""], uploading: true)
        XCTAssertEqual(Set(before.map(\.id)).count, before.count)
        XCTAssertEqual(before[0].id.path, "dir/a")
        XCTAssertEqual(before[0].id.occurrence, 0)
        XCTAssertEqual(before[2].id.occurrence, 1)
        XCTAssertEqual(before[0].id, after[2].id)
        XCTAssertEqual(before[1].id, after[1].id)
        XCTAssertEqual(before[2].id, after[3].id)
        XCTAssertEqual(before[3].id, after[4].id)
        XCTAssertEqual(before[4].id, after[5].id)
        XCTAssertEqual(before[5].id, after[6].id)
        XCTAssertNotEqual(before[0].transfer.state, after[2].transfer.state)
        XCTAssertEqual(rows(["b"])[0].id, before[1].id)
    }

    func testLongListUsesBoundedScrollWithoutDroppingFilesOrOtherRemotes() {
        let first = makeRemote(backend: sftpBackend())
        let second = makeRemote(backend: sftpBackend())
        for count in [0, 3, 4, 500] {
            let paths = (0..<count).map { "folder/file\($0)" }
            let model = TransfersPresentation(remotes: [first, second],
                                              statuses: [first.id: status(paths), second.id: status(["other"])],
                                              selectedRemoteID: first.id)
            XCTAssertEqual(model.sections[0].scrollsFiles, count > 3)
            XCTAssertEqual(model.sections[0].rows.map(\.transfer.path), paths)
        }
        let all = TransfersPresentation(remotes: [first, second],
                                        statuses: [first.id: status((0..<500).map { "file\($0)" }),
                                                   second.id: status(["other"])], selectedRemoteID: nil)
        XCTAssertEqual(all.sections.count, 2)
        XCTAssertEqual(all.sections[1].rows[0].transfer.path, "other")
        XCTAssertFalse(all.sections[1].scrollsFiles)
    }
}
