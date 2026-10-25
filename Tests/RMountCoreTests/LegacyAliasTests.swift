import XCTest
@testable import RMountCore

/// The old macsh names stay readable as aliases of the RMount ones (see LegacyNames).
final class LegacyAliasTests: XCTestCase {
    // MARK: names

    func testLegacyBundleIDsKeepTheFlavorSuffix() {
        XCTAssertEqual(LegacyNames.legacyBundleIDs(for: "ai.rmount"), ["ai.macsh"])
        XCTAssertEqual(LegacyNames.legacyBundleIDs(for: "ai.rmount.lite"), ["ai.macsh.lite"])
        XCTAssertEqual(LegacyNames.legacyBundleIDs(for: "com.example.other"), [])
    }

    // MARK: Application Support

    private func supportBase() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private func ids() -> (new: String, old: String) {
        let n = UUID().uuidString
        return ("ai.rmount.tests.\(n)", "ai.macsh.tests.\(n)")
    }

    func testSupportDirectoryIsCopiedFromTheOldBundleID() throws {
        let (new, old) = ids()
        let base = try supportBase()
        let oldDir = base.appendingPathComponent(old)
        try FileManager.default.createDirectory(at: oldDir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("[remotes]".utf8).write(to: oldDir.appendingPathComponent("remotes.json"))
        defer {
            try? FileManager.default.removeItem(at: oldDir)
            try? FileManager.default.removeItem(at: base.appendingPathComponent(new))
        }

        let dir = try AppPaths.applicationSupport(bundleID: new, legacyBundleIDs: [old])

        XCTAssertEqual(dir.lastPathComponent, new)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("remotes.json"), encoding: .utf8), "[remotes]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("logs").path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".migrated-from"), encoding: .utf8), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("remotes.json").path),
                      "the old directory is kept so an older version still works")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("\(new).migrating").path))
    }

    func testSupportDirectoryIsOnlyMigratedOnce() throws {
        let (new, old) = ids()
        let base = try supportBase()
        let oldDir = base.appendingPathComponent(old)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldDir.appendingPathComponent("remotes.json"))
        defer {
            try? FileManager.default.removeItem(at: oldDir)
            try? FileManager.default.removeItem(at: base.appendingPathComponent(new))
        }
        let dir = try AppPaths.applicationSupport(bundleID: new, legacyBundleIDs: [old])
        try Data("edited".utf8).write(to: dir.appendingPathComponent("remotes.json"))
        try Data("old-changed".utf8).write(to: oldDir.appendingPathComponent("remotes.json"))

        _ = try AppPaths.applicationSupport(bundleID: new, legacyBundleIDs: [old])

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("remotes.json"), encoding: .utf8), "edited")
    }

    func testSupportDirectoryWithoutAnOldOneIsEmpty() throws {
        let (new, old) = ids()
        let dir = try AppPaths.applicationSupport(bundleID: new, legacyBundleIDs: [old])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: Keychain

    func testKeychainFindsASecretStoredUnderTheOldServiceAndCopiesIt() throws {
        let oldName = "ai.macsh.tests.\(UUID().uuidString)"
        let old = KeychainService(serviceName: oldName)
        let newName = "ai.rmount.tests.\(UUID().uuidString)"
        let aliased = KeychainService(serviceName: newName, legacyServiceNames: [oldName])
        let plain = KeychainService(serviceName: newName)
        let id = UUID()
        defer {
            try? old.delete(remoteID: id, kind: .password)
            try? aliased.delete(remoteID: id, kind: .password)
        }
        try old.set(remoteID: id, kind: .password, value: "hunter2")
        XCTAssertNil(try plain.get(remoteID: id, kind: .password))

        XCTAssertEqual(try aliased.get(remoteID: id, kind: .password), "hunter2")
        XCTAssertEqual(try plain.get(remoteID: id, kind: .password), "hunter2", "copied to the new service")
        XCTAssertEqual(try old.get(remoteID: id, kind: .password), "hunter2", "the old item is left alone")
    }

    func testKeychainPrefersTheNewServiceAndWritesThere() throws {
        let oldName = "ai.macsh.tests.\(UUID().uuidString)"
        let old = KeychainService(serviceName: oldName)
        let newName = "ai.rmount.tests.\(UUID().uuidString)"
        let aliased = KeychainService(serviceName: newName, legacyServiceNames: [oldName])
        let id = UUID()
        defer {
            try? old.delete(remoteID: id, kind: .password)
            try? aliased.delete(remoteID: id, kind: .password)
        }
        try old.set(remoteID: id, kind: .password, value: "old")
        try aliased.set(remoteID: id, kind: .password, value: "new")

        XCTAssertEqual(try aliased.get(remoteID: id, kind: .password), "new")
        XCTAssertEqual(try old.get(remoteID: id, kind: .password), "old")
    }

    func testKeychainDeleteRemovesTheOldItemToo() throws {
        let oldName = "ai.macsh.tests.\(UUID().uuidString)"
        let old = KeychainService(serviceName: oldName)
        let aliased = KeychainService(serviceName: "ai.rmount.tests.\(UUID().uuidString)", legacyServiceNames: [oldName])
        let id = UUID()
        try old.set(remoteID: id, kind: .password, value: "x")

        try aliased.delete(remoteID: id, kind: .password)

        XCTAssertNil(try aliased.get(remoteID: id, kind: .password))
        XCTAssertNil(try old.get(remoteID: id, kind: .password))
    }

    // MARK: preferences

    private func suite() -> (name: String, defaults: UserDefaults) {
        let name = "rmount.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return (name, d)
    }

    func testPreferencesAreCopiedFromTheOldKeysInTheSameDomain() {
        let (_, d) = suite()
        d.set("nightly", forKey: "macsh.updateChannel")
        d.set(false, forKey: "macsh.autoCheckUpdates")
        d.set("nfs", forKey: "macsh.defaultProtocol")

        let prefs = UserPreferences(defaults: d)

        XCTAssertEqual(prefs.updateChannel, .nightly)
        XCTAssertFalse(prefs.autoCheckUpdates)
        XCTAssertEqual(prefs.defaultProtocol, .nfs)
        XCTAssertEqual(d.string(forKey: "rmount.updateChannel"), "nightly")
        XCTAssertEqual(d.string(forKey: "macsh.updateChannel"), "nightly", "old keys stay for an older version")
    }

    func testPreferencesAreCopiedFromTheOldDomain() {
        let (_, d) = suite()
        let (oldName, oldDefaults) = suite()
        oldDefaults.set("/opt/rclone", forKey: "macsh.customRclonePath")
        oldDefaults.set("v0.1.4", forKey: "macsh.skippedUpdateTag")

        let prefs = UserPreferences(defaults: d, legacyDomains: [oldName])

        XCTAssertEqual(prefs.customRclonePath, "/opt/rclone")
        XCTAssertEqual(prefs.skippedUpdateTag, "v0.1.4")
    }

    func testNewPreferenceWinsOverTheOldOne() {
        let (_, d) = suite()
        d.set("stable", forKey: "rmount.updateChannel")
        d.set("nightly", forKey: "macsh.updateChannel")
        XCTAssertEqual(UserPreferences(defaults: d).updateChannel, .stable)
    }

    func testPreferencesAreMigratedOnlyOnce() {
        let (_, d) = suite()
        _ = UserPreferences(defaults: d)
        d.set("nightly", forKey: "macsh.updateChannel")
        XCTAssertEqual(UserPreferences(defaults: d).updateChannel, .stable)
    }

    // MARK: mounts, assets, build info

    func testMounterSearchesTheOldMountFolderOnlyWithItsDefaultBase() {
        XCTAssertEqual(Mounter().legacyMountBases.map(\.lastPathComponent), ["macsh"])
        XCTAssertEqual(Mounter(mountBase: URL(fileURLWithPath: "/tmp/x")).legacyMountBases, [])
    }

    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.com/\(name)")!, size: 1, digest: nil)
    }

    func testAssetSelectionFallsBackToTheOldNames() {
        let old = [asset("macsh-0.1.4.dmg"), asset("macsh-lite-0.1.4.dmg")]
        XCTAssertEqual(UpdateChecker.selectAsset(old, lite: false)?.name, "macsh-0.1.4.dmg")
        XCTAssertEqual(UpdateChecker.selectAsset(old, lite: true)?.name, "macsh-lite-0.1.4.dmg")
    }

    func testAssetSelectionPrefersTheNewNames() {
        let both = [asset("macsh-0.2.0.dmg"), asset("macsh-lite-0.2.0.dmg"), asset("rmount-0.2.0.dmg"), asset("rmount-lite-0.2.0.dmg")]
        XCTAssertEqual(UpdateChecker.selectAsset(both, lite: false)?.name, "rmount-0.2.0.dmg")
        XCTAssertEqual(UpdateChecker.selectAsset(both, lite: true)?.name, "rmount-lite-0.2.0.dmg")
    }

    func testBuildInfoReadsTheOldBuildSHAKey() {
        let info = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.4", "MacshBuildSHA": "abc1234def"], bundleIdentifier: "ai.macsh")
        XCTAssertEqual(info.sha, "abc1234def")
        let both = BuildInfo(infoDictionary: ["RMountBuildSHA": "new", "MacshBuildSHA": "old"], bundleIdentifier: "ai.rmount")
        XCTAssertEqual(both.sha, "new")
    }
}
