#!/usr/bin/env python3
"""Behavior tests for the coverage known-flake retry gate."""

import importlib.util
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ci_flake_retry", ROOT / "scripts/ci-flake-retry.py")
retry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retry)


LOG = """  1) test flaky one (Aiur.RetryFixtureTest)
     test/aiur/retry_fixture_test.exs:10
     assertion failed
  2) test flaky two (Aiur.RetryFixtureTest)
     test/aiur/retry_fixture_test.exs:20
     assertion failed
2 tests, 2 failures
"""


class RetryGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.known = self.root / "known.txt"
        self.quarantine = self.root / "quarantine.txt"
        self.known.write_text("Aiur.RetryFixtureTest :: flaky one\nAiur.RetryFixtureTest :: flaky two\n")
        self.quarantine.write_text("")

    def tearDown(self):
        self.temp.cleanup()

    def plan(self, log=LOG, changed=(), base=()):
        return retry.retry_plan(log, set(changed), self.known, self.quarantine,
                                set(base), True)

    def test_two_known_failures_are_retried(self):
        plan = self.plan()
        self.assertEqual([item["test"] for item in plan], [
            "Aiur.RetryFixtureTest :: flaky one", "Aiur.RetryFixtureTest :: flaky two",
        ])
        self.assertEqual([item["path"] for item in plan], [
            "test/aiur/retry_fixture_test.exs", "test/aiur/retry_fixture_test.exs",
        ])

    def test_mixed_known_and_new_failures_are_not_retried(self):
        log = LOG + "  3) test new regression (Aiur.NewFixtureTest)\n     test/aiur/new_fixture_test.exs:30\n3 tests, 3 failures\n"
        self.assertEqual(self.plan(log=log), [])

    def test_partial_failure_parse_is_not_retryable(self):
        log = """  1) test flaky one (Aiur.RetryFixtureTest)
     test/aiur/retry_fixture_test.exs:10
  2) test failure without a test source location (Aiur.SetupFixtureTest)
     test/support/setup_fixture.ex:4
2 tests, 2 failures
"""
        self.assertEqual(self.plan(log=log), [])

    def test_github_job_log_prefixes_do_not_hide_failure_names_or_locations(self):
        prefixed = """coverage (2/4)\tTest coverage partition\t2026-10-22T01:00:00Z  1) test flaky one (Aiur.RetryFixtureTest)
coverage (2/4)\tTest coverage partition\t2026-10-22T01:00:00Z      test/aiur/retry_fixture_test.exs:10
coverage (2/4)\tTest coverage partition\t2026-10-22T01:00:01Z  1 test, 1 failure
"""
        plan = self.plan(log=prefixed)
        self.assertEqual(len(plan), 1)
        self.assertEqual(plan[0]["path"], "test/aiur/retry_fixture_test.exs")

    def test_failing_test_file_touched_by_pr_disables_retry(self):
        self.assertEqual(self.plan(changed=("src/test/aiur/retry_fixture_test.exs",)), [])

    def test_quarantined_and_recent_base_failures_are_eligible(self):
        self.quarantine.write_text("Aiur.RetryFixtureTest\tflaky one\t#1\n")
        self.known.write_text("")
        one_failure = LOG.split("  2) test")[0] + "1 test, 1 failure\n"
        plan = self.plan(log=one_failure, base=())
        self.assertEqual(len(plan), 1)
        self.quarantine.write_text("")
        plan = self.plan(log=one_failure, base=("Aiur.RetryFixtureTest :: flaky one",))
        self.assertEqual(len(plan), 1)

    def test_recent_base_failure_lookup_uses_only_failed_runs_in_last_day(self):
        now = datetime(2026, 10, 22, 12, tzinfo=timezone.utc)
        runs = [
            {"databaseId": 1, "createdAt": (now - timedelta(hours=23)).isoformat(), "conclusion": "failure"},
            {"databaseId": 2, "createdAt": (now - timedelta(hours=25)).isoformat(), "conclusion": "failure"},
            {"databaseId": 3, "createdAt": (now - timedelta(hours=1)).isoformat(), "conclusion": "success"},
        ]

        viewed = []

        def gh_call(command, **_kwargs):
            if command[1:3] == ["run", "list"]:
                import json
                return json.dumps(runs)
            if command[1:4] == ["run", "view", "1"]:
                viewed.append(command[3])
                return LOG
            raise AssertionError(f"unexpected GitHub CLI call: {command}")

        with patch.object(retry.subprocess, "check_output", side_effect=gh_call):
            observed = retry.recent_base_failures("aiur-team/aiur", "main", now)

        self.assertEqual(observed, {
            "Aiur.RetryFixtureTest :: flaky one", "Aiur.RetryFixtureTest :: flaky two",
        })
        self.assertEqual(viewed, ["1"])

    def test_github_history_failure_disables_base_evidence(self):
        with patch.object(retry.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "gh")):
            observed = retry.recent_base_failures("aiur-team/aiur", "main")
        self.assertEqual(observed, set())

    def test_merge_group_and_unparseable_failure_never_retry(self):
        found = retry.failures("Compilation failed before ExUnit started")
        self.assertEqual(found, [])
        self.assertEqual(retry.retry_plan(LOG, set(), self.known, self.quarantine, set(), False), [])

    def test_workflow_retries_only_the_selected_failures_and_records_result(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        partition = workflow.split("  coverage-partition:\n", 1)[1].split("\n  test:\n", 1)[0]
        prepare = (ROOT / "scripts/prepare-coverage-retry.sh").read_text()
        retry_script = (ROOT / "scripts/retry-coverage-tests.sh").read_text()
        partition_script = (ROOT / "scripts/run-coverage-partition.sh").read_text()
        self.assertIn("github.event_name == 'pull_request'", partition)
        self.assertIn('GH_TOKEN: "${{ github.token }}"', partition)
        self.assertIn("id: retry-known-flakes", partition)
        self.assertIn("bash ../scripts/prepare-coverage-retry.sh", partition)
        self.assertIn("bash ../scripts/run-coverage-partition.sh", partition)
        self.assertIn("bash ../scripts/retry-coverage-tests.sh", partition)
        self.assertIn('mix test "${args[@]}"', retry_script)
        self.assertIn('retry.log', retry_script)
        self.assertIn('plan.update({"outcome": outcome', retry_script)
        self.assertIn("steps.retry-known-flakes.outcome != 'success'", partition)
        self.assertIn("Retried known flakes: all selected tests passed", retry_script)
        self.assertIn('git -C "$workspace" diff --name-only "$BASE_SHA...HEAD"', prepare)
        self.assertIn("timeout --signal=TERM --kill-after=60s 20m", partition_script)
        self.assertIn("make coverage-partition", partition_script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
