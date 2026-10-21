#!/usr/bin/env python3
"""Exercise the required job set for browser path-gated CI."""
import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    'check_ci_gate', Path(__file__).with_name('check-ci-gate.py'),
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RequiredJobsTest(unittest.TestCase):
    def test_web_pr_requires_browser_shards(self):
        self.assertIn('browser', MODULE.required_jobs('pull_request', False, False, True))

    def test_non_web_pr_skips_browser_shards(self):
        self.assertNotIn('browser', MODULE.required_jobs('pull_request', False, False, False))

    def test_full_ci_label_does_not_select_browser_without_web_changes(self):
        self.assertNotIn('browser', MODULE.required_jobs('pull_request', True, False, False))

    def test_merge_group_always_requires_browser_shards(self):
        self.assertIn('browser', MODULE.required_jobs('merge_group', True, False, False))

    def test_non_pr_full_ci_preserves_browser_shards(self):
        self.assertIn('browser', MODULE.required_jobs('workflow_dispatch', True, False, False))


if __name__ == '__main__':
    unittest.main()
