import XCTest
import CryptoKit
@testable import RMountCore

final class UpdateInstallerTests: DebugTestCase {
    // MARK: helpers

    /// A minimal fake bundle: <dir>/<name>/Contents/{Info.plist,MacOS/<exe>} where the exe holds `marker`.
    /// The bundle is ad-hoc signed (like the release builds) unless `sign` is false.
    @discardableResult
    private func makeApp(named name: String, in dir: URL, marker: String,
                         id: String = "ai.rmount", version: String = "1.0.0", sign: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent(name)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try marker.write(to: macos.appendingPathComponent("exe"), atomically: true, encoding: .utf8)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                    "CFBundleVersion": version, "CFBundleExecutable": "exe",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--deep", "-s", "-", app.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw XCTSkip("codesign unavailable here") }
        }
        return app
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/MacOS/exe"), encoding: .utf8)
    }

    /// Wraps `app` in a real DMG with hdiutil, like scripts/build-release.sh does.
    private func makeDMG(containing app: URL, in dir: URL, name: String = "update.dmg") throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: stage.appendingPathComponent(app.lastPathComponent))
        let dmg = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-volname", "rmount", "-srcfolder", stage.path, "-fs", "HFS+", "-size", "20m", "-format", "UDZO", "-ov", dmg.path]
        p.standardOutput = Pipe()
        let err = Pipe()
        p.standardError = err
        try p.debugRun()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.debugWaitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("hdiutil unavailable here: \(msg)") }
        return dmg
    }

    private func digest(of file: URL) throws -> String { "sha256:" + (try UpdateInstaller.sha256(of: file)) }

    private func tempDir() throws -> URL {
        let dir = try makeTempDir()
        addDebugTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: checksum

    func testSHA256AndVerify() throws {
        let dir = try tempDir()
        let f = dir.appendingPathComponent("f.bin")
        try Data("abc".utf8).write(to: f)
        let known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try UpdateInstaller.sha256(of: f), known)

        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: "sha256:\(known)"))
        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: known.uppercased()))
        for bad in [nil, "", "md5:123"] as [String?] {
            XCTAssertThrowsError(try UpdateInstaller.verify(file: f, expected: bad), "\(bad ?? "nil")") {
                XCTAssertEqual($0 as? UpdateInstaller.InstallError, .digestMissing)
            }
        }
        XCTAssertThrowsError(try UpdateInstaller.verify(file: f, expected: "sha256:deadbeef")) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
    }

    func testSHA256OfLargeFileStreams() throws {
        let dir = try tempDir()
        let f = dir.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 3 * (1 << 20) + 5).write(to: f)
        XCTAssertEqual(try UpdateInstaller.sha256(of: f).count, 64)
    }

    // MARK: replace / install

    func testReplaceAppSwapsContents() throws {
        let dir = try tempDir()
        let current = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        let staging = dir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let new = try makeApp(named: "rmount.app", in: staging, marker: "NEW")
        try UpdateInstaller.replaceApp(at: current, with: new)
        XCTAssertEqual(try marker(of: current), "NEW")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "the staged copy is consumed")
    }

    func testReplaceAppReportsFailure() throws {
        let dir = try tempDir()
        let missingNew = dir.appendingPathComponent("nope.app")
        let current = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        XCTAssertThrowsError(try UpdateInstaller.replaceApp(at: current, with: missingNew)) {
            guard case UpdateInstaller.InstallError.replaceFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try marker(of: current), "OLD", "a failed update leaves the installed app alone")
    }

    func testCanReplaceChecksParentFolder() throws {
        let dir = try tempDir()
        XCTAssertTrue(UpdateInstaller.canReplace(dir.appendingPathComponent("rmount.app")))
        XCTAssertFalse(UpdateInstaller.canReplace(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    func testInstallFromRealDMG() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD-VERSION")
        let src = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)
        let digest = "sha256:" + (try UpdateInstaller.sha256(of: dmg))

        try UpdateInstaller.install(dmg: dmg, expectedDigest: digest, over: installed)

        XCTAssertEqual(try marker(of: installed), "NEW-VERSION")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".rmount-update-") }
        XCTAssertTrue(leftovers.isEmpty, "staging folder removed: \(leftovers)")
    }

    func testInstallOverOldNamedAppMovesToTheNewName() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION", id: "ai.macsh")
        let src = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)

        let result = try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg), over: installed)

        XCTAssertEqual(result.lastPathComponent, "rmount.app")
        XCTAssertEqual(try marker(of: result), "NEW-VERSION")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path), "the old bundle is moved away")
    }

    func testInstallOverOldNamedAppReplacesAnExistingNewNamedApp() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION", id: "ai.macsh")
        try makeApp(named: "rmount.app", in: dir, marker: "STALE")
        let src = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)

        let result = try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg), over: installed)

        XCTAssertEqual(try marker(of: result), "NEW-VERSION")
    }

    // MARK: staged-app and release-signature rejections

    private func assertRejected(_ expected: (UpdateInstaller.InstallError) -> Bool, installedApp: URL,
                                dmg: URL, digest: String?, channel: UpdateChannel = .stable,
                                key: Data? = nil, sig: Data? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: digest, over: installedApp,
                                                         channel: channel, releaseKey: key, releaseSignature: sig),
                             file: file, line: line) {
            guard let e = $0 as? UpdateInstaller.InstallError, expected(e) else { return XCTFail("\($0)", file: file, line: line) }
            XCTAssertFalse(e.localizedDescription.isEmpty, file: file, line: line)
        }
        XCTAssertEqual(try marker(of: installedApp), "OLD", "the installed app is untouched", file: file, line: line)
    }

    func testInstallRejectsMissingDigest() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        let dmg = try makeDMG(containing: try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW"), in: dir)
        try assertRejected({ $0 == .digestMissing }, installedApp: installed, dmg: dmg, digest: nil)
        try assertRejected({ $0 == .digestMissing }, installedApp: installed, dmg: dmg, digest: "md5:1")
    }

    func testInstallRejectsAnotherBundleIdentifier() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        let evil = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW", id: "com.evil.app")
        let dmg = try makeDMG(containing: evil, in: dir)
        try assertRejected({ $0 == .bundleIdentifierMismatch(expected: "ai.rmount", found: "com.evil.app") },
                           installedApp: installed, dmg: dmg, digest: try digest(of: dmg))
    }

    func testInstallRejectsABrokenCodeSignature() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        let unsigned = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW", sign: false)
        let dmg = try makeDMG(containing: unsigned, in: dir)
        try assertRejected({ if case .codeSignatureInvalid = $0 { return true } else { return false } },
                           installedApp: installed, dmg: dmg, digest: try digest(of: dmg))

        // Signed, then tampered with after signing.
        let tampered = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW")
        try "HACKED".write(to: tampered.appendingPathComponent("Contents/MacOS/exe"), atomically: true, encoding: .utf8)
        let dmg2 = try makeDMG(containing: tampered, in: dir, name: "tampered.dmg")
        try assertRejected({ if case .codeSignatureInvalid = $0 { return true } else { return false } },
                           installedApp: installed, dmg: dmg2, digest: try digest(of: dmg2))
    }

    func testStableChannelRejectsADowngradeButNightlyAllowsIt() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD", version: "0.2.0")
        let older = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW", version: "0.1.9")
        let dmg = try makeDMG(containing: older, in: dir)
        try assertRejected({ $0 == .downgrade(current: "0.2.0", new: "0.1.9") },
                           installedApp: installed, dmg: dmg, digest: try digest(of: dmg))
        XCTAssertNoThrow(try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg),
                                                     over: installed, channel: .nightly))
        XCTAssertEqual(try marker(of: installed), "NEW")
    }

    func testStableChannelAcceptsANewerVersion() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD", version: "0.2.0")
        let newer = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW", version: "0.3.0")
        let dmg = try makeDMG(containing: newer, in: dir)
        XCTAssertNoThrow(try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg), over: installed))
        XCTAssertEqual(try marker(of: installed), "NEW")
    }

    func testReleaseSignatureAcceptedMissingAndInvalid() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD")
        let dmg = try makeDMG(containing: try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW"), in: dir)
        let digest = try self.digest(of: dmg)
        let priv = Curve25519.Signing.PrivateKey()   // throwaway key, test only
        let key = priv.publicKey.rawRepresentation
        let sig = try priv.signature(for: Data(contentsOf: dmg))

        try assertRejected({ $0 == .releaseSignatureMissing }, installedApp: installed, dmg: dmg, digest: digest, key: key, sig: nil)
        try assertRejected({ $0 == .releaseSignatureInvalid }, installedApp: installed, dmg: dmg, digest: digest,
                           key: key, sig: Data(repeating: 1, count: 64))
        let other = Curve25519.Signing.PrivateKey()
        try assertRejected({ $0 == .releaseSignatureInvalid }, installedApp: installed, dmg: dmg, digest: digest,
                           key: other.publicKey.rawRepresentation, sig: sig)
        try assertRejected({ $0 == .releaseSignatureInvalid }, installedApp: installed, dmg: dmg, digest: digest,
                           key: Data([1, 2, 3]), sig: sig)

        // Base64 text form, as a .sig asset would hold it.
        XCTAssertNoThrow(try UpdateInstaller.install(dmg: dmg, expectedDigest: digest, over: installed, releaseKey: key,
                                                     releaseSignature: Data(sig.base64EncodedString().utf8)))
        XCTAssertEqual(try marker(of: installed), "NEW")
    }

    func testReleaseKeyConfigurationAndAssetName() {
        XCTAssertNil(UpdateSignature.configuredPublicKey(nil))
        XCTAssertNil(UpdateSignature.configuredPublicKey(["RMountUpdatePublicKey": "  "]))
        XCTAssertNil(UpdateSignature.configuredPublicKey(["RMountUpdatePublicKey": "$(RMOUNT_KEY)!"]))
        XCTAssertEqual(UpdateSignature.configuredPublicKey(["RMountUpdatePublicKey": "AQID"]), Data([1, 2, 3]))
        XCTAssertEqual(UpdateSignature.signatureAssetName(for: "rmount-0.2.1.dmg"), "rmount-0.2.1.dmg.sig")
    }

    func testAppNameInMountedDMG() throws {
        let dir = try tempDir()
        try makeApp(named: "rmount.app", in: dir, marker: "x")
        try makeApp(named: "rmount-lite.app", in: dir, marker: "y")
        XCTAssertEqual(UpdateInstaller.appName(inMountedDMG: dir, matching: "rmount.app"), "rmount.app")
        XCTAssertEqual(UpdateInstaller.appName(inMountedDMG: dir, matching: "macsh.app"), "rmount.app")
        XCTAssertEqual(UpdateInstaller.appName(inMountedDMG: dir, matching: "macsh-lite.app"), "rmount-lite.app")
        XCTAssertEqual(UpdateInstaller.appName(inMountedDMG: dir, matching: "Other.app"), "Other.app",
                       "an unrelated app name is never swapped for another app")
    }

    func testInstallRejectsBadChecksumBeforeTouchingTheApp() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD-VERSION")
        let src = try makeApp(named: "rmount.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: "sha256:00", over: installed)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
        XCTAssertEqual(try marker(of: installed), "OLD-VERSION")
    }

    func testInstallWhenDMGLacksTheApp() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD-VERSION")
        let other = try makeApp(named: "other.app", in: try tempDir(), marker: "X")
        let dmg = try makeDMG(containing: other, in: dir)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg), over: installed)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .appNotFound("rmount.app"))
        }
        XCTAssertEqual(try marker(of: installed), "OLD-VERSION")
    }

    func testInstallWithUnreadableDMG() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "rmount.app", in: dir, marker: "OLD-VERSION")
        let junk = dir.appendingPathComponent("junk.dmg")
        try Data("not a disk image".utf8).write(to: junk)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: junk, expectedDigest: try digest(of: junk), over: installed)) {
            guard case UpdateInstaller.InstallError.mountFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testInstallIntoReadOnlyFolderExplainsWhy() throws {
        let dir = try tempDir()
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let installed = try makeApp(named: "rmount.app", in: locked, marker: "OLD")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let dmg = dir.appendingPathComponent("x.dmg")
        try Data("x".utf8).write(to: dmg)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: try digest(of: dmg), over: installed)) {
            guard case UpdateInstaller.InstallError.notWritable(let folder) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(folder, locked.path)
        }
    }

    func testClearQuarantineRemovesTheFlag() throws {
        let dir = try tempDir()
        let app = try makeApp(named: "rmount.app", in: dir, marker: "X")
        let value = "0083;00000000;Safari;"
        let rc = value.withCString { setxattr(app.path, "com.apple.quarantine", $0, Int(strlen($0)), 0, 0) }
        XCTAssertEqual(rc, 0)
        UpdateInstaller.clearQuarantine(app)
        XCTAssertEqual(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "attribute is gone")
    }

    func testRelaunchCommandQuotesThePath() {
        let p = UpdateInstaller.relaunchProcess(appURL: URL(fileURLWithPath: "/Applications/it's here/rmount.app"))
        XCTAssertEqual(p.executableURL?.path, "/bin/sh")
        XCTAssertEqual(p.arguments, ["-c", "sleep 1; /usr/bin/open -n '/Applications/it'\\''s here/rmount.app'"])
    }

    func testErrorsAreReadable() {
        let all: [UpdateInstaller.InstallError] = [.downloadFailed(404), .checksumMismatch, .notWritable("/Applications"),
                                                   .mountFailed("x"), .appNotFound("rmount.app"), .replaceFailed("y")]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
        XCTAssertTrue(UpdateInstaller.InstallError.notWritable("/Applications").errorDescription!.contains("/Applications"))
    }
}
