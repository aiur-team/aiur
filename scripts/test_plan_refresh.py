#!/usr/bin/env python3
"""Isolated CLI fixtures; runnable with python3 -I scripts/test_plan_refresh.py."""
import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name('plan_refresh.py')
HEADER = ['path', 'release_lines', 'package', 'frozen_owner', 'frozen_disposition', 'confidence']


class PlanRefreshTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.write('src/a.ex', ''.join(f'line {n}\n' for n in range(1, 21)))
        self.write('src/shift.ex', ''.join(f'shift {n}\n' for n in range(1, 21)))
        self.write('src/delete.ex', 'deleted\n')
        self.write('website/grow.txt', 'line\n' * 499)
        self.write('website/boundary.txt', 'line\n' * 500)
        self.write('website/unassigned.txt', 'line\n' * 600)
        self.write('website/shrink.txt', 'line\n' * 501)
        self.pack = self.repo / 'pack'
        self.write('pack/tickets/one.md', '---\nticket_id: T1\nsize_owner: n/a\n---\n'
                   '`src/a.ex:3` `src/shift.ex:10-12` `src/delete.ex`\n'
                   '`website/grow.txt` `website/boundary.txt` `website/unassigned.txt`\n')
        self.write('pack/tickets/two.md', '---\nticket_id: T2\nsize_owner: WEB\n---\n`website/shrink.txt`\n')
        self.write('pack/bucket/migration-plan.md', '| Row | Today | Destination |\n'
                   '| PR-01 | `src/a.ex` | target |\n'
                   '| PR-02 | `src/{a,shift}.ex` | target |\n'
                   '| PR-03 | `src/delete.ex` | target |\n')
        self.write('pack/contracts/events-and-replay.md',
                   '---\nstatus: frozen\nbase_main_sha: abc\ndate: 2026-10-08\n---\n')
        self.before = self.commit()
        self.git('mv', 'src/a.ex', 'src/b.ex')
        path = self.repo / 'src/shift.ex'
        path.write_text('inserted 1\ninserted 2\n' + path.read_text())
        self.git('rm', '-q', 'src/delete.ex')
        self.write('website/grow.txt', 'line\n' * 500 + 'last')
        self.write('website/shrink.txt', 'line\n' * 500)
        self.after = self.commit()
        self.ledger = self.root / 'ledger.csv'
        with self.ledger.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(HEADER)
            writer.writerow(['website/grow.txt', 501, 'WEB', '', '', ''])
        self.out = self.root / 'report.md'

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'Fixture')
        return self.git('rev-parse', 'HEAD')

    def run_tool(self, *extra, expected=0):
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), '--repo', str(self.repo),
                                 '--from', self.before, '--to', self.after, '--pack', str(self.pack),
                                 '--u8-ledger', str(self.ledger), '--out', str(self.out), *extra],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        return self.out.read_text() if expected == 0 else result.stderr

    def test_rename_marks_moved(self):
        self.assertIn('| src/a.ex:3 | MOVED src/a.ex → src/b.ex |', self.run_tool())

    def test_insert_above_shifts_lines(self):
        self.assertIn('| src/shift.ex:10-12 | LINES-SHIFTED :12-14 |', self.run_tool())

    def test_edit_inside_range_flags_changed(self):
        path = self.repo / 'src/shift.ex'
        path.write_text(path.read_text().replace('shift 11\n', 'changed\n'))
        self.after = self.commit()
        self.assertIn('| src/shift.ex:10-12 | LINES-CHANGED |', self.run_tool())

    def test_deleted_file_gone(self):
        self.assertIn('| src/delete.ex | GONE |', self.run_tool())

    def test_size_owner_mismatch(self):
        self.assertIn('| T1 | website/grow.txt | 501 | n/a | MISMATCH (ledger says WEB) |', self.run_tool())

    def test_size_500_is_not_oversized(self):
        sizes = self.run_tool().split('## Size owners by ticket')[1]
        self.assertNotIn('website/boundary.txt', sizes)

    def test_unassigned_oversized(self):
        self.assertIn('| T1 | website/unassigned.txt | 600 | n/a | UNASSIGNED', self.run_tool())

    def test_bad_ledger_exits_2(self):
        self.ledger.write_text('path,package\n')
        self.assertIn('ledger header must be', self.run_tool(expected=2))

    def test_pack_ref_matches_local_pack(self):
        local = self.run_tool()
        self.assertEqual(local, self.run_tool('--pack', 'pack', '--pack-ref', self.before))

    def test_missing_inputs_exit_2(self):
        self.assertIn('pack contains no Markdown', self.run_tool('--pack', str(self.root / 'absent'), expected=2))
        self.assertIn('plan-refresh:', self.run_tool('--to', 'missing-ref', expected=2))
        self.assertIn('plan-refresh:', self.run_tool('--u8-ledger', str(self.root / 'missing'), expected=2))

    def test_identity_has_no_moves_or_stale_lines(self):
        output = self.run_tool('--to', self.before)
        self.assertIn('0 file moves', output)
        for status in ('GONE', 'MOVED ', 'LINES-SHIFTED', 'LINES-CHANGED'):
            self.assertNotIn(status, output)

    def test_path_rows_and_contract_metadata(self):
        output = self.run_tool()
        self.assertIn('| PR-01 | `src/a.ex` | moved | src/b.ex (unassigned) |', output)
        self.assertIn('| PR-02 | `src/{a,shift}.ex` | partly moved |', output)
        self.assertIn('| PR-03 | `src/delete.ex` | deleted |', output)
        self.assertIn('| events-and-replay | frozen | abc | 2026-10-08 |', output)
        self.assertIn('| T2 | — | — | WEB | NO-LONGER-OVERSIZED |', output)

    def test_component_map_most_specific_segment_globs(self):
        self.write('components.json', json.dumps({'components': [
            {'id': 'general', 'paths': ['src/**']},
            {'id': 'nested-only', 'paths': ['src/*/*.ex']},
            {'id': 'specific', 'paths': ['src/b.ex']}]}))
        self.after = self.commit()
        output = self.run_tool()
        self.assertIn('Component manifest absent at ' + self.before, output)
        self.assertIn('| PR-01 | `src/a.ex` | moved | src/b.ex (specific) |', output)
        self.assertIn('src/shift.ex (general)', output)
        self.assertIn('| specific |  | src/b.ex |', output)
        self.git('rm', '-q', 'components.json')
        self.write('components/0.json', json.dumps({'components': [{'id': 'split', 'paths': ['src/**']}]}))
        self.after = self.commit()
        self.assertIn('src/b.ex (split)', self.run_tool())

    def test_split_and_unresolved_citation(self):
        self.write('src/a_part.ex', 'new split\n')
        self.write('pack/tickets/extra.md', '`src/absent.ex:9`\n')
        self.after = self.commit()
        output = self.run_tool()
        self.assertIn('SPLIT? src/a_part.ex', output)
        self.assertIn('UNRESOLVED (absent at from)', output)

    def test_insert_at_start_and_end_boundaries(self):
        original = ''.join(f'shift {n}\n' for n in range(1, 21))
        self.write('src/shift.ex', original.replace('shift 10\n', 'insert\nshift 10\n'))
        self.after = self.commit()
        self.assertIn('LINES-SHIFTED :11-13', self.run_tool())
        self.write('src/shift.ex', original.replace('shift 11\n', 'shift 11\ninsert\n'))
        self.after = self.commit()
        self.assertIn('LINES-CHANGED', self.run_tool())
        self.write('src/shift.ex', original.replace('shift 12\n', 'shift 12\ninsert\n'))
        self.after = self.commit()
        self.assertIn('| src/shift.ex:10-12 | OK |', self.run_tool())


if __name__ == '__main__':
    unittest.main(verbosity=2)
