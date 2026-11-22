import XCTest
@testable import RMountCore

@MainActor
final class FinderExtensionPromptPolicyTests: DebugTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: UserPreferences!
    private let bundleID = "ai.rmount.findersync"

    override func setUp() {
        super.setUp()
        suiteName = "rmount.finder-extension-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = UserPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDisabledExtensionShowsOnlyOncePerLaunchAndLaterDoesNotPersist() async {
        let provider = FakeFinderExtensionStatusProvider(.notEnabled)
        let policy = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        let status = await policy.refreshStatus(bundleID: bundleID)
        XCTAssertEqual(status, .notEnabled)
        XCTAssertTrue(policy.shouldShowNotice())
        XCTAssertFalse(policy.shouldShowNotice())
        XCTAssertFalse(preferences.finderExtensionPromptDismissed)
        XCTAssertEqual(provider.requestedBundleIDs, [bundleID])
        XCTAssertFalse(provider.wasCalledOnMainThread)

        let nextLaunch = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        await nextLaunch.refreshStatus(bundleID: bundleID)
        XCTAssertTrue(nextLaunch.shouldShowNotice())
    }

    func testEnabledExtensionDoesNotConsumeNoticeAllowance() async {
        let provider = FakeFinderExtensionStatusProvider(.enabled)
        let policy = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        await policy.refreshStatus(bundleID: bundleID)
        XCTAssertFalse(policy.shouldShowNotice())
        provider.result = .notEnabled
        await policy.refreshStatus(bundleID: bundleID)
        XCTAssertTrue(policy.shouldShowNotice())
    }

    func testTurningBadgesOnCanShowNotice() async {
        preferences.showFinderBadges = false
        let policy = FinderExtensionPromptPolicy(preferences: preferences,
                                                provider: FakeFinderExtensionStatusProvider(.notEnabled))
        await policy.refreshStatus(bundleID: bundleID)
        XCTAssertFalse(policy.shouldShowNotice())
        preferences.showFinderBadges = true
        XCTAssertTrue(policy.shouldShowNotice())
        preferences.showFinderBadges = false
        preferences.showFinderBadges = true
        XCTAssertFalse(policy.shouldShowNotice())
    }

    func testDismissalPersistsAndSuppressesSubsequentLaunches() async {
        let provider = FakeFinderExtensionStatusProvider(.notEnabled)
        let policy = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        await policy.refreshStatus(bundleID: bundleID)
        XCTAssertTrue(policy.shouldShowNotice())
        policy.dismissPermanently()
        XCTAssertTrue(preferences.finderExtensionPromptDismissed)
        let nextLaunch = FinderExtensionPromptPolicy(preferences: UserPreferences(defaults: defaults),
                                                     provider: provider)
        await nextLaunch.refreshStatus(bundleID: bundleID)
        XCTAssertFalse(nextLaunch.shouldShowNotice())
    }

    func testFailedDetectionIsUnknownAndShowsAtMostOncePerLaunch() async {
        let policy = FinderExtensionPromptPolicy(preferences: preferences,
                                                provider: FakeFinderExtensionStatusProvider(.unknown))
        XCTAssertEqual(policy.status, .unknown)
        let status = await policy.refreshStatus(bundleID: bundleID)
        XCTAssertEqual(status, .unknown)
        XCTAssertTrue(policy.shouldShowNotice())
        await policy.refreshStatus(bundleID: bundleID)
        XCTAssertFalse(policy.shouldShowNotice())
    }

    func testBoolOnlyProviderUsesDefaultStatusImplementationAndLiteBundleID() async {
        let provider = BoolFinderExtensionStatusProvider(enabled: true)
        XCTAssertEqual(provider.status(bundleID: bundleID), .enabled)
        XCTAssertEqual(BoolFinderExtensionStatusProvider(enabled: false).status(bundleID: bundleID), .notEnabled)
        let policy = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        let status = await policy.refreshStatus(bundleID: "ai.rmount.lite.findersync")
        XCTAssertEqual(status, .enabled)
        XCTAssertFalse(policy.shouldShowNotice())
    }

    func testOlderRefreshCannotOverwriteNewerResult() async {
        let started = expectation(description: "first lookup started")
        let provider = OrderedFinderExtensionStatusProvider(firstStarted: started)
        defer { provider.releaseFirst.signal() }
        let policy = FinderExtensionPromptPolicy(preferences: preferences, provider: provider)
        let first = Task { await policy.refreshStatus(bundleID: bundleID) }
        await fulfillment(of: [started], timeout: 2)
        let latest = await policy.refreshStatus(bundleID: bundleID)
        XCTAssertEqual(latest, .enabled)
        provider.releaseFirst.signal()
        let older = await first.value
        XCTAssertEqual(older, .enabled)
        XCTAssertEqual(policy.status, .enabled)
        XCTAssertFalse(policy.shouldShowNotice())
    }

    func testDismissalPreferenceDefaultsToFalseAndUsesCurrentPrefix() {
        XCTAssertFalse(preferences.finderExtensionPromptDismissed)
        preferences.finderExtensionPromptDismissed = true
        XCTAssertEqual(defaults.object(forKey: "rmount.finderExtensionPromptDismissed") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "macsh.finderExtensionPromptDismissed"))
        XCTAssertTrue(UserPreferences(defaults: defaults).finderExtensionPromptDismissed)
        preferences.finderExtensionPromptDismissed = false
        XCTAssertFalse(UserPreferences(defaults: defaults).finderExtensionPromptDismissed)
    }

    func testPluginkitOutputSamples() {
        let samples: [(String, FinderExtensionStatus)] = [
            ("+    ai.rmount.findersync(0.2.0)\tUUID\tdate\t/path", .enabled),
            ("-    ai.rmount.findersync(...)", .notEnabled),
            ("     ai.rmount.findersync(...)", .notEnabled),
            ("!    ai.rmount.findersync(...)", .notEnabled),
            ("", .notEnabled),
            ("\n   \n", .notEnabled),
            ("+    ai.rmount.findersync.other(0.2.0)", .notEnabled),
            ("+    ai.rmount.lite.findersync(0.2.0)", .notEnabled),
            ("- ai.rmount.findersync(0.1.0)\n+ ai.rmount.findersync(0.2.0)\n", .enabled),
        ]
        for (output, expected) in samples {
            XCTAssertEqual(PluginkitFinderExtensionStatusProvider.parse(output, bundleID: bundleID),
                           expected, "Unexpected status for \(output.debugDescription)")
        }
        XCTAssertEqual(PluginkitFinderExtensionStatusProvider.parse("+ ai.rmount.lite.findersync(0.2.0)",
                                                                   bundleID: "ai.rmount.lite.findersync"), .enabled)
    }
}

private final class FakeFinderExtensionStatusProvider: FinderExtensionStatusProviding {
    var result: FinderExtensionStatus
    private(set) var requestedBundleIDs: [String] = []
    private(set) var wasCalledOnMainThread = false

    init(_ result: FinderExtensionStatus) { self.result = result }

    func isEnabled(bundleID: String) -> Bool { status(bundleID: bundleID) == .enabled }

    func status(bundleID: String) -> FinderExtensionStatus {
        requestedBundleIDs.append(bundleID)
        wasCalledOnMainThread = Thread.isMainThread
        return result
    }
}

private final class OrderedFinderExtensionStatusProvider: FinderExtensionStatusProviding {
    let releaseFirst = DispatchSemaphore(value: 0)
    private let firstStarted: XCTestExpectation
    private let lock = NSLock()
    private var calls = 0

    init(firstStarted: XCTestExpectation) { self.firstStarted = firstStarted }

    func isEnabled(bundleID: String) -> Bool { status(bundleID: bundleID) == .enabled }

    func status(bundleID: String) -> FinderExtensionStatus {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            firstStarted.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 5)
            return .notEnabled
        }
        return .enabled
    }
}

private struct BoolFinderExtensionStatusProvider: FinderExtensionStatusProviding {
    let enabled: Bool
    func isEnabled(bundleID: String) -> Bool { enabled }
}

final class FinderExtensionStatusProviderTests: DebugTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func provider(script: String, timeout: TimeInterval = 2) throws -> PluginkitFinderExtensionStatusProvider {
        let executable = directory.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return PluginkitFinderExtensionStatusProvider(executableURL: executable, timeout: timeout)
    }

    func testProbePassesPluginkitArgumentsAndParsesSuccessfulOutput() throws {
        let provider = try provider(script: """
        [ "$1" = '-m' ] && [ "$2" = '-i' ] && [ "$3" = 'ai.rmount.findersync' ] || exit 1
        printf '+    %s(0.2.0)\\tUUID\\tdate\\t/path\\n' "$3"
        """)
        XCTAssertTrue(provider.isEnabled(bundleID: "ai.rmount.findersync"))
    }

    func testProbeSuccessfulEmptyOutputMeansNotRegistered() throws {
        let provider = try provider(script: "exit 0")
        XCTAssertEqual(provider.status(bundleID: "ai.rmount.findersync"), .notEnabled)
        XCTAssertFalse(provider.isEnabled(bundleID: "ai.rmount.findersync"))
    }

    func testProbeFailureAndInvalidUTF8AreUnknown() throws {
        let failure = try provider(script: "printf '+ ai.rmount.findersync(0.2.0)'; exit 1")
        XCTAssertEqual(failure.status(bundleID: "ai.rmount.findersync"), .unknown)
        let invalidUTF8 = try provider(script: "printf '\\377'")
        XCTAssertEqual(invalidUTF8.status(bundleID: "ai.rmount.findersync"), .unknown)
        let missing = PluginkitFinderExtensionStatusProvider(executableURL: directory.appendingPathComponent("missing"))
        XCTAssertEqual(missing.status(bundleID: "ai.rmount.findersync"), .unknown)
    }

    func testProbeTimeoutIsBoundedEvenIfChildIgnoresTerminate() throws {
        let provider = try provider(script: "trap '' TERM\nwhile :; do :; done", timeout: 0.1)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(provider.status(bundleID: "ai.rmount.findersync"), .unknown)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testProbeDrainsOutputLargerThanPipeCapacity() throws {
        let provider = try provider(script: """
        printf '+ ai.rmount.findersync(0.2.0)\\n'
        /usr/bin/head -c 1100000 /dev/zero
        """, timeout: 5)
        XCTAssertEqual(provider.status(bundleID: "ai.rmount.findersync"), .enabled)
    }
}
