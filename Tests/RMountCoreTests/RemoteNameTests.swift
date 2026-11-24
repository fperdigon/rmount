import XCTest
@testable import RMountCore

final class RemoteNameTests: DebugTestCase {
    func testValidateAcceptsOrdinaryNames() throws {
        for name in ["My NAS", "work-2", "dev.env", "Ünï"] { XCTAssertNoThrow(try RemoteName.validate(name)) }
    }

    func testValidateRejectsBadNames() {
        XCTAssertThrowsError(try RemoteName.validate("  ")) { XCTAssertEqual($0 as? RemoteNameError, .empty) }
        XCTAssertThrowsError(try RemoteName.validate("..")) { XCTAssertEqual($0 as? RemoteNameError, .reserved) }
        XCTAssertThrowsError(try RemoteName.validate(".")) { XCTAssertEqual($0 as? RemoteNameError, .reserved) }
        XCTAssertThrowsError(try RemoteName.validate("a/b")) { XCTAssertEqual($0 as? RemoteNameError, .invalidCharacter) }
        XCTAssertThrowsError(try RemoteName.validate("a\nb")) { XCTAssertEqual($0 as? RemoteNameError, .invalidCharacter) }
        XCTAssertFalse((RemoteNameError.empty.errorDescription ?? "").isEmpty)
        XCTAssertFalse((RemoteNameError.reserved.errorDescription ?? "").isEmpty)
        XCTAssertFalse((RemoteNameError.invalidCharacter.errorDescription ?? "").isEmpty)
    }

    func testPathComponentSanitizes() {
        XCTAssertEqual(RemoteName.pathComponent(from: "a/b"), "a-b")
        XCTAssertEqual(RemoteName.pathComponent(from: "../x"), "x")
        XCTAssertEqual(RemoteName.pathComponent(from: ".."), "rmount-mount")
        XCTAssertEqual(RemoteName.pathComponent(from: "-rf"), "rf")
        XCTAssertEqual(RemoteName.pathComponent(from: "a\u{0}b\n"), "ab")
        XCTAssertEqual(RemoteName.pathComponent(from: "host:1"), "host-1")
    }
}
