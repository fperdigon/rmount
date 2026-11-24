import Foundation
import XCTest
@testable import RMountCore

final class ProcessRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testLargeStdoutAndStderrDoNotDeadlock() throws {
        // Both pipes exceed the 64 KB pipe buffer; reading after exit would hang forever.
        let r = try ProcessRunner.run(
            executable: sh,
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2"],
            timeout: 30)
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.stdout.count, 300_000)
        XCTAssertEqual(r.stderr.count, 200_000)
    }

    func testExitStatusAndOutput() throws {
        let r = try ProcessRunner.run(executable: sh, arguments: ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stdoutString, "out\n")
        XCTAssertEqual(r.stderrString, "err\n")
    }

    func testMergeStderrAndEnvironment() throws {
        let r = try ProcessRunner.run(
            executable: sh, arguments: ["-c", "echo $FOO; echo err >&2"],
            environment: ["FOO": "bar"], mergeStderr: true)
        XCTAssertEqual(r.stdoutString, "bar\nerr\n")
        XCTAssertTrue(r.stderr.isEmpty)
    }

    func testTimeoutTerminates() throws {
        let start = Date()
        let r = try ProcessRunner.run(executable: sh, arguments: ["-c", "sleep 30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutFallsBackToSigkill() throws {
        // Ignores SIGTERM, so only SIGKILL stops it.
        let start = Date()
        let r = try ProcessRunner.run(
            executable: sh, arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
            timeout: 0.5, killGrace: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testLaunchFailureThrows() {
        XCTAssertThrowsError(try ProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/bin")))
    }

    func testOnStartReceivesProcess() throws {
        var pid: Int32 = 0
        _ = try ProcessRunner.run(executable: sh, arguments: ["-c", "true"], onStart: { pid = $0.processIdentifier })
        XCTAssertGreaterThan(pid, 0)
    }
}
