import XCTest
@testable import RMountCore

final class RemoteStoreTests: DebugTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmount-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testEmptyOnFreshDirectory() throws {
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveThenLoad() throws {
        let store = RemoteStore(directory: tmpDir)
        let r = Remote(
            id: UUID(),
            name: "test",
            backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .password)),
            mountProtocol: .webdav,
            autoMount: false
        )
        try store.save([r])
        XCTAssertEqual(try store.load(), [r])
    }

    func testCorruptFileThrows() throws {
        let store = RemoteStore(directory: tmpDir)
        try "not json".write(to: tmpDir.appendingPathComponent("remotes.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }

    // MARK: tolerant loading

    private var fileURL: URL { tmpDir.appendingPathComponent("remotes.json") }

    private let goodID = "11111111-1111-1111-1111-111111111111"
    private let futureEntry = #"{"id":"22222222-2222-2222-2222-222222222222","name":"future","backend":{"quantum":{"x":1}},"mountProtocol":"webdav","autoMount":false}"#

    private func good(_ name: String = "good") -> String {
        #"{"id":"\#(goodID)","name":"\#(name)","backend":{"sftp":{"_0":{"host":"h","port":22,"user":"u","remotePath":"/","authKind":"password"}}},"mountProtocol":"webdav","autoMount":false}"#
    }

    private func goodRemote() -> Remote {
        Remote(id: UUID(uuidString: goodID)!, name: "good",
               backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .password)),
               mountProtocol: .webdav, autoMount: false)
    }

    func testUnknownBackendIsSkippedAndOthersLoad() throws {
        try "[\(good()),\(futureEntry)]".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load(), [goodRemote()])
        XCTAssertEqual(store.skippedEntries.map(\.name), ["future"])
        XCTAssertTrue(store.skippedNotice?.contains("future") == true)
    }

    func testUnknownEnumValueIsSkipped() throws {
        let bad = good("odd").replacingOccurrences(of: "\"webdav\"", with: "\"carrierpigeon\"")
        try "[\(bad)]".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(store.skippedEntries.count, 1)
    }

    func testCorruptEntryIsSkipped() throws {
        try "[\(good()), 42, {\"name\": 7}]".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertEqual(store.skippedEntries.count, 2)
        XCTAssertNil(store.skippedEntries[0].name)
        XCTAssertTrue(store.skippedNotice?.contains("entry #2") == true)
    }

    func testNoNoticeWhenEverythingLoads() throws {
        let store = RemoteStore(directory: tmpDir)
        try store.save([goodRemote()])
        _ = try store.load()
        XCTAssertNil(store.skippedNotice)
    }

    func testSavePreservesSkippedEntriesAndBacksUp() throws {
        let original = "[\(good()),\(futureEntry)]"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = RemoteStore(directory: tmpDir)
        var remotes = try store.load()
        remotes[0].name = "renamed"
        try store.save(remotes)
        XCTAssertEqual(try String(contentsOf: store.backupURL, encoding: .utf8), original)

        let again = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try again.load().map(\.name), ["renamed"])
        XCTAssertEqual(again.skippedEntries.map(\.name), ["future"])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
        let kept = raw.first { $0["name"] as? String == "future" }
        XCTAssertEqual((kept?["backend"] as? [String: Any])?["quantum"] as? [String: Int], ["x": 1])
    }

    func testBackupOnlyAfterSkippedLoadAndNotOverwrittenBySecondSave() throws {
        let store = RemoteStore(directory: tmpDir)
        try store.save([goodRemote()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))

        let original = "[\(good()),\(futureEntry)]"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try store.load()
        try store.save([goodRemote()])
        try store.save([goodRemote()])
        XCTAssertEqual(try String(contentsOf: store.backupURL, encoding: .utf8), original)
    }

    func testVersionedObjectFormIsReadAndKept() throws {
        try #"{"version": 3, "remotes": [\#(good())]}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load(), [goodRemote()])
        XCTAssertEqual(store.fileVersion, 3)
        try store.save([goodRemote()])
        let again = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try again.load(), [goodRemote()])
        XCTAssertEqual(again.fileVersion, 3)
    }

    func testNonListRootStillThrows() throws {
        try #"{"foo": 1}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RemoteStore(directory: tmpDir).load())
    }
}
