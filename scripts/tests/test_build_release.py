import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "build-release.sh"
PLISTBUDDY = pathlib.Path("/usr/libexec/PlistBuddy")


def build_target_source():
    text = SCRIPT.read_text()
    return re.search(r"^build_target\(\) \{.*?^\}\n", text, re.S | re.M).group(0)


@unittest.skipUnless(PLISTBUDDY.exists(), "needs macOS PlistBuddy")
class BuildTargetTests(unittest.TestCase):
    """Runs build_target from build-release.sh with a fake xcodebuild first on PATH."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="build-release-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / "bin").mkdir()
        self.products = self.tmp / "products"
        self.app = self.products / "rmount-lite.app"

    def run_build(self, fake_body):
        fake = self.tmp / "bin" / "xcodebuild"
        fake.write_text("#!/bin/bash\n" + fake_body)
        fake.chmod(0o755)
        script = ("set -euo pipefail\nVERSION=1.2.3 BUILD_SHA=x BUILD_KIND=dev BUILD_DIR=d\n"
                  f'PRODUCTS="{self.products}"\n' + build_target_source() + "\nbuild_target rmount-lite\necho OK\n")
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                              env={"PATH": f"{self.tmp / 'bin'}:/usr/bin:/bin"})

    def make_app(self, version):
        (self.app / "Contents").mkdir(parents=True)
        subprocess.run([str(PLISTBUDDY), "-c", f"Add :CFBundleShortVersionString string {version}",
                        str(self.app / "Contents" / "Info.plist")], check=True, capture_output=True)

    def fake_ok(self, version):
        return (f'mkdir -p "{self.app}/Contents"\n'
                f'/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string {version}" '
                f'"{self.app}/Contents/Info.plist" >/dev/null\necho "** BUILD SUCCEEDED **"\n')

    def test_success(self):
        r = self.run_build(self.fake_ok("1.2.3"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("OK", r.stdout)

    def test_failed_xcodebuild_fails_even_with_stale_app(self):
        self.make_app("1.2.3")
        r = self.run_build('echo "noise"; exit 65\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("OK", r.stdout)
        self.assertIn("xcodebuild failed", r.stderr)
        self.assertFalse(self.app.exists())

    def test_wrong_version_is_rejected(self):
        r = self.run_build(self.fake_ok("0.0.9"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected 1.2.3", r.stderr)


if __name__ == "__main__":
    unittest.main()
