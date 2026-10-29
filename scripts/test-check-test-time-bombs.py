#!/usr/bin/env python3
"""Pin the fixture-date shift used by check-test-time-bombs.py."""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('time_bombs', Path(__file__).with_name('check-test-time-bombs.py'))
TIME_BOMBS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TIME_BOMBS)


class ShiftTextTest(unittest.TestCase):
    def test_moves_every_date_form_back_and_keeps_the_time(self):
        self.assertEqual(TIME_BOMBS.shift_text('"2026-10-15T10:00:00Z" ~U[2026-11-01 09:00:00Z] ~D[2026-03-01]', 35),
                         '"2026-09-10T10:00:00Z" ~U[2026-09-27 09:00:00Z] ~D[2026-01-25]')

    def test_leaves_non_dates_alone(self):
        text = 'v2026-13-45 12026-10-15 2026-10-155 2026-02-30'
        self.assertEqual(TIME_BOMBS.shift_text(text, 35), text)


class SelectTest(unittest.TestCase):
    def test_runs_only_dated_tests_outside_the_fixed_date_list(self):
        src = TIME_BOMBS.ROOT / 'src'
        dated = [src / 'test/a_test.exs', src / 'test/aiur/codex/reset_time_test.exs', src / 'test/support/helper.ex']
        self.assertEqual(TIME_BOMBS.select([], dated), ['test/a_test.exs'])
        self.assertEqual(TIME_BOMBS.select(['test/b_test.exs', 'test/a_test.exs'], dated), ['test/a_test.exs'])

    def test_temporary_tree_keeps_undated_sibling_required_by_dated_test(self):
        source_test = TIME_BOMBS.ROOT / 'src/test/aiur/build_queue/events_test.exs'
        sibling = TIME_BOMBS.ROOT / 'src/test/support/build_queue_fake_tracker.ex'
        self.assertIn('Code.require_file("../../support/build_queue_fake_tracker.ex", __DIR__)',
                      source_test.read_text())
        self.assertIsNone(TIME_BOMBS.DATE.search(sibling.read_text()))
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / 'test'
            shutil.copytree(TIME_BOMBS.ROOT / 'src/test', destination)
            shifted = TIME_BOMBS.copy_test_tree(35, destination)
            self.assertIn(Path('test/aiur/build_queue/events_test.exs'), shifted)
            self.assertTrue((destination / 'support/build_queue_fake_tracker.ex').is_file())

    def test_guard_process_termination_leaves_source_tree_unchanged(self):
        root = TIME_BOMBS.ROOT
        tracked = TIME_BOMBS.tracked_test_files()
        before = {path: path.read_bytes() for path in tracked}
        with tempfile.TemporaryDirectory() as scratch:
            fake_mix = Path(scratch) / 'mix'
            marker = Path(scratch) / 'started'
            count_file = Path(scratch) / 'count'
            fake_mix.write_text(f'#!/usr/bin/env python3\nfrom pathlib import Path\nimport os, time\nPath({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n')
            fake_mix.chmod(0o755)
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('check-test-time-bombs.py')),
                                        'test/aiur_engine_pre_pr_test.exs'],
                                       env=dict(os.environ, PATH=f'{scratch}:{os.environ["PATH"]}', TMPDIR=scratch,
                                                AIUR_TIME_BOMB_COUNT_FILE=str(count_file)),
                                       # The runner reports its filtered file count before invoking mix.
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail('guard exited before entering the timed test command')
                    if any(path.read_bytes() != before[path] for path in tracked):
                        self.fail('guard rewrote a tracked test before running tests')
                    time.sleep(0.02)
                    # Fake mix creates this marker when the guard reaches the test command.
                    if marker.exists():
                        break
                else:
                    self.fail('guard did not enter the timed test command')
                self.assertEqual(count_file.read_text(), '1')
                process.kill()
                process.wait(timeout=5)
                os.kill(int(marker.read_text()), signal.SIGKILL)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
        self.assertEqual({path: path.read_bytes() for path in tracked}, before)


if __name__ == '__main__':
    unittest.main()
