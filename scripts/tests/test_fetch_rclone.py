import hashlib
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "fetch-rclone.sh"


def verify(path, sha):
    return subprocess.run(["bash", str(SCRIPT), "--verify", str(path), sha],
                          capture_output=True, text=True)


class FetchRcloneChecksumTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.file = pathlib.Path(self.dir.name) / "rclone.zip"
        self.file.write_bytes(b"pretend rclone zip")
        self.sha = hashlib.sha256(b"pretend rclone zip").hexdigest()

    def test_accepts_matching_file(self):
        self.assertEqual(verify(self.file, self.sha).returncode, 0)

    def test_rejects_tampered_file(self):
        self.file.write_bytes(b"pretend rclone zip, tampered")
        result = verify(self.file, self.sha)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stderr)

    def test_rejects_wrong_hash(self):
        self.assertNotEqual(verify(self.file, "0" * 64).returncode, 0)

    def test_pins_a_version_and_hash(self):
        text = SCRIPT.read_text()
        self.assertIn('RCLONE_VERSION="v', text)
        self.assertNotIn("rclone-current", text)
        self.assertRegex(text, r'RCLONE_SHA256="[0-9a-f]{64}"')


if __name__ == "__main__":
    unittest.main()
