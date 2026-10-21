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
