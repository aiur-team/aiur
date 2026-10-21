#!/usr/bin/env python3
"""Browser soak regressions for sampling, listing fallback, and budget behavior."""
import importlib.util
import json
import os
from pathlib import Path
import re
import unittest
from unittest.mock import patch

BASE_TEST = Path(__file__).with_name('test-ci-soak.py')
ns = {'__file__': str(BASE_TEST), '__name__': 'ci_soak_test_support'}
exec(compile(BASE_TEST.read_text(), str(BASE_TEST), 'exec'), ns)
SoakTest = ns['SoakTest']
BASE_SETUP = SoakTest.setUp
BASE_TEARDOWN = SoakTest.tearDown
BASE_SOAK = SoakTest.soak
SCRIPT = Path(__file__).with_name('ci-soak.py')


class BrowserSamplingTest(unittest.TestCase):
    """Reuse the shared fake-runner fixture without duplicating its tests."""

    setUp = BASE_SETUP
    tearDown = BASE_TEARDOWN
    soak = BASE_SOAK

    def test_browser_samples_large_spec_and_rotates_within_budget(self):
        spec = self.browser / 'tests/build-home-motion.browser.spec.mjs'
        spec.parent.mkdir(parents=True)
        spec.write_text("import { test } from '@playwright/test';\nfor (const cell of Array.from({length: 2338}, (_, index) => index)) {\n  test.describe(`cell ${cell}`, () => test(`motion [cell]+ ${cell}`, async () => {}));\n}\n")
        (self.browser / 'package.json').write_text(json.dumps({'scripts': {
            'test:core': 'npm run test:motion',
            'test:motion': 'node scripts/run-browser-tests.mjs tests/build-home-motion.browser.spec.mjs',
        }}))
        self.durations.write_text("export const recordedSeconds = {\n  'test:motion': 1000,\n}\n")
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        invocation = ['node', 'scripts/run-browser-tests.mjs', 'tests/build-home-motion.browser.spec.mjs']
        fake_clock = [0]

        with patch.dict(os.environ, self.env | {
                'PLAYWRIGHT_LIST_COUNT': '2338', 'PLAYWRIGHT_LIST_TITLE': 'motion [cell]+'}):
            listed = module.browser_test_list(invocation)
        fake_clock[0] = 0

        def pass_sample(_command, _spec, _timeout):
            fake_clock[0] += 1
            return 0

        class SelectMiddle:
            def sample(self, population, count):
                return population[10:10 + count]

        with patch.dict(os.environ, self.env | {
                'SOAK_SPECS': '["tests/build-home-motion.browser.spec.mjs"]',
                'PLAYWRIGHT_LIST_COUNT': '2338', 'PLAYWRIGHT_LIST_TITLE': 'motion [cell]+'}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module, 'DURATION_SOURCE', self.durations), \
                patch.object(module, 'BUDGET_SECONDS', 60), \
                patch.object(module.time, 'monotonic', side_effect=lambda: fake_clock[0]), \
                patch.object(module, 'browser_test_list', return_value=listed), \
                patch.object(module.random, 'SystemRandom', return_value=SelectMiddle()), \
                patch.object(module, 'run_browser', side_effect=pass_sample) as runner, \
                patch.object(module, 'notice') as notices:
            result = module.soak_browser()
        self.assertEqual(result, 0)
        self.assertEqual(len(runner.call_args_list), 5)
        self.assertEqual([call.args[0][-1] for call in runner.call_args_list], ['--repeat-each=1'] * 5)
        self.assertEqual([call.args[0][call.args[0].index('--grep') + 1]
                          for call in runner.call_args_list], [
                              '.*' + re.escape(f'motion [cell]+ {index}') + '.*'
                              for index in range(10, 15)])
        self.assertEqual(fake_clock[0], 5)
        self.assertLessEqual(fake_clock[0], 60)
        notices.assert_any_call('Playwright soak: 5 repeats passed for 1 specs')
        self.assertIn('test(`motion [cell]+ ${cell}`', spec.read_text())
        self.assertTrue(any(1 <= int(json.loads(line)[1]) <= 65535
                            for line in self.list_calls.read_text().splitlines()))

    def test_unlistable_registration_runs_unsampled(self):
        for failure in ({'LIST_FAIL': '1'}, {'LIST_INVALID': '1'}):
            self.calls.unlink(missing_ok=True)
            result, calls = self.soak('browser', SOAK_SPECS='["tests/a.spec.mjs"]', **failure)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][1:], [
                'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs', '--repeat-each=5'])
            self.assertIn('running this registration unsampled', result.stdout)
            self.assertNotIn('::error::', result.stdout)

    def test_listing_timeout_falls_back_to_unsampled_run(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        with patch.dict(os.environ, self.env | {
                'SOAK_SPECS': '["tests/a.spec.mjs"]', 'LIST_TIMEOUT_ON': '1'}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module, 'DURATION_SOURCE', self.durations), \
                patch.object(module, 'BUDGET_SECONDS', 60), \
                patch.object(module, 'BROWSER_LIST_TIMEOUT_SECONDS', 0.01), \
                patch.object(module, 'run_browser', return_value=0) as runner, \
                patch.object(module, 'notice') as notices:
            self.assertEqual(module.soak_browser(), 0)
        self.assertEqual(runner.call_args.args[0],
                         ['node', 'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs', '--repeat-each=5'])
        self.assertEqual(runner.call_args.args[1], 'tests/a.spec.mjs')
        self.assertAlmostEqual(runner.call_args.args[2], 1200, delta=1)
        self.assertTrue(any('running this registration unsampled' in call.args[0]
                            for call in notices.call_args_list))

    def test_listing_time_counts_toward_the_soak_budget(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        fake_clock = [0]

        def list_after_elapsed(_invocation, timeout=None):
            self.assertEqual(timeout, 30)
            fake_clock[0] += 30
            return [('sample title',)]

        with patch.dict(os.environ, self.env | {'SOAK_SPECS': '["tests/a.spec.mjs"]'}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module, 'DURATION_SOURCE', self.durations), \
                patch.object(module, 'BUDGET_SECONDS', 60), \
                patch.object(module.time, 'monotonic', side_effect=lambda: fake_clock[0]), \
                patch.object(module, 'browser_test_list', side_effect=list_after_elapsed), \
                patch.object(module, 'run_browser') as runner, \
                patch.object(module, 'notice') as notices:
            self.assertEqual(module.soak_browser(), 0)
        runner.assert_not_called()
        notices.assert_any_call('Playwright soak skipped tests/a.spec.mjs: estimated 50s exceeds 30s remaining budget')

    def test_sampling_one_registration_does_not_bypass_another_budget_estimate(self):
        spec = 'tests/shared.spec.mjs'
        (self.browser / 'package.json').write_text(json.dumps({'scripts': {
            'test:core': 'npm run test:sampled && npm run test:expensive',
            'test:sampled': f'node scripts/run-browser-tests.mjs {spec} --config sampled.mjs --grep sampled',
            'test:expensive': f'node scripts/run-browser-tests.mjs {spec} --config expensive.mjs --grep expensive',
        }}))
        self.durations.write_text("export const recordedSeconds = {\n  'test:sampled': 1,\n  'test:expensive': 100,\n}\n")
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        fake_clock = [0]

        def list_by_config(invocation, timeout=None):
            count = 201 if 'sampled.mjs' in invocation else 1
            return [(f'title {index}',) for index in range(count)]

        with patch.dict(os.environ, self.env | {'SOAK_SPECS': json.dumps([spec])}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module, 'DURATION_SOURCE', self.durations), \
                patch.object(module, 'BUDGET_SECONDS', 60), \
                patch.object(module.time, 'monotonic', side_effect=lambda: fake_clock[0]), \
                patch.object(module, 'browser_test_list', side_effect=list_by_config), \
                patch.object(module.random, 'SystemRandom', return_value=type('Sample', (), {
                    'sample': lambda _self, population, count: population[:count]})()), \
                patch.object(module, 'run_browser', return_value=0) as runner, \
                patch.object(module, 'notice') as notices:
            self.assertEqual(module.soak_browser(), 0)
        self.assertEqual(len(runner.call_args_list), 5)
        self.assertTrue(all('sampled.mjs' in call.args[0] for call in runner.call_args_list))
        notices.assert_any_call(
            'Playwright soak skipped tests/shared.spec.mjs: estimated 500s exceeds 60s remaining budget')

    def test_sample_grep_conjoins_filters_that_match_after_the_title_start(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        cases = (
            (['--grep', 'columns[.]'], 'prefix product interactions show columns.cell update'),
            (['--grep=columns[.]'], 'prefix product interactions show columns.cell update'),
            (['--grep', '^prefix'], 'prefix product interactions. show columns.cell update'),
            (['--grep=^prefix'], 'prefix product interactions. show columns.cell update'),
        )
        for grep_args, title in cases:
            command = ['node', 'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs']
            command.extend(grep_args)
            sampled = module.sample_grep(command, ('product interactions', 'columns.cell'))
            pattern = sampled[sampled.index('--grep') + 1] if '--grep' in sampled else next(
                arg.removeprefix('--grep=') for arg in sampled if arg.startswith('--grep='))
            self.assertRegex(title, pattern)
            self.assertNotRegex(title.replace('columns.cell', 'rows.cell'), pattern)

if __name__ == "__main__":
    unittest.main()
