#!/usr/bin/env python3
"""Behavior tests for the coverage known-flake retry gate."""

import importlib.util
import json
import os
import re
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

    def test_invalid_exunit_tests_are_not_retryable(self):
        log = LOG.split("  2) test")[0] + "2 tests, 1 failure, 1 invalid\n"
        self.assertEqual(self.plan(log=log), [])

    def test_setup_all_crash_is_not_retryable(self):
        log = LOG.replace("2 tests, 2 failures", "2 tests, 2 failures")
        log += "** (ExUnit.CallbackError) setup_all callback failed\n"
        self.assertEqual(self.plan(log=log), [])

    def test_only_plain_exunit_failure_exit_status_is_retryable(self):
        for status in (0, 1, 124, 137):
            with self.subTest(status=status):
                self.assertEqual(
                    retry.retry_plan(LOG, set(), self.known, self.quarantine,
                                     set(), True, partition_status=status),
                    [],
                )

    def test_known_list_coverage_skips_base_history_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "failed.log"
            changed = root / "changed.txt"
            evidence = root / "evidence/retry-plan.json"
            summary = root / "summary.md"
            log.write_text(LOG)
            changed.write_text("README.md\n")
            summary.write_text("")
            with patch.object(retry, "recent_base_failures", side_effect=AssertionError("unexpected lookup")):
                with patch("sys.argv", [
                    "ci-flake-retry.py", str(log), str(changed), str(self.known),
                    str(self.quarantine), str(evidence), str(summary),
                    "--repo", "aiur-team/aiur", "--base-branch", "main",
                    "--pull-request", "--partition", "2", "--partition-status", "2",
                ]):
                    self.assertEqual(retry.main(), 0)
            self.assertEqual(len(json.loads(evidence.read_text())["tests"]), 2)

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
            {"databaseId": 3, "createdAt": (now - timedelta(hours=1)).isoformat(), "conclusion": "failure"},
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

        timeouts = []

        def bounded_call(command, **kwargs):
            timeouts.append(kwargs["timeout"])
            return gh_call(command, **kwargs)

        with patch.object(retry.subprocess, "check_output", side_effect=bounded_call):
            observed = retry.recent_base_failures(
                "aiur-team/aiur", "main",
                targets={"Aiur.RetryFixtureTest :: flaky one"}, now=now,
            )

        self.assertEqual(observed, {
            "Aiur.RetryFixtureTest :: flaky one", "Aiur.RetryFixtureTest :: flaky two",
        })
        self.assertEqual(viewed, ["1"])
        self.assertTrue(timeouts)
        self.assertTrue(all(0 < timeout <= 5 for timeout in timeouts))

    def test_github_history_failure_disables_base_evidence(self):
        with patch.object(retry.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "gh")):
            observed = retry.recent_base_failures("aiur-team/aiur", "main")
        self.assertEqual(observed, set())

    def test_prepare_script_fetches_base_in_depth_one_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / "origin.git"
            seed = root / "seed"
            workspace = root / "workspace"
            runner_temp = root / "runner-temp"
            runner_temp.mkdir()
            subprocess.run(["git", "init", "--bare", str(origin)], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(["git", "init", str(seed)], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "config", "user.name", "Retry Test"], check=True)
            subprocess.run(["git", "-C", str(seed), "config", "user.email", "retry@example.test"], check=True)
            (seed / ".github").mkdir()
            (seed / "src/test").mkdir(parents=True)
            (seed / "scripts").mkdir()
            (seed / ".github/known-flaky-tests.txt").write_text(
                "Aiur.RetryFixtureTest :: flaky one\n"
            )
            (seed / "src/test/quarantine.txt").write_text("")
            for name in ("ci-flake-retry.py", "prepare-coverage-retry.sh"):
                (seed / "scripts" / name).write_bytes((ROOT / "scripts" / name).read_bytes())
            subprocess.run(["git", "-C", str(seed), "add", "."], check=True)
            subprocess.run(["git", "-C", str(seed), "commit", "-m", "Base"], check=True,
                           stdout=subprocess.DEVNULL)
            base_sha = subprocess.check_output(
                ["git", "-C", str(seed), "rev-parse", "HEAD"], text=True
            ).strip()
            subprocess.run(["git", "-C", str(seed), "branch", "-M", "main"], check=True)
            subprocess.run(["git", "-C", str(seed), "remote", "add", "origin", str(origin)], check=True)
            subprocess.run(["env", "AIUR_AGENT_WORKSPACE=", "git", "-c", "protocol.file.allow=always", "-C", str(seed), "push", "origin", "main"], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "checkout", "-b", "feature"], check=True,
                           stdout=subprocess.DEVNULL)
            (seed / "README.md").write_text("PR-only change\n")
            subprocess.run(["git", "-C", str(seed), "add", "README.md"], check=True)
            subprocess.run(["git", "-C", str(seed), "commit", "-m", "PR change"], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "checkout", "main"], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "merge", "--no-ff", "feature", "-m", "Merge PR"],
                           check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["env", "AIUR_AGENT_WORKSPACE=", "git", "-c", "protocol.file.allow=always", "-C", str(seed), "push", "origin", "HEAD:merge"], check=True,
                           stdout=subprocess.DEVNULL)
            subprocess.run([
                "git", "-c", "protocol.file.allow=always", "clone", "--depth=1", "--branch", "merge",
                f"file://{origin}", str(workspace),
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shallow = subprocess.check_output(
                ["git", "-C", str(workspace), "rev-parse", "--is-shallow-repository"], text=True
            ).strip()
            self.assertEqual(shallow, "true")
            failed_log = runner_temp / "failed.log"
            failed_log.write_text(
                "  1) test flaky one (Aiur.RetryFixtureTest)\n"
                "     test/aiur/retry_fixture_test.exs:10\n"
                "1 test, 1 failure\n"
            )
            status_file = runner_temp / "partition.status"
            status_file.write_text("2\n")
            summary = runner_temp / "summary.md"
            summary.write_text("")
            env = dict(os.environ, AIUR_REAL_GIT="/usr/bin/git", GITHUB_WORKSPACE=str(workspace),
                       RUNNER_TEMP=str(runner_temp), GITHUB_STEP_SUMMARY=str(summary),
                       BASE_SHA=base_sha, BASE_BRANCH="main", REPOSITORY="aiur-team/aiur")
            completed = subprocess.run([
                "bash", str(workspace / "scripts/prepare-coverage-retry.sh"),
                "1", str(failed_log), str(status_file),
            ], env=env, text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("test/aiur/retry_fixture_test.exs:10", (runner_temp / "shard-evidence/retry-tests.txt").read_text())
            plan = json.loads((runner_temp / "shard-evidence/retry-plan.json").read_text())
            self.assertEqual(plan["tests"][0]["test"], "Aiur.RetryFixtureTest :: flaky one")

    def test_retry_script_enforces_timeout_and_records_green_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            evidence = root / "evidence"
            evidence.mkdir()
            (evidence / "retry-tests.txt").write_text("test/aiur/retry_fixture_test.exs:10\n")
            (evidence / "retry-plan.json").write_text(json.dumps({"tests": [{"test": "flaky"}]}))
            timeout_args = root / "timeout-args.txt"
            timeout_script = bin_dir / "timeout"
            timeout_script.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$@\" > \"$TIMEOUT_ARGS\"\n"
                "shift 3\nexec \"$@\"\n"
            )
            timeout_script.chmod(0o755)
            mix_script = bin_dir / "mix"
            mix_script.write_text("#!/usr/bin/env bash\necho '1 test, 0 failures'\n")
            mix_script.chmod(0o755)
            summary = root / "summary.md"
            completed = subprocess.run([
                "bash", str(ROOT / "scripts/retry-coverage-tests.sh"), "2", str(evidence),
            ], env=dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        TIMEOUT_ARGS=str(timeout_args), GITHUB_STEP_SUMMARY=str(summary)),
                text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(timeout_args.read_text().splitlines()[:3], [
                "--signal=TERM", "--kill-after=60s", "10m",
            ])
            plan = json.loads((evidence / "retry-plan.json").read_text())
            self.assertEqual(plan["outcome"], "success")
            self.assertIn("Retried known flakes: all selected tests passed", summary.read_text())

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
        self.assertIn('git -C "$workspace" fetch --no-tags --depth=1 origin "$BASE_SHA"', prepare)
        self.assertIn('git -C "$workspace" diff --name-only "$BASE_SHA" HEAD', prepare)
        self.assertIn("--partition-status", prepare)
        self.assertIn("status_file=", partition_script)
        self.assertIn('printf \'%s\\n\' "$status" > "$status_file"', partition_script)
        self.assertIn("timeout --signal=TERM --kill-after=60s 20m", partition_script)
        self.assertIn("make coverage-partition", partition_script)
        self.assertIn("timeout --signal=TERM --kill-after=60s 10m", retry_script)

    def test_coverage_job_budget_covers_partition_and_retry_bounds(self):
        # A job timeout below both bounds cancels the evidence uploads (#2397/#2560).
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        partition = workflow.split("  coverage-partition:\n", 1)[1].split("\n  test:\n", 1)[0]
        job_minutes = int(re.search(r"^    timeout-minutes: (\d+)$", partition, re.M).group(1))

        def bound_minutes(script):
            text = (ROOT / "scripts" / script).read_text()
            kill, run = re.search(r"timeout --signal=TERM --kill-after=(\d+)s (\d+)m", text).groups()
            return int(run) + int(kill) / 60

        worst_case = bound_minutes("run-coverage-partition.sh") + bound_minutes("retry-coverage-tests.sh")
        setup_and_uploads = 3
        self.assertGreaterEqual(job_minutes, worst_case + setup_and_uploads)


if __name__ == "__main__":
    unittest.main(verbosity=2)
