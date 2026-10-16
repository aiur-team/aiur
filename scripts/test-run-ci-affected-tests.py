#!/usr/bin/env python3
"""Exercise the selector runner with a hermetic Mix executable."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('run-ci-affected-tests.py')


class AffectedRunnerTest(unittest.TestCase):
    def run_selection(self, selection, status=0):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            mix = root / 'mix'
            mix.write_text('''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1] == 'aiur.affected_tests':
    assert sys.argv[2] == 'base-sha'
    print(os.environ['SELECTION'])
else:
    with open(os.environ['CALLS'], 'a') as out:
        out.write(json.dumps(sys.argv[1:]) + '\\n')
    sys.exit(int(os.environ['TEST_STATUS']))
''')
            mix.chmod(0o755)
            calls = root / 'calls'
            summary = root / 'summary.md'
            result = subprocess.run(['python3', str(SCRIPT), 'base-sha'], capture_output=True,
                                    env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                                             SELECTION=selection, CALLS=str(calls), TEST_STATUS=str(status),
                                             GITHUB_STEP_SUMMARY=str(summary)))
            self.last_stderr = result.stderr
            self.last_stdout = result.stdout
            self.last_summary = summary.read_text() if summary.exists() else ''
            self.assertNotIn(b"can't open file", result.stderr)
            invoked = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result.returncode, invoked, result.stdout.decode()

    def test_runs_selected_paths_without_shell_evaluation(self):
        self.assertEqual(self.run_selection("cd src && mise exec -- mix test --max-cases 4 'test/a test.exs' 'test/$(bad)_test.exs'"),
                         (0, [['test', '--max-cases', '4', 'test/a test.exs', 'test/$(bad)_test.exs']],
                          "cd src && mise exec -- mix test --max-cases 4 'test/a test.exs' 'test/$(bad)_test.exs'\n\n"))

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

    def test_no_tests_does_not_run_test_suite(self):
        self.assertEqual(self.run_selection('# no affected test files detected for the documentation-only change'),
                         (0, [], '# no affected test files detected for the documentation-only change\n\n'))

    def test_failure_is_not_reported_as_success(self):
        self.assertNotEqual(self.run_selection('cd src && mise exec -- mix test --max-cases 4 test/a_test.exs', 1)[0], 0)

    def test_selector_timeout_preserves_stage_diagnostic_and_fails(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            mix = root / 'mix'
            mix.write_text('''#!/usr/bin/env python3
import time
print('affected-test selector: xref graph label=compile', file=__import__('sys').stderr, flush=True)
time.sleep(30)
''')
            mix.chmod(0o755)
            process = subprocess.Popen(
                ['python3', str(SCRIPT), 'base-sha'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                         AIUR_CI_SELECTOR_TIMEOUT_SECONDS='2'),
            )
            try:
                readable, _writable, _exceptional = select.select([process.stdout], [], [], 1.5)
                self.assertTrue(readable, 'selector stage was not streamed before the timeout')
                self.assertIn('xref graph label=compile', process.stdout.readline())
                _stdout, stderr = process.communicate(timeout=4)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn('selector exceeded 2s', stderr)
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()

    def test_selector_timeout_kills_descendants_that_ignore_sigterm(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            child_pid = root / 'child.pid'
            mix = root / 'mix'
            mix.write_text(f'''#!/usr/bin/env python3
import signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
open({str(child_pid)!r}, 'w').write(str(child.pid))
print('selector started', flush=True)
time.sleep(30)
''')
            mix.chmod(0o755)
            process = subprocess.Popen(
                ['python3', str(SCRIPT), 'base-sha'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                         AIUR_CI_SELECTOR_TIMEOUT_SECONDS='2'),
            )
            try:
                _stdout, stderr = process.communicate(timeout=8)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn('selector exceeded 2s', stderr)
                child_process = subprocess.run(
                    ['ps', '-o', 'stat=', '-p', child_pid.read_text()],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(child_process.stdout.strip(), '', 'selector descendant survived timeout')
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()

    def test_selector_timeout_catches_descendant_holding_stdout_after_leader_exits(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            child_pid = root / 'child.pid'
            mix = root / 'mix'
            mix.write_text(f'''#!/usr/bin/env python3
import subprocess, sys
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
open({str(child_pid)!r}, 'w').write(str(child.pid))
print('# no affected test files detected', flush=True)
''')
            mix.chmod(0o755)
            result = subprocess.run(
                ['python3', str(SCRIPT), 'base-sha'],
                capture_output=True,
                text=True,
                timeout=8,
                start_new_session=True,
                env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                         AIUR_CI_SELECTOR_TIMEOUT_SECONDS='2'),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('selector exceeded 2s', result.stderr)
            child_process = subprocess.run(
                ['ps', '-o', 'stat=', '-p', child_pid.read_text()],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(child_process.stdout.strip(), '', 'selector descendant survived timeout')

    def test_unrecognized_output_fails_closed(self):
        for value in ['unexpected', 'cd src && mise exec -- echo success']:
            self.assertNotEqual(self.run_selection(value)[0], 0)


if __name__ == '__main__':
    unittest.main()
