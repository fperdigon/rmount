import pathlib
import hashlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "update-cask.sh"

CASK = '''cask "{token}" do
  version "0.1.5"
  sha256 "{sha}"

  url "https://example.invalid/{token}-#{{version}}.dmg"
end
'''


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                        "HOME": str(cwd)})


class UpdateCaskTests(unittest.TestCase):
    """Runs scripts/update-cask.sh against a throwaway bare repository standing in for the tap."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="update-cask-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        seed = self.tmp / "seed"
        (seed / "Casks").mkdir(parents=True)
        for token in ("rmount", "rmount-lite"):
            (seed / "Casks" / f"{token}.rb").write_text(CASK.format(token=token, sha="0" * 64))
        git("init", "-q", "-b", "main", cwd=seed)
        git("add", "-A", cwd=seed)
        git("commit", "-q", "-m", "seed", cwd=seed)
        self.bare = self.tmp / "tap.git"
        git("clone", "-q", "--bare", str(seed), str(self.bare), cwd=self.tmp)
        self.dist = self.tmp / "dist"
        self.dist.mkdir()

    def make_dmgs(self, version):
        sums = {}
        for name in ("rmount", "rmount-lite"):
            data = f"{name}-{version}".encode()
            (self.dist / f"{name}-{version}.dmg").write_bytes(data)
            sums[name] = hashlib.sha256(data).hexdigest()
        return sums

    def run_script(self, version):
        import os
        env = dict(os.environ, TAP_URL=f"file://{self.bare}", DIST=str(self.dist))
        env.pop("HOMEBREW_TAP_TOKEN", None)
        return subprocess.run([str(SCRIPT), version], capture_output=True, text=True, env=env)

    def cask_in_tap(self, token):
        return subprocess.run(["git", "--git-dir", str(self.bare), "show", f"HEAD:Casks/{token}.rb"],
                              capture_output=True, text=True, check=True).stdout

    def test_updates_version_and_checksums(self):
        sums = self.make_dmgs("0.2.0")
        result = self.run_script("v0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        for token in ("rmount", "rmount-lite"):
            text = self.cask_in_tap(token)
            self.assertIn('  version "0.2.0"', text)
            self.assertIn(f'  sha256 "{sums[token]}"', text)
            self.assertIn("#{version}", text, "the url line is left alone")

    def test_second_run_changes_nothing(self):
        self.make_dmgs("0.2.0")
        self.assertEqual(self.run_script("0.2.0").returncode, 0)
        result = self.run_script("0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)

    def test_missing_dmg_fails_before_pushing(self):
        result = self.run_script("9.9.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found", result.stderr)
        self.assertIn('  version "0.1.5"', self.cask_in_tap("rmount"))

    def test_requires_a_token_or_url(self):
        import os
        env = {k: v for k, v in os.environ.items() if k not in ("TAP_URL", "HOMEBREW_TAP_TOKEN")}
        result = subprocess.run([str(SCRIPT), "0.2.0"], capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HOMEBREW_TAP_TOKEN", result.stderr)


if __name__ == "__main__":
    unittest.main()
