#!/usr/bin/env python3
"""Exercise the pre-PR command against committed repository fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent


class StructuralGateTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='structure-3652-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / 'scripts/components').mkdir(parents=True)
        for name in ('check-pr-structure.py', 'check-file-size.py', 'check-docs-prose.mjs', 'check-components.py',
                     'components/import_rules.py', 'components/module_references.exs', 'components/ts-imports.mjs'):
            shutil.copyfile(SOURCE / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'scripts/components/node_modules').symlink_to(SOURCE / 'scripts/components/node_modules', target_is_directory=True)
        self.write('.gitignore', 'node_modules/\n__pycache__/\n')
        shutil.copyfile(SOURCE / 'components.schema.json', self.root / 'components.schema.json')
        files = {
            'src/lib/aiur/config/schema.ex': 'embeds_one(:fixture, Fixture)\nfield(:scalar, :integer)\n',
            'src/lib/aiur/env/schema.ex': '{"AIUR_FIXTURE", type: :string}\n',
            'src/lib/aiur/config/paths.ex': 'def fixture_dir, do: "/fixture"\n',
            'website/docs-app/guide/fixture.md': 'One sentence.\n\n| Key | Value |\n| --- | --- |\n',
        }
        for name, body in files.items():
            self.write(name, body)
        manifest = dict(manifest_version=1, components=[dict(
            id='fixture', name='Fixture', layer=0, kind='required',
            paths=[name for name in files if name.startswith('src/lib/')],
            facades=['Aiur.Fixture'], facade_pending=None, requires=[], optional=[],
            owns=dict(config=['fixture', 'scalar'], env=['AIUR_FIXTURE'],
                      state=['fixture_dir'], capabilities=[]), prior=[])])
        self.write('components.json', json.dumps(manifest))
        self.git('init', '-q')
        self.git('config', 'gc.auto', '0')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.commit()
        self.base = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)

    def write(self, name, body):
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(body)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '--allow-empty', '-qm', 'fixture')

    def check(self, expected, message):
        result = subprocess.run(
            ['python3', str(self.root / 'scripts/check-pr-structure.py'), '--base', self.base],
            cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)

    def test_valid_repository(self):
        self.check(0, 'all 3 source files owned')

    def test_oversized_file(self):
        self.write('oversized.txt', 'line\n' * 501)
        self.commit()
        self.check(1, 'oversized.txt: base 0 -> head 501')

    def test_long_paragraph(self):
        self.write('website/docs-app/guide/fixture.md', 'a' * 361 + '\n')
        self.commit()
        self.check(1, '361 characters (max 360)')

    def test_two_sentences_above_table(self):
        self.write('website/docs-app/guide/fixture.md', 'First sentence.\nSecond sentence!\n\n| Key | Value |\n| --- | --- |\n')
        self.commit()
        self.check(1, 'more than one sentence above a table')

    def test_unowned_file(self):
        self.write('src/lib/unowned.ex', 'defmodule Aiur.Unowned do\nend\n')
        self.commit()
        self.check(1, 'src/lib/unowned.ex: unowned file')

    def test_uncommitted_changes_fail_closed(self):
        self.write('src/lib/unowned.ex', 'defmodule Aiur.Unowned do\nend\n')
        self.check(1, 'commit all changes before running')


if __name__ == '__main__':
    unittest.main(verbosity=2)
