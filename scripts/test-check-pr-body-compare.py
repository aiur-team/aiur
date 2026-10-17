#!/usr/bin/env python3
"""Local-history contribution comparison for the PR-body gate (#4856)."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pr_body', Path(__file__).with_name('check-pr-body.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PrBodyCompareTests(unittest.TestCase):
    def test_local_history_accepts_a_main_merge_and_rejects_an_extra_edit(self):
        with tempfile.TemporaryDirectory(prefix='pr-body-carry-') as scratch:
            root = Path(scratch)
            self.git(root, 'init', '-b', 'main')
            self.git(root, 'config', 'user.name', 'Test')
            self.git(root, 'config', 'user.email', 'test@example.invalid')
            (root / 'a.ex').write_text('l1\nl2\nl3\n')
            (root / 'b.ex').write_text('x\n')
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-m', 'initial')
            self.git(root, 'switch', '-c', 'feature')
            (root / 'a.ex').write_text('l1\nl2\nl3\nfeature\n')
            self.git(root, 'commit', '-am', 'feature')
            tested = self.git(root, 'rev-parse', 'HEAD').strip()
            self.git(root, 'switch', 'main')
            (root / 'b.ex').write_text('y\n')
            self.git(root, 'commit', '-am', 'main moves')
            self.git(root, 'switch', 'feature')
            self.git(root, 'merge', '--no-edit', 'main')
            pr = lambda: {'body': f'Tested head: {tested}\n', 'base': {'sha': 'main'},
                          'head': {'sha': self.git(root, 'rev-parse', 'HEAD').strip()}}
            with patch('builtins.print'):
                self.assertEqual(self.local_carry(pr(), root), (tested, f'identical contribution since {tested}'))
                (root / 'a.ex').write_text('l1\nl2\nl3\nfeature\nextra\n')
                self.git(root, 'commit', '-am', 'extra')
                self.assertEqual(self.local_carry(pr(), root)[1], 'exact head')

    def test_local_history_carries_a_main_merge_of_more_than_300_files(self):
        with tempfile.TemporaryDirectory(prefix='pr-body-carry-') as scratch:
            root = Path(scratch)
            self.git(root, 'init', '-b', 'main')
            self.git(root, 'config', 'user.name', 'Test')
            self.git(root, 'config', 'user.email', 'test@example.invalid')
            (root / 'a.ex').write_text('l1\n')
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-m', 'initial')
            self.git(root, 'switch', '-c', 'feature')
            (root / 'a.ex').write_text('l1\nfeature\n')
            self.git(root, 'commit', '-am', 'feature')
            tested = self.git(root, 'rev-parse', 'HEAD').strip()
            self.git(root, 'switch', 'main')
            for n in range(301):
                (root / f'base_{n}.ex').write_text(f'{n}\n')
            self.git(root, 'add', '.')
            self.git(root, 'commit', '-m', 'main moves 301 files')
            self.git(root, 'switch', 'feature')
            self.git(root, 'merge', '--no-edit', 'main')
            pr = {'body': f'Tested head: {tested}\n', 'base': {'sha': 'main'},
                  'head': {'sha': self.git(root, 'rev-parse', 'HEAD').strip()}}
            with patch('builtins.print'):
                self.assertEqual(self.local_carry(pr, root), (tested, f'identical contribution since {tested}'))

    def local_carry(self, pr, history):
        # History comes from the scratch repository; the classifier source from this checkout.
        real_git, real_ancestor = gate.git, gate.is_ancestor
        with patch.object(gate, 'git', side_effect=lambda _root, *args: real_git(history, *args)), \
             patch.object(gate, 'is_ancestor', side_effect=lambda _root, t, h: real_ancestor(history, t, h)):
            return gate.evidence_head(pr, Path(__file__).resolve().parent.parent)

    def test_comparison_timeout_falls_back_to_the_exact_head(self):
        pr = {'body': f'Tested head: {"c" * 40}\n', 'head': {'sha': 'a' * 40}, 'base': {'sha': 'b' * 40}}
        hung = subprocess.TimeoutExpired(['git', 'diff'], gate.GIT_TIMEOUT)
        with patch.object(gate, 'is_ancestor', return_value=True), \
             patch.object(gate.subprocess, 'check_output', side_effect=hung) as git, \
             patch('builtins.print') as say:
            self.assertEqual(gate.evidence_head(pr, Path.cwd()), ('a' * 40, 'exact head'))
        self.assertEqual(git.call_args.kwargs['timeout'], gate.GIT_TIMEOUT)
        self.assertIn('comparison unavailable', say.call_args.args[0])

    def git(self, root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT, text=True)


if __name__ == '__main__':
    unittest.main()
