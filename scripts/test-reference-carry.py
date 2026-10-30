#!/usr/bin/env python3
"""Regression tests for the reference migration command's actual entry point."""
import csv
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('reference_carry', REPO / 'scripts/carry-reference-edits.py')
CARRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CARRY)


class ReferenceCarryTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        shutil.copytree(REPO / 'website/docs-app/reference', self.root / 'website/docs-app/reference')
        (self.root / 'scripts').mkdir()
        shutil.copyfile(REPO / 'scripts/reference-sections.tsv', self.root / 'scripts/reference-sections.tsv')
        with (self.root / 'scripts/reference-sections.tsv').open() as file:
            self.routes = [row for row in csv.DictReader(file, delimiter='\t') if row['destination'] == 'cli-launch.md']
        self.page = self.root / 'website/docs-app/reference/cli-launch.md'
        self.before = self.page.read_text()
        self.after = self.before.replace('## Start, initialize, and queue\n',
                                         '## Start, initialize, and queue\n\nCarried PR addition.\n')

    def run_command(self):
        def git_output(root, *args):
            if args[0] == 'rev-parse':
                return str(root) + '\n'
            if args[0] == 'status':
                return ''
            if args[0] == 'merge-base':
                return 'base\n'
            if args[0] == 'show':
                return self.before if args[1].startswith('base:') else self.after
            self.fail(f'unexpected Git call: {args}')

        with patch('sys.argv', ['carry', '--pr', '123', '--root', str(self.root)]), \
                patch.object(CARRY, 'git', side_effect=git_output), \
                patch.object(CARRY.subprocess, 'run') as fetch:
            CARRY.main()
        fetch.assert_called_once_with(['git', '-C', str(self.root), 'fetch', 'origin',
                                      'pull/123/head:refs/aiur/reference-carry/123'], check=True)

    def test_command_carries_edits_and_preserves_other_sections(self):
        # Limit the fixture's map to the document whose old source Git returns.
        with (self.root / 'scripts/reference-sections.tsv').open('w') as file:
            writer = csv.DictWriter(file, self.routes[0].keys(), delimiter='\t', lineterminator='\n')
            writer.writeheader()
            writer.writerows(self.routes)
        self.run_command()
        self.assertEqual(self.page.read_text().strip(), self.after.strip())
        self.run_command()
        self.assertEqual(self.page.read_text().count('Carried PR addition.'), 1)

    def test_concurrent_section_edits_are_refused_without_writes(self):
        self.page.write_text(self.before.replace('## Start, initialize, and queue\n',
                                                 '## Start, initialize, and queue\n\nCurrent addition.\n'))
        current = self.page.read_text()
        with self.assertRaisesRegex(ValueError, 'overlapping edits'):
            CARRY.carry(self.root, {'cli.md': self.before}, {'cli.md': self.after}, self.routes)
        self.assertEqual(self.page.read_text(), current)

    def test_nonoverlapping_changes_in_one_section_preserve_both_sides(self):
        heading = '## Start, initialize, and queue'
        prefix, before = CARRY.sections(self.before)
        current = dict(before)
        current[heading] = current[heading].rstrip() + '\n\nCurrent addition.\n'
        self.page.write_text(prefix + ''.join(current.values()))
        proposed = CARRY.carry(self.root, {'cli.md': self.before}, {'cli.md': self.after}, self.routes)
        result = proposed[self.page]
        self.assertIn('Carried PR addition.', result)
        self.assertIn('Current addition.', result)
        self.assertEqual(result.count('Carried PR addition.'), 1)
        self.assertEqual(result.count('Current addition.'), 1)
        unchanged = [line for line in result.splitlines() if line.strip() and
                     line not in ('Carried PR addition.', 'Current addition.')]
        self.assertEqual(unchanged, [line for line in self.before.splitlines() if line.strip()])

    def test_adjacent_line_replacements_preserve_both_sides(self):
        self.assertEqual(CARRY.merge_section('a\nb\nc\n', 'A\nb\nc\n', 'a\nB\nc\n'), 'A\nB\nc\n')

    def test_new_headings_require_manual_migration(self):
        with self.assertRaisesRegex(ValueError, 'new headings'):
            CARRY.carry(self.root, {'cli.md': self.before},
                        {'cli.md': self.after + '\n### New section\n\nNew content.\n'}, self.routes)
        self.assertEqual(self.page.read_text(), self.before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
