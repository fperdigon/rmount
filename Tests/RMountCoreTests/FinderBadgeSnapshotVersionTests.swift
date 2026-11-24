import XCTest
@testable import RMountCore

final class FinderBadgeSnapshotVersionTests: XCTestCase {
    func testMissingSchemaVersionDecodesAsOne() throws {
        let json = Data(#"{"roots":["/r"],"items":[{"path":"/r/a","state":"done"}],"writtenAt":5}"#.utf8)
        let snapshot = try JSONDecoder().decode(FinderBadgeSnapshot.self, from: json)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertTrue(FinderBadgeSnapshot.isSupported(data: json))
        XCTAssertNoThrow(try snapshot.validated())
    }

    func testEncodedSnapshotCarriesCurrentVersionAndRoundTrips() throws {
        let snapshot = FinderBadgeSnapshot(roots: ["/r"], items: [.init(path: "/r/a", state: .waiting)], writtenAt: 1)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(FinderBadgeSnapshot.schemaVersion(of: data), FinderBadgeSnapshot.currentSchemaVersion)
        XCTAssertEqual(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: data), snapshot)
    }

    func testNewerVersionIsUnsupportedEvenWhenItsItemsDoNotDecode() throws {
        let json = Data(#"{"schemaVersion":2,"roots":[],"items":[{"path":"/x","state":"paused"}],"writtenAt":1}"#.utf8)
        XCTAssertFalse(FinderBadgeSnapshot.isSupported(data: json))
        XCTAssertEqual(FinderBadgeSnapshot.schemaVersion(of: json), 2)
        XCTAssertThrowsError(try JSONDecoder().decode(FinderBadgeSnapshot.self, from: json))
        XCTAssertThrowsError(try FinderBadgeSnapshot(roots: ["/r"], schemaVersion: 2).validated())
    }

    func testUnreadableVersionProbeFallsBackToOne() {
        XCTAssertEqual(FinderBadgeSnapshot.schemaVersion(of: Data("nope".utf8)), 1)
    }
}
