#!/usr/bin/env python3
"""Exercise union merges for validated shared registries."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('hot_list_format', REPO / 'scripts/check-hot-list-format.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def git(root, *args):
    return subprocess.run(['/usr/bin/git', '-C', str(root), *args], check=True, capture_output=True, text=True).stdout


class SharedListMergeTest(unittest.TestCase):
    def test_union_merge_of_concurrent_additions_passes_registry_checker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git(root, 'init', '-q')
            git(root, 'config', 'user.name', 'Merge test')
            git(root, 'config', 'user.email', 'merge-test@example.invalid')
            (root / '.gitattributes').write_text((REPO / '.gitattributes').read_text())
            self.install_checker_fixture(root)
            target = root / 'scripts/components/allowlist/kernel.tsv'
            target.write_text('# rule\ttarget_module\treason\n')
            self.commit(root, 'base')
            base = git(root, 'rev-parse', 'HEAD').strip()

            git(root, 'checkout', '-q', '-b', 'left')
            target.write_text(target.read_text() + 'R-private\tA.Left\t#100 left\n')
            self.commit(root, 'left row')
            git(root, 'checkout', '-q', base, '-b', 'right')
            target.write_text(target.read_text() + 'R-private\tB.Right\t#101 right\n')
            self.commit(root, 'right row')

            git(root, 'checkout', '-q', 'left')
            result = subprocess.run(['/usr/bin/git', '-C', str(root), 'merge', '--no-edit', 'right'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(CHECKER.check(root), [])

            rows = [row for row in target.read_text().splitlines() if row and not row.startswith('#')]
            self.assertEqual(rows, ['R-private\tA.Left\t#100 left', 'R-private\tB.Right\t#101 right'])

    def test_union_merge_preserves_both_state_writer_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git(root, 'init', '-q')
            git(root, 'config', 'user.name', 'Merge test')
            git(root, 'config', 'user.email', 'merge-test@example.invalid')
            (root / '.gitattributes').write_text((REPO / '.gitattributes').read_text())
            self.install_checker_fixture(root)
            target = root / 'src/test/support/state_writers_allowlist.exs'
            target.parent.mkdir(parents=True, exist_ok=True)
            header = '# Existing cross-owner writes only.\n[\n]\n'
            target.write_text(header)
            self.commit(root, 'base')
            base = git(root, 'rev-parse', 'HEAD').strip()

            git(root, 'checkout', '-q', '-b', 'left')
            target.write_text('# Existing cross-owner writes only.\n[\n  {Aiur.LeftWriter, :left, "left"},\n]\n')
            self.commit(root, 'left row')
            git(root, 'checkout', '-q', base, '-b', 'right')
            target.write_text('# Existing cross-owner writes only.\n[\n  {Aiur.RightWriter, :right, "right"},\n]\n')
            self.commit(root, 'right row')

            git(root, 'checkout', '-q', 'left')
            result = subprocess.run(['/usr/bin/git', '-C', str(root), 'merge', '--no-edit', 'right'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(CHECKER.check(root), [])
            self.assertIn('{Aiur.LeftWriter, :left, "left"}', target.read_text())
            self.assertIn('{Aiur.RightWriter, :right, "right"}', target.read_text())

    @staticmethod
    def install_checker_fixture(root):
        import shutil
        for name in [*CHECKER.CODE_LISTS, 'src/test/support/state_writers_allowlist.exs',
                     'components.json', 'components.schema.json']:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, target)
        for name in ('components', 'scripts/components/allowlist'):
            shutil.copytree(REPO / name, root / name, dirs_exist_ok=True)

    @staticmethod
    def commit(root, message):
        git(root, 'add', '.')
        git(root, 'commit', '-qm', message)


if __name__ == '__main__':
    unittest.main(verbosity=2)
