#!/usr/bin/env python3
"""Exercise latest PR-body check selection against the GitHub API boundary."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name('check-pr-body-check-run.py')
SPEC = importlib.util.spec_from_file_location('pr_body_check_run', MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrBodyCheckRunTest(unittest.TestCase):
    def test_latest_pr_body_run_is_selected_and_requires_success(self):
        response = {
            'check_runs': [
                {'id': 10, 'name': 'pr body', 'head_sha': 'head', 'status': 'completed',
                 'conclusion': 'failure'},
                {'id': 11, 'name': 'lint', 'head_sha': 'head', 'status': 'completed',
                 'conclusion': 'success'},
                {'id': 12, 'name': 'pr body', 'head_sha': 'head', 'status': 'completed',
                 'conclusion': 'success'},
            ],
        }
        completed = subprocess.CompletedProcess([], 0, json.dumps(response), '')
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'aiur-team/aiur', 'PR_HEAD': 'head'}):
            with patch.object(MODULE.subprocess, 'run', return_value=completed) as run:
                self.assertEqual(MODULE.latest_check()['id'], 12)
        self.assertIn('commits/head/check-runs?per_page=100', run.call_args.args[0][2])

    def test_missing_pr_body_run_is_rejected(self):
        with patch.object(MODULE, 'latest_check', return_value=None):
            with patch('sys.stderr') as stderr:
                self.assertEqual(MODULE.main(), 1)
                self.assertEqual(''.join(call.args[0] for call in stderr.write.call_args_list),
                                 'ci gate failed: PR-body check has not reported yet\n')


if __name__ == '__main__':
    unittest.main()
