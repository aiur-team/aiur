#!/usr/bin/env python3
"""Hermetic rollout and head-wiring checks for the PR-body gate."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pr_body', Path(__file__).with_name('check-pr-body.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PrBodyGateTests(unittest.TestCase):
    def test_both_sides_of_rollout_and_initial_unlanded_gate(self):
        cutoff = gate.timestamp('2026-10-11T12:00:00Z')
        for created, expected in [
            ('2026-10-11T11:59:59Z', False),
            ('2026-10-11T12:00:00Z', False),
            ('2026-10-11T12:00:01Z', True),
        ]:
            with self.subTest(created=created):
                self.assertEqual(gate.needs_check({'created_at': created}, cutoff), expected)
                with tempfile.TemporaryDirectory(prefix='pr-body-main-') as scratch:
                    metadata = Path(scratch) / 'pr.json'
                    metadata.write_text(json.dumps({'created_at': created, 'body': ''}))
                    with patch.object(sys, 'argv', ['check-pr-body', '--pr-json', str(metadata), '--base', 'main']), \
                         patch.object(gate, 'activation_time', return_value=cutoff), \
                         patch.object(gate, 'check_evidence', return_value=7) as check, \
                         patch('builtins.print'):
                        self.assertEqual(gate.main(), 7 if expected else 0)
                        self.assertEqual(check.call_count, int(expected))
        self.assertFalse(gate.needs_check({'created_at': '2026-10-11T12:00:01Z'}, None))

    def test_cutoff_is_first_parent_landing_not_feature_authorship(self):
        with tempfile.TemporaryDirectory(prefix='pr-body-history-') as scratch:
            root = Path(scratch)
            self.git(root, 'init', '-b', 'main')
            self.git(root, 'config', 'gc.auto', '0')
            self.git(root, 'config', 'maintenance.auto', 'false')
            self.git(root, 'config', 'gc.autoDetach', 'false')
            self.git(root, 'config', 'user.name', 'Test')
            self.git(root, 'config', 'user.email', 'test@example.invalid')
            (root / 'README').write_text('before rollout')
            self.git(root, 'add', 'README')
            self.commit(root, 'initial', '2026-10-11T10:00:00Z')
            self.assertIsNone(gate.activation_time(root, 'main'))
            self.git(root, 'switch', '-c', 'feature')
            (root / 'scripts').mkdir()
            (root / 'scripts/check-pr-body.py').write_text('gate')
            self.git(root, 'add', 'scripts/check-pr-body.py')
            self.commit(root, 'feature', '2026-10-11T11:00:00Z')
            self.git(root, 'switch', 'main')
            self.git(root, 'merge', '--no-ff', 'feature', '-m', 'land',
                     env=dict(os.environ, GIT_COMMITTER_DATE='2026-10-11T12:00:00Z'))
            self.assertEqual(gate.activation_time(root, 'main'), gate.timestamp('2026-10-11T12:00:00Z'))

    def test_passes_live_head_and_body_to_shared_checker_and_preserves_failure(self):
        pr = {'body': 'live body', 'head': {'sha': 'a' * 40}}
        def run(command, **kwargs):
            self.assertEqual(command[-2:], ['--head', pr['head']['sha']])
            self.assertEqual(Path(command[command.index('--file') + 1]).read_text(), 'live body')
            return subprocess.CompletedProcess(command, 7)
        with patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertEqual(gate.check_evidence(pr, Path.cwd()), 7)

    def git(self, root, *args, **kwargs):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT, **kwargs)

    def commit(self, root, message, date):
        self.git(root, 'commit', '-m', message,
                 env=dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date))


if __name__ == '__main__':
    unittest.main()
