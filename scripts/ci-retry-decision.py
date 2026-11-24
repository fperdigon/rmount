#!/usr/bin/env python3
"""Decide whether a finished CI run should be retried because GitHub never gave its jobs a runner.

Reads the output of `gh api repos/<repo>/actions/runs/<id>/jobs --paginate` on stdin (one or more JSON
objects, each with a "jobs" list) and prints one line: `<decision>: <reason>`, where decision is

  retry         only infrastructure losses (cancelled, zero steps ever ran); rerun the failed jobs
  exhausted     same, but the attempt cap is reached; stop retrying and tell the PR
  real-failure  a job failed for real; never retry
  nothing       nothing to retry

A job is an infrastructure loss only when it was cancelled AND no step ever started. Any failed job, or a
cancelled job that already ran steps (a user or a newer commit cancelled it), is not retried.
Usage: ci-retry-decision.py --attempt N [--max-attempts 20] < jobs.json
"""
import argparse
import json
import sys

MAX_ATTEMPTS = 20  # GitHub allows at most 50 reruns of one run; stay well below it


def load_jobs(text):
    """Accept concatenated JSON documents (what `gh api --paginate` prints) as well as a bare list."""
    decoder = json.JSONDecoder()
    jobs, pos = [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return jobs
        doc, pos = decoder.raw_decode(text, pos)
        jobs.extend(doc if isinstance(doc, list) else doc.get("jobs", []))


def started_steps(job):
    return [s for s in job.get("steps") or []
            if s.get("started_at") or s.get("conclusion") not in (None, "skipped")]


def decide(jobs, attempt, max_attempts=MAX_ATTEMPTS):
    infra, real = [], []
    for job in jobs:
        conclusion = job.get("conclusion")
        if conclusion in (None, "success", "skipped", "neutral"):
            continue
        if conclusion == "cancelled" and not started_steps(job):
            infra.append(job.get("name", "?"))
        elif conclusion == "cancelled":
            continue  # cancelled after it ran: user or newer commit, not an outage
        else:  # failure, timed_out, action_required, ...
            real.append(job.get("name", "?"))
    if real:
        return "real-failure", "real failure in: " + ", ".join(real)
    if not infra:
        return "nothing", "no job lost its runner"
    if attempt >= max_attempts:
        return "exhausted", f"attempt {attempt} reached the cap of {max_attempts}; no runner for: " + ", ".join(infra)
    return "retry", "no runner was acquired for: " + ", ".join(infra)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--attempt", type=int, required=True)
    p.add_argument("--max-attempts", type=int, default=MAX_ATTEMPTS)
    args = p.parse_args(argv)
    decision, reason = decide(load_jobs(sys.stdin.read()), args.attempt, args.max_attempts)
    print(f"{decision}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
