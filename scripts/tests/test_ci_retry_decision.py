import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "ci-retry-decision.py"
spec = importlib.util.spec_from_file_location("ci_retry_decision", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

RAN = [{"name": "Set up job", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z"}]


def job(name, conclusion, steps=()):
    return {"name": name, "conclusion": conclusion, "steps": list(steps)}


class DecisionTests(unittest.TestCase):
    def test_infra_only_retries(self):
        d, _ = mod.decide([job("build-test", "cancelled"), job("changes", "success", RAN)], 1)
        self.assertEqual(d, "retry")

    def test_steps_all_queued_is_infra(self):
        queued = [{"name": "x", "status": "queued", "conclusion": None, "started_at": None}]
        self.assertEqual(mod.decide([job("a", "cancelled", queued)], 1)[0], "retry")

    def test_real_failure_mixed_never_retries(self):
        d, reason = mod.decide([job("a", "cancelled"), job("b", "failure", RAN)], 1)
        self.assertEqual(d, "real-failure")
        self.assertIn("b", reason)

    def test_timed_out_is_real(self):
        self.assertEqual(mod.decide([job("a", "timed_out", RAN)], 1)[0], "real-failure")

    def test_all_success_or_skipped_does_nothing(self):
        self.assertEqual(mod.decide([job("a", "success", RAN), job("b", "skipped")], 1)[0], "nothing")

    def test_cancelled_with_steps_is_not_infra(self):
        cancelled = RAN + [{"name": "t", "status": "completed", "conclusion": "cancelled",
                            "started_at": "2026-01-01T00:01:00Z"}]
        self.assertEqual(mod.decide([job("a", "cancelled", cancelled)], 1)[0], "nothing")

    def test_attempt_cap(self):
        jobs = [job("a", "cancelled")]
        self.assertEqual(mod.decide(jobs, 19)[0], "retry")
        self.assertEqual(mod.decide(jobs, 20)[0], "exhausted")
        self.assertEqual(mod.decide(jobs, 3, max_attempts=3)[0], "exhausted")

    def test_real_failure_beats_exhausted(self):
        self.assertEqual(mod.decide([job("a", "cancelled"), job("b", "failure")], 99)[0], "real-failure")

    def test_paginated_stream_and_cli(self):
        page1 = json.dumps({"total_count": 2, "jobs": [job("a", "success", RAN)]})
        page2 = json.dumps({"total_count": 2, "jobs": [job("b", "cancelled")]})
        out = subprocess.run([sys.executable, str(SCRIPT), "--attempt", "2"], input=page1 + "\n" + page2,
                             capture_output=True, text=True, check=True).stdout
        self.assertTrue(out.startswith("retry: "), out)

    def test_empty_input(self):
        self.assertEqual(mod.decide(mod.load_jobs(""), 1)[0], "nothing")


if __name__ == "__main__":
    unittest.main()
