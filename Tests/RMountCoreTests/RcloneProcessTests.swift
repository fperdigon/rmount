import XCTest
@testable import RMountCore

final class RcloneProcessTests: DebugTestCase {
    private func fixture() throws -> (FakeRclone, RcloneProcess, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        addDebugTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fake = try FakeRclone.make(in: dir)
        let runner = RcloneProcess(binary: fake.binary, logFile: dir.appendingPathComponent("rclone.log"))
        return (fake, runner, dir)
    }

    func testObscureReturnsBinaryOutput() throws {
        let (fake, _, _) = try fixture()
        XCTAssertEqual(try RcloneProcess.obscure(plaintext: "secret", binary: fake.binary), "OBS-secret")
    }

    func testObscureThrowsWhenRcloneFails() throws {
        let (fake, _, dir) = try fixture()
        try "1".write(to: dir.appendingPathComponent("obscure-fail.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RcloneProcess.obscure(plaintext: "secret", binary: fake.binary)) { error in
            XCTAssertTrue(error.localizedDescription.contains("obscure exploded"), "\(error)")
        }
        XCTAssertEqual(RcloneProcess.ObscureError.failed("").errorDescription, "rclone obscure failed")
    }

    func testSpawnWebDAVServeBuildsArguments() throws {
        let (fake, runner, dir) = try fixture()
        let spawned = try runner.spawnWebDAVServe(
            remoteName: "r", remotePath: "/data", configText: "[r]\ntype = sftp\n",
            baseurl: "/vol", liveUpdates: true, envOverrides: ["RMOUNT_TEST_ENV": "hello"]
        )
        TestDebug.spawned(spawned)
        defer { spawned.process.stopAndReap() }

        let lines = fake.recordedLines()
        XCTAssertEqual(Array(lines.prefix(3)), ["serve", "webdav", "r:/data"])
        XCTAssertTrue(lines.contains("--addr"))
        XCTAssertTrue(lines.contains("127.0.0.1:\(spawned.port)"))
        XCTAssertTrue(lines.contains("--baseurl"))
        XCTAssertTrue(lines.contains("/vol"))
        XCTAssertTrue(lines.contains("--dir-cache-time"))
        XCTAssertTrue(lines.contains("--vfs-fast-fingerprint"))
        XCTAssertFalse(lines.contains("--user"))
        XCTAssertFalse(lines.contains("--pass"))
        XCTAssertFalse(lines.contains(spawned.user), "serve credentials must not be in argv")
        XCTAssertFalse(lines.contains(spawned.password), "serve credentials must not be in argv")
        XCTAssertTrue(lines.contains("ENV:RCLONE_USER=\(spawned.user)"))
        XCTAssertTrue(lines.contains("ENV:RCLONE_PASS=\(spawned.password)"))
        XCTAssertTrue(lines.contains("ENV:RMOUNT_TEST_ENV=hello"))
        XCTAssertGreaterThan(spawned.port, 0)
        XCTAssertGreaterThan(spawned.rcPort, 0)
        XCTAssertNotEqual(spawned.port, spawned.rcPort)
        XCTAssertTrue(lines.contains("--rc"))
        XCTAssertTrue(lines.contains("127.0.0.1:\(spawned.rcPort)"))
        XCTAssertEqual(spawned.process.environment?["RCLONE_RC_USER"], spawned.rcUser)
        XCTAssertEqual(spawned.process.environment?["RCLONE_RC_PASS"], spawned.rcPassword)
        XCTAssertFalse(spawned.process.arguments!.contains(spawned.rcUser))
        XCTAssertFalse(spawned.process.arguments!.contains(spawned.rcPassword))
        XCTAssertTrue(spawned.user.hasPrefix("rmount-"))

        // The config text is written to the file passed via --config.
        let cfgIdx = try XCTUnwrap(lines.firstIndex(of: "--config"))
        let cfg = try String(contentsOfFile: lines[cfgIdx + 1], encoding: .utf8)
        XCTAssertEqual(cfg, "[r]\ntype = sftp\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rclone.log").path))
    }

    func testWebDAVWithoutLiveUpdatesOmitsCacheFlags() throws {
        let (fake, runner, _) = try fixture()
        let spawned = try runner.spawnWebDAVServe(
            remoteName: "r", remotePath: "/", configText: "[r]\n", baseurl: "/v", liveUpdates: false
        )
        TestDebug.spawned(spawned)
        defer { spawned.process.stopAndReap() }
        let lines = fake.recordedLines()
        XCTAssertFalse(lines.contains("--dir-cache-time"))
        XCTAssertFalse(lines.contains("--vfs-fast-fingerprint"))
        XCTAssertTrue(lines.contains("--vfs-cache-mode"))
    }

    func testSpawnNFSServeHasNoAuth() throws {
        let (fake, runner, _) = try fixture()
        let spawned = try runner.spawnNFSServe(
            remoteName: "r", remotePath: "bucket/prefix", configText: "[r]\n", liveUpdates: true
        )
        TestDebug.spawned(spawned)
        defer { spawned.process.stopAndReap() }
        let lines = fake.recordedLines()
        XCTAssertEqual(Array(lines.prefix(3)), ["serve", "nfs", "r:bucket/prefix"])
        XCTAssertFalse(lines.contains("--user"))
        XCTAssertFalse(lines.contains("--baseurl"))
        XCTAssertTrue(lines.contains("--dir-cache-time"))
        XCTAssertEqual(spawned.user, "")
        XCTAssertEqual(spawned.password, "")
    }

    func testSpawnDistinctPorts() throws {
        let (_, runner, _) = try fixture()
        let a = try runner.spawnNFSServe(remoteName: "r", remotePath: "/", configText: "[r]\n", liveUpdates: false)
        TestDebug.spawned(a)
        defer { a.process.stopAndReap() }
        XCTAssertGreaterThan(a.port, 1023)
        let b = try runner.spawnNFSServe(remoteName: "r", remotePath: "/", configText: "[r]\n", liveUpdates: false)
        TestDebug.spawned(b)
        defer { b.process.stopAndReap() }
        XCTAssertNotEqual(a.rcPort, a.port)
        XCTAssertNotEqual(b.rcPort, b.port)
        XCTAssertNotEqual(a.rcUser, b.rcUser)
        XCTAssertNotEqual(a.rcPassword, b.rcPassword)
    }

    func testLaunchFailureThrows() throws {
        let dir = try makeTempDir()
        addDebugTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runner = RcloneProcess(
            binary: URL(fileURLWithPath: "/nonexistent/rclone"),
            logFile: dir.appendingPathComponent("rclone.log")
        )
        XCTAssertThrowsError(
            try runner.spawnNFSServe(remoteName: "r", remotePath: "/", configText: "[r]\n", liveUpdates: false)
        ) { error in
            guard case RcloneProcess.SpawnError.launchFailed = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }
}
