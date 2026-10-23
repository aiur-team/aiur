#!/usr/bin/env python3
"""Exercise the selector runner with a hermetic Mix executable."""
import json
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('run-ci-affected-tests.py')
SELECTED_TEST = 'cd src && mise exec -- mix test --max-cases 4 test/slow_test.exs'
RUNNER_SPEC = importlib.util.spec_from_file_location('affected_runner', SCRIPT)
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)


class AffectedRunnerTest(unittest.TestCase):
    def run_selection(self, selection, status=0, test_delay=0):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            mix = root / 'mix'
            mix.write_text('''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1] == 'aiur.affected_tests':
    assert sys.argv[2] == 'base-sha'
    print(os.environ['SELECTION'])
else:
    import time
    time.sleep(float(os.environ['TEST_DELAY']))
    with open(os.environ['CALLS'], 'a') as out:
        out.write(json.dumps(sys.argv[1:]) + '\\n')
    sys.exit(int(os.environ['TEST_STATUS']))
''')
            mix.chmod(0o755)
            git = root / 'git'
            git.write_text('#!/usr/bin/env python3\nimport os\nprint(os.environ.get("GIT_DIFF_PATHS", ""))\n')
            git.chmod(0o755)
            time_bombs = root / 'time_bombs.py'
            time_bombs.write_text('import json, os, sys\n'
                                  'open(os.environ["RECHECKS"], "a").write(json.dumps(sys.argv[1:]) + "\\n")\n')
            calls = root / 'calls'
            rechecks = root / 'rechecks'
            summary = root / 'summary.md'
            result = subprocess.run(['python3', str(SCRIPT), 'base-sha'], capture_output=True,
                                    env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                             SELECTION=selection, CALLS=str(calls), TEST_STATUS=str(status),
                                             TEST_DELAY=str(test_delay),
                                             GIT_DIFF_PATHS=os.environ.get('GIT_DIFF_PATHS', ''),
                                             AIUR_TIME_BOMB_CHECK=str(time_bombs), RECHECKS=str(rechecks),
                                             GITHUB_STEP_SUMMARY=str(summary),
                                             GITHUB_EVENT_NAME=''))
            self.last_stderr = result.stderr
            self.last_stdout = result.stdout
            self.last_summary = summary.read_text() if summary.exists() else ''
            self.last_rechecks = ([json.loads(line) for line in rechecks.read_text().splitlines()]
                                  if rechecks.exists() else [])
            self.assertNotIn(b"can't open file", result.stderr)
            self.assertIn(b'::notice::affected-tests selection duration:', result.stderr)
            if 'mix test' in selection and len(selection.split()) <= 305:
                self.assertIn(b'::notice::affected-tests selected tests duration:', result.stderr)
            invoked = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result.returncode, invoked, result.stdout.decode()

    def test_runs_selected_paths_without_shell_evaluation(self):
        self.assertEqual(self.run_selection("cd src && mise exec -- mix test --max-cases 4 'test/a test.exs' 'test/$(bad)_test.exs'"),
                         (0, [['test', '--max-cases', '4', 'test/a test.exs', 'test/$(bad)_test.exs']],
                          "cd src && mise exec -- mix test --max-cases 4 'test/a test.exs' 'test/$(bad)_test.exs'\n\n"))

    def test_selected_test_duration_includes_slow_test_runtime(self):
        status, calls, _output = self.run_selection(SELECTED_TEST, test_delay=1.1)
        match = re.search(rb'::notice::affected-tests selected tests duration: ([0-9.]+)s', self.last_stderr)
        self.assertEqual(status, 0)
        self.assertEqual(calls, [['test', '--max-cases', '4', 'test/slow_test.exs']])
        self.assertIsNotNone(match)
        self.assertGreaterEqual(float(match.group(1)), 1.0)

    def test_selected_test_command_is_terminated_at_its_timeout(self):
        self.assertEqual(RUNNER.SELECTED_TEST_TIMEOUT_SECONDS, 600)
        stderr = io.StringIO()
        command = [sys.executable, '-c', 'import time; time.sleep(5)']
        with patch.object(RUNNER, 'SELECTED_TEST_TIMEOUT_SECONDS', 0.1):
            with redirect_stderr(stderr), self.assertRaises(subprocess.TimeoutExpired):
                RUNNER.run_selected_tests(command)

        match = re.search(r'::notice::affected-tests selected tests duration: ([0-9.]+)s', stderr.getvalue())
        self.assertIsNotNone(match)
        self.assertLess(float(match.group(1)), 2.0)
        self.assertIn('::error::affected-tests selected tests exceeded its 0.1s timeout', stderr.getvalue())

    def test_unsafe_selection_defers_full_suite_to_merge_queue(self):
        reason = 'changed files include test support; changed paths: src/test/support/helper.exs'
        status, calls, output = self.run_selection(
            f'# full suite recommended: {reason}\ncd src && mise exec -- make ci'
        )
        notice = f'Unsafe affected selection deferred to full CI in the merge queue: {reason}'
        self.assertEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIn(f'::notice::{notice}', output)
        self.assertIn(notice, self.last_summary)

    def test_selection_over_300_files_is_covered_by_merge_group_suite(self):
        paths = ' '.join(f'test/file_{index}_test.exs' for index in range(301))
        status, calls, output = self.run_selection(f'cd src && mise exec -- mix test --max-cases 4 {paths}')
        notice = 'selection 301 files > 300; covered by the merge_group full suite'
        self.assertEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIn(notice, output)
        self.assertIn(notice, self.last_summary)

    def test_selection_at_300_files_runs(self):
        # Future-regression guard for the inclusive boundary: 300 stays scoped.
        paths = ' '.join(f'test/file_{index}_test.exs' for index in range(300))
        status, calls, _output = self.run_selection(f'cd src && mise exec -- mix test --max-cases 4 {paths}')
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(calls[0][3:]), 300)

    def test_passing_selection_reruns_with_older_fixture_dates(self):
        status, _calls, _output = self.run_selection('cd src && mise exec -- mix test --max-cases 4 test/a_test.exs')
        self.assertEqual(status, 0)
        self.assertEqual(self.last_rechecks, [['test/a_test.exs']])

    def test_changed_test_modules_run_individually_before_the_affected_selection(self):
        with patch.dict(os.environ, {'GIT_DIFF_PATHS': 'src/test/one_test.exs\nsrc/test/two_test.exs\nsrc/test/support/helper.exs'}):
            status, calls, _output = self.run_selection(
                'cd src && mise exec -- mix test --max-cases 4 test/one_test.exs test/dependency_test.exs'
            )

        self.assertEqual(status, 0)
        self.assertEqual(calls, [
            ['test', '--max-cases', '4', 'test/one_test.exs'],
            ['test', '--max-cases', '4', 'test/two_test.exs'],
            ['test', '--max-cases', '4', 'test/one_test.exs', 'test/dependency_test.exs'],
        ])

    def test_changed_test_modules_are_capped_and_skipped_paths_are_reported(self):
        paths = '\n'.join(f'src/test/module_{index:02}_test.exs' for index in range(11))
        with patch.dict(os.environ, {'GIT_DIFF_PATHS': paths}):
            status, calls, output = self.run_selection(
                'cd src && mise exec -- mix test --max-cases 4 test/module_00_test.exs'
            )

        self.assertEqual(status, 0)
        individual = [call for call in calls[:-1]]
        self.assertEqual(len(individual), RUNNER.MAX_CHANGED_TEST_MODULES)
        self.assertEqual(individual[0][-1], 'test/module_00_test.exs')
        self.assertEqual(individual[-1][-1], 'test/module_07_test.exs')
        self.assertEqual(calls[-1], ['test', '--max-cases', '4', 'test/module_00_test.exs'])
        self.assertIn('first 8 of 11 modules', output)
        self.assertIn('test/module_08_test.exs', output)
        self.assertIn('test/module_10_test.exs', output)

    def test_failing_selection_skips_the_date_rerun(self):
        self.run_selection('cd src && mise exec -- mix test --max-cases 4 test/a_test.exs', 1)
        self.assertEqual(self.last_rechecks, [])

    def test_no_tests_does_not_run_test_suite(self):
        self.assertEqual(self.run_selection('# no affected test files detected for the documentation-only change'),
                         (0, [], '# no affected test files detected for the documentation-only change\n\n'))

    def test_merge_group_full_selection_limits_guard_to_changed_test_files(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            mix = root / 'mix'
            mix.write_text('#!/usr/bin/env python3\nprint("cd src && mise exec -- make ci")\n')
            mix.chmod(0o755)
            git = root / 'git'
            git.write_text('#!/usr/bin/env python3\nprint("src/test/changed_test.exs\\nsrc/test/support/helper.exs")\n')
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

    def test_failure_is_not_reported_as_success(self):
        self.assertNotEqual(self.run_selection('cd src && mise exec -- mix test --max-cases 4 test/a_test.exs', 1)[0], 0)

    def test_unrecognized_output_fails_closed(self):
        for value in ['unexpected', 'cd src && mise exec -- echo success']:
            self.assertNotEqual(self.run_selection(value)[0], 0)


if __name__ == '__main__':
    unittest.main()
