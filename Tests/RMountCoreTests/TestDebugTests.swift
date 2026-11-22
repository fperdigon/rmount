import XCTest

final class TestDebugTests: DebugTestCase {
    func testSecretOperandsAreRedactedEvenWhenTheyLookLikeOptions() {
        XCTAssertEqual(TestDebug.safeArguments(["serve", "webdav", "r:/data", "--user", "alice",
                                                "--pass", "--rc", "--rc"]),
                       ["serve", "webdav", "<redacted>", "--user", "<redacted>",
                        "--pass", "<redacted>", "--rc"])
        for command in ["obscure", "reveal"] {
            XCTAssertEqual(TestDebug.safeArguments([command, "serve"]), [command, "<redacted>"])
        }
    }

    func testShellBodiesInlineSecretsAndUnknownOptionsAreRedacted() {
        XCTAssertEqual(TestDebug.safeArguments(["-c", "echo token", "--pass=secret", "--token", "secret"]),
                       ["-c", "<redacted>", "<redacted>", "<redacted>", "<redacted>"])
    }
}
