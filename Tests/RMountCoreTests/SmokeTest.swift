import XCTest
@testable import RMountCore

final class SmokeTest: XCTestCase {
    func testVersionExposed() {
        XCTAssertEqual(RMountCore.version, "0.1.0-phase1")
    }
}
