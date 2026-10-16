#!/usr/bin/env python3
"""Contract tests for quarantine-list selection."""

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("run-quarantined-tests.py")
SPEC = importlib.util.spec_from_file_location("quarantined_tests", SCRIPT)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class QuarantinedTestSelectionTest(unittest.TestCase):
    def test_every_list_entry_resolves_to_a_focused_test_location(self):
        selected = RUNNER.selectors()

        self.assertGreaterEqual(len(selected), len(RUNNER.entries()))
        self.assertTrue(any(item.startswith("test/aiur/experiments_cli_test.exs:") for item in selected))
        self.assertGreaterEqual(sum(item.startswith("test/aiur/core/agent_runner_checkpoint_queue_test.exs:") for item in selected), 2)

    def test_selector_locations_are_unique(self):
        selected = RUNNER.selectors()
        self.assertTrue(selected)
        self.assertEqual(len(selected), len(set(selected)))


if __name__ == "__main__":
    unittest.main()
