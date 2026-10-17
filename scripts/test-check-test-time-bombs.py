#!/usr/bin/env python3
"""Pin the fixture-date shift used by check-test-time-bombs.py."""
import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()
