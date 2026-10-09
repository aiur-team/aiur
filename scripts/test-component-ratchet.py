#!/usr/bin/env python3
"""Real CLI fixtures for the component allowlist ratchet."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from components.public_fixtures import public_fields

REPO = Path(__file__).resolve().parent.parent
CHECKER = REPO / 'scripts/check-components.py'


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(REPO / 'scripts/components/fixtures/allowlisted_violation_passes',
                        self.root, dirs_exist_ok=True)
        shutil.copyfile(REPO / 'components.schema.json', self.root / 'components.schema.json')
        manifest_path = self.root / 'components.json'
        manifest = json.loads(manifest_path.read_text())
        manifest.update(components=[public_fields(c) for c in manifest['components']], features=[])
        manifest_path.write_text(json.dumps(manifest))
        self.path = self.root / 'scripts/components/allowlist/a.tsv'
        self.original = self.path.read_text()

    def check(self, *args, code=0, summary=None):
        env = dict(os.environ, AIUR_COMPONENTS_ROOT=str(self.root))
        env.pop('GITHUB_STEP_SUMMARY', None)
        if summary:
            env['GITHUB_STEP_SUMMARY'] = str(summary)
        result = subprocess.run([sys.executable, str(CHECKER), '--rules', 'elixir', *args],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def base(self):
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'Fixture baseline')
        return self.git('rev-parse', 'HEAD')

    def stale(self):
        self.path.write_text(self.original + 'R-private\ta.DoesNotExist\t#3300 temporary\n')

    def test_stale_entry_fails(self):
        self.stale()
        self.assertIn('stale allowlist entry: R-private a -> a.DoesNotExist; delete it from '
                      'scripts/components/allowlist/a.tsv or run python3 scripts/check-components.py --prune',
                      self.check(code=1))

    def test_prune_removes_only_stale(self):
        self.stale()
        self.check('--prune')
        self.assertEqual(self.path.read_text(), self.original)
        self.check()

    def test_prune_never_adds(self):
        self.path.write_text('# rule\ttarget_module\treason\n')
        before = self.path.read_bytes()
        self.assertIn('R-private a -> B.Internal', self.check('--prune', code=1))
        self.assertEqual(self.path.read_bytes(), before)

    def test_selected_rule_preserves_other_rules(self):
        self.stale()
        self.check('--rules', 'optional', '--prune')
        self.assertIn('a.DoesNotExist', self.path.read_text())

    def grow(self, reason):
        manifest_path = self.root / 'components.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['components'][1]['layer'] = 3
        manifest_path.write_text(json.dumps(manifest))
        self.path.write_text(self.original + f'R-down\tB.Internal\t{reason}\n')

    def test_growth_without_ticket_reason_fails(self):
        base = self.base()
        self.grow('todo')
        self.assertIn('added allowlist entry requires a ticket reason',
                      self.check('--growth-base', base, code=1))

    def test_growth_with_ticket_reason_passes(self):
        base = self.base()
        for reason in ('MP-R1-C7-T03 temporary', 'U12 temporary', '#3300 temporary'):
            self.grow(reason)
            self.check('--growth-base', base)

    def test_duplicate_baseline_row_is_growth(self):
        self.path.write_text(self.original.replace('fixture baseline', 'baseline abcdef0'))
        base = self.base()
        self.path.write_text(self.path.read_text() + 'R-private\tB.Internal\tbaseline abcdef0\n')
        self.check('--growth-base', base, code=1)

    def test_new_file_growth_fails(self):
        self.path.unlink()
        base = self.base()
        self.path.write_text(self.original.replace('fixture', 'todo'))
        self.check('--growth-base', base, code=1)

    def test_baseline_reason_cannot_bypass_growth(self):
        base = self.base()
        self.path.write_text(self.original.replace('fixture', 'baseline abcdef0'))
        self.check('--growth-base', base, code=1)

    def test_missing_base_is_fetched(self):
        self.base()
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory)
            shutil.copytree(self.root, remote, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns('.git'))
            def git(*args):
                return subprocess.check_output(['git', '-C', str(remote), *args], text=True).strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-qm', 'Remote fixture baseline')
            base = git('rev-parse', 'HEAD')
            self.git('remote', 'add', 'origin', str(remote))
            self.grow('todo')
            self.assertIn('added allowlist entry requires a ticket reason',
                          self.check('--growth-base', base, code=1))
            self.git('cat-file', '-e', f'{base}^{{commit}}')

    def test_unfetchable_base_warns_and_stale_still_fails(self):
        self.base()
        self.stale()
        text = self.check('--growth-base', '0' * 40, code=1)
        self.assertIn('growth guard skipped', text)
        self.assertIn('stale allowlist entry', text)

    def test_prune_and_baseline_are_incompatible(self):
        self.assertIn('--prune cannot be combined with --write-baseline',
                      self.check('--prune', '--write-baseline', code=2))
        self.assertEqual(self.path.read_text(), self.original)

    def test_summary_written_on_failure(self):
        self.stale()
        summary = self.root / 'summary.md'
        summary.write_text('Earlier step\n')
        self.check(code=1, summary=summary)
        text = summary.read_text()
        self.assertTrue(text.startswith('Earlier step\n'))
        self.assertIn('R-private: 1 violations, 1 allowed, 0 new, 1 stale', text)
        self.assertIn('Largest SCC: 1 components', text)
        self.assertRegex(text, r'Runtime: [0-9.]+ s')


if __name__ == '__main__':
    unittest.main(verbosity=2)
