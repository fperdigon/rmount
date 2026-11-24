import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "truncate-notes.sh"


class TruncateNotesTests(unittest.TestCase):
    def run_script(self, text, *args):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / "notes.md"
            f.write_text(text, encoding="utf-8")
            r = subprocess.run(["bash", str(SCRIPT), str(f), *args], capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return f.read_bytes()

    def test_small_input_unchanged(self):
        text = "### day\n- one\n- two\n"
        self.assertEqual(self.run_script(text).decode(), text)

    def test_large_input_cut_at_line_boundary_valid_utf8(self):
        text = "".join(f"- change {i} é中\U0001F600 padding padding\n" for i in range(8000))
        self.assertGreater(len(text.encode()), 200000)
        out = self.run_script(text)
        self.assertLessEqual(len(out), 100000)
        self.assertGreater(len(out), 90000)
        decoded = out.decode("utf-8")  # raises if a character was cut
        self.assertTrue(decoded.endswith("\n"))
        self.assertTrue(text.startswith(decoded))

    def test_producer_pipeline_does_not_sigpipe(self):
        # The shape publish-nightly.sh uses: a big producer written to a file under pipefail.
        with tempfile.TemporaryDirectory() as d:
            notes = pathlib.Path(d) / "notes.md"
            cmd = (f'set -euo pipefail; {{ for i in $(seq 1 6000); do echo "- line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxx"; done; }} '
                   f'> "{notes}"; bash "{SCRIPT}" "{notes}" 100000')
            r = subprocess.run(["bash", "-c", cmd], capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertLessEqual(notes.stat().st_size, 100000)


if __name__ == "__main__":
    unittest.main()
