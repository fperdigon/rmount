import XCTest
@testable import RMountCore

final class UserPreferencesTests: DebugTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "rmount.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultProtocolFallsBackToWebDAV() {
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .webdav)
    }

    func testDefaultProtocolPersists() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.defaultProtocol = .nfs
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .nfs)
    }

    func testInvalidStoredProtocolFallsBack() {
        defaults.set("bogus", forKey: "rmount.defaultProtocol")
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .webdav)
    }

    func testCustomRclonePathDefaultsToNil() {
        XCTAssertNil(UserPreferences(defaults: defaults).customRclonePath)
    }

    func testCustomRclonePathIsTrimmed() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "  /usr/local/bin/rclone \n"
        XCTAssertEqual(prefs.customRclonePath, "/usr/local/bin/rclone")
    }

    func testBlankOrNilClearsCustomRclonePath() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "/x"
        prefs.customRclonePath = "   "
        XCTAssertNil(prefs.customRclonePath)
        prefs.customRclonePath = "/x"
        prefs.customRclonePath = nil
        XCTAssertNil(prefs.customRclonePath)
    }

    func testFinderUploadProgressDefaultsToEnabled() {
        XCTAssertTrue(UserPreferences(defaults: defaults).showFinderUploadProgress)
    }

    func testFinderUploadProgressPersistsUnderCurrentKey() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.showFinderUploadProgress = false
        XCTAssertFalse(UserPreferences(defaults: defaults).showFinderUploadProgress)
        XCTAssertEqual(defaults.object(forKey: "rmount.showFinderUploadProgress") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "macsh.showFinderUploadProgress"))
        prefs.showFinderUploadProgress = true
        XCTAssertTrue(UserPreferences(defaults: defaults).showFinderUploadProgress)
    }

    func testFinderUploadProgressNotifiesWhenChanged() {
        let prefs = UserPreferences(defaults: defaults)
        let changed = expectation(forNotification: UserPreferences.showFinderUploadProgressDidChange,
                                  object: prefs) { _ in
            !prefs.showFinderUploadProgress
        }
        prefs.showFinderUploadProgress = false
        wait(for: [changed], timeout: 1)
    }

    func testFinderUploadProgressDoesNotNotifyForUnchangedValue() {
        let prefs = UserPreferences(defaults: defaults)
        let unchanged = expectation(forNotification: UserPreferences.showFinderUploadProgressDidChange,
                                    object: prefs)
        unchanged.isInverted = true
        prefs.showFinderUploadProgress = true
        wait(for: [unchanged], timeout: 0.05)
    }
    func testFinderBadgesDefaultToEnabledAndPersistUnderCurrentKey() {
        let prefs = UserPreferences(defaults: defaults)
        XCTAssertTrue(prefs.showFinderBadges)
        prefs.showFinderBadges = false
        XCTAssertFalse(UserPreferences(defaults: defaults).showFinderBadges)
        XCTAssertEqual(defaults.object(forKey: "rmount.showFinderBadges") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "macsh.showFinderBadges"))
        prefs.showFinderBadges = true
        XCTAssertTrue(UserPreferences(defaults: defaults).showFinderBadges)
    }

    func testFinderBadgesNotifyOnlyWhenChanged() {
        let prefs = UserPreferences(defaults: defaults)
        let changed = expectation(forNotification: UserPreferences.showFinderBadgesDidChange,
                                  object: prefs) { _ in !prefs.showFinderBadges }
        prefs.showFinderBadges = false
        wait(for: [changed], timeout: 1)
        let unchanged = expectation(forNotification: UserPreferences.showFinderBadgesDidChange,
                                    object: prefs)
        unchanged.isInverted = true
        prefs.showFinderBadges = false
        wait(for: [unchanged], timeout: 0.05)
    }

}
