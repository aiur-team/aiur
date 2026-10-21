#!/usr/bin/env python3
"""Fixture tests for the test-isolation ratchet."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("test_isolation", Path(__file__).with_name("check-test-isolation.py"))
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class IsolationLintTests(unittest.TestCase):
    def test_process_sleep_is_reported_with_line(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "sleep_test.exs"
            file.write_text("defmodule SleepTest do\n  Process.sleep(100)\nend\n")
            violations = checker.counts(file)
            self.assertEqual(violations["sleep"], 1)

    def test_lint_failure_includes_file_and_line(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            test_root = root / "src/test"
            test_root.mkdir(parents=True)
            file = test_root / "new_test.exs"
            file.write_text("Process.sleep(100)\n")
            previous_root, previous_test_root, previous_baseline = checker.ROOT, checker.TEST_ROOT, checker.BASELINE
            checker.ROOT, checker.TEST_ROOT, checker.BASELINE = root, test_root, root / "baseline.json"
            checker.BASELINE.write_text(json.dumps({"src/test/new_test.exs": {"sleep": 0}}))
            try:
                self.assertEqual(checker.main(), 1)
            finally:
                checker.ROOT, checker.TEST_ROOT, checker.BASELINE = previous_root, previous_test_root, previous_baseline

    def test_counts_can_only_fall_from_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.json"
            baseline.write_text(json.dumps({"src/test/one_test.exs": {"sleep": 2}}))
            prior = checker.BASELINE
            checker.BASELINE = baseline
            try:
                current = {"src/test/one_test.exs": {"sleep": 1}}
                self.assertTrue(all(rule_count <= json.loads(baseline.read_text())[file].get(rule, 0)
                                    for file, rules in current.items() for rule, rule_count in rules.items()))
            finally:
                checker.BASELINE = prior

    def test_application_env_is_allowed_in_sync_module(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "sync_test.exs"
            file.write_text("use ExUnit.Case, async: false\nApplication.put_env(:app, :key, :value)\n")
            self.assertEqual(checker.counts(file).get("async_global_env", 0), 0)

    def test_application_env_in_async_module_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "async_test.exs"
            file.write_text("use ExUnit.Case, async: true\nApplication.put_env(:app, :key, :value)\n")
            self.assertEqual(checker.counts(file)["async_global_env"], 1)

    def test_empty_capture_comparison_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "log_test.exs"
            file.write_text('assert capture_log(fn -> :ok end) == ""\n')
            self.assertEqual(checker.counts(file)["empty_capture"], 1)

    def test_global_literal_pubsub_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "pubsub_test.exs"
            file.write_text('Phoenix.PubSub.subscribe(Aiur.PubSub, "global")\n')
            self.assertEqual(checker.counts(file)["global_pubsub"], 1)

    def test_owned_process_start_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "owned_test.exs"
            file.write_text("start_supervised!({Agent, fn -> nil end})\n")
            self.assertEqual(checker.counts(file)["unowned_start"], 0)

    def test_async_environment_writes_are_counted_per_module(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "mixed_test.exs"
            file.write_text("""use ExUnit.Case, async: true
Application.put_env(:app, :unsafe, true)
use ExUnit.Case, async: false
System.put_env("SAFE", "yes")
""")
            self.assertEqual(checker.counts(file)["async_global_env"], 1)

    def test_custom_async_case_environment_writes_are_counted(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "custom_case_test.exs"
            file.write_text("use Aiur.BuildHome.AsyncCase, async: true\nApplication.put_env(:app, :unsafe, true)\n")
            self.assertEqual(checker.counts(file)["async_global_env"], 1)

    def test_unowned_process_start_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "spawn_test.exs"
            file.write_text("spawn(fn -> work() end)\nTask.start(fn -> work() end)\n")
            self.assertEqual(checker.counts(file)["unowned_start"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
