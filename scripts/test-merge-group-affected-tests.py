#!/usr/bin/env python3
"""Exercise the merge-group-only affected-test runner path."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('run-ci-affected-tests.py')


class MergeGroupSelectionTest(unittest.TestCase):
        def test_merge_group_computes_changed_paths_before_running_selector(self):
            """Exercise merge_group like CI: selector receives base-to-candidate paths."""
            with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
                root = Path(scratch)
                mix = root / 'mix'
                mix.write_text(
                    '#!/usr/bin/env python3\n'
                    'import base64, json, os, sys\n'
                    "assert sys.argv[1:] == ['aiur.affected_tests', 'base-sha']\n"
                    "paths = json.loads(base64.b64decode(os.environ['AIUR_CI_CHANGED_PATHS_B64']))\n"
                    "assert paths == ['src/test/changed_test.exs']\n"
                    "print('cd src && mise exec -- mix test --max-cases 4 test/changed_test.exs')\n"
                )
                mix.chmod(0o755)
                git = root / 'git'
                git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs")\n')
                git.chmod(0o755)
                guard = root / 'guard.py'
                guard.write_text('import sys\n')
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), 'base-sha'], capture_output=True,
                    env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                             GITHUB_EVENT_NAME='merge_group', AIUR_TIME_BOMB_CHECK=str(guard))
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode())

        def test_time_bomb_guard_uses_changed_tests_and_reports_count_and_duration(self):
            with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
                root = Path(scratch)
                mix = root / 'mix'
                mix.write_text('#!/usr/bin/env python3\nprint("cd src && mise exec -- mix test --max-cases 4 test/changed_test.exs test/unchanged_test.exs")\n')
                mix.chmod(0o755)
                git = root / 'git'
                git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs")\n')
                git.chmod(0o755)
                marker = root / 'time-bomb-ran'
                guard = root / 'guard.py'
                guard.write_text(f'import os, pathlib, sys\npathlib.Path({str(marker)!r}).write_text(" ".join(sys.argv[1:]))\npathlib.Path(os.environ["AIUR_TIME_BOMB_COUNT_FILE"]).write_text("1")\n')
                summary = root / 'summary.md'
                result = subprocess.run([sys.executable, str(SCRIPT), 'base-sha'], capture_output=True,
                                        env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                                 GITHUB_EVENT_NAME='merge_group',
                                                 AIUR_TIME_BOMB_CHECK=str(guard),
                                                 GITHUB_STEP_SUMMARY=str(summary)))
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(marker.read_text(), 'test/changed_test.exs')
                self.assertRegex(summary.read_text(), r'merge-group time-bomb rerun: 1 dated test files, [0-9.]+s')

        def test_time_bomb_timeout_is_warning_with_budget_metrics(self):
            with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
                root = Path(scratch)
                mix = root / 'mix'
                mix.write_text('#!/usr/bin/env python3\nprint("cd src && mise exec -- mix test --max-cases 4 test/changed_test.exs")\n')
                mix.chmod(0o755)
                git = root / 'git'
                git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs")\n')
                git.chmod(0o755)
                guard = root / 'guard.py'
                guard.write_text('import os, pathlib, time\npathlib.Path(os.environ["AIUR_TIME_BOMB_COUNT_FILE"]).write_text("1")\ntime.sleep(5)\n')
                summary = root / 'summary.md'
                result = subprocess.run([sys.executable, str(SCRIPT), 'base-sha'], capture_output=True,
                                        env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                                 GITHUB_EVENT_NAME='merge_group',
                                                 AIUR_TIME_BOMB_CHECK=str(guard),
                                                 GITHUB_STEP_SUMMARY=str(summary),
                                                 AIUR_TIME_BOMB_TIMEOUT_SECONDS='0.1'))
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn(b'::warning::', result.stderr)
                self.assertIn(b'1 dated test files', result.stderr)
                self.assertIn('1 dated test files', summary.read_text())

        def test_time_bomb_failure_still_fails_merge_group(self):
            with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
                root = Path(scratch)
                mix = root / 'mix'
                mix.write_text('#!/usr/bin/env python3\nprint("cd src && mise exec -- mix test --max-cases 4 test/changed_test.exs")\n')
                mix.chmod(0o755)
                git = root / 'git'
                git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs")\n')
                git.chmod(0o755)
                guard = root / 'guard.py'
                guard.write_text('import os, pathlib, sys\npathlib.Path(os.environ["AIUR_TIME_BOMB_COUNT_FILE"]).write_text("1")\nsys.exit(1)\n')
                summary = root / 'summary.md'
                result = subprocess.run([sys.executable, str(SCRIPT), 'base-sha'], capture_output=True,
                                        env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                                 GITHUB_EVENT_NAME='merge_group',
                                                 AIUR_TIME_BOMB_CHECK=str(guard),
                                                 GITHUB_STEP_SUMMARY=str(summary)))
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(summary.read_text(), r'merge-group time-bomb rerun: 1 dated test files, [0-9.]+s')



        def test_merge_group_runs_time_bomb_guard_even_without_pr_selection(self):
            with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
                root = Path(scratch)
                mix = root / 'mix'
                mix.write_text('#!/usr/bin/env python3\nprint("cd src && mise exec -- mix test --max-cases 4 test/changed_test.exs")\n')
                mix.chmod(0o755)
                git = root / 'git'
                git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs")\n')
                git.chmod(0o755)
                marker = root / 'time-bomb-ran'
                guard = root / 'guard.py'
                guard.write_text(f'import pathlib, sys\npathlib.Path({str(marker)!r}).write_text(" ".join(sys.argv[1:]))\n')
                result = subprocess.run([sys.executable, str(SCRIPT), 'base-sha'], capture_output=True,
                                        env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                                 GITHUB_EVENT_NAME='merge_group',
                                                 AIUR_TIME_BOMB_CHECK=str(guard)))
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(marker.read_text(), 'test/changed_test.exs')



if __name__ == '__main__':
    unittest.main()
