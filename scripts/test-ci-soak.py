#!/usr/bin/env python3
"""Exercise ci-soak.py selection and runners against a temp git repo and fake mix/node executables."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('ci-soak.py')
FAKE = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([os.getcwd(), *sys.argv[1:]]) + '\\n')
fail = os.environ.get('FAIL_ON', '')
if '--list' not in sys.argv and os.environ.get('TIMEOUT_ON') and any(
        os.environ['TIMEOUT_ON'] in arg for arg in sys.argv[1:]):
    import time
    time.sleep(1)
sys.exit(1 if fail and fail in sys.argv[1:] else 0)
'''

FAKE_NPX = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['LIST_CALLS'], 'a') as out:
    out.write(json.dumps([os.getcwd(), *sys.argv[1:]]) + '\\n')
if os.environ.get('LIST_TIMEOUT_ON'):
    import time
    time.sleep(1)
count = int(os.environ.get('PLAYWRIGHT_LIST_COUNT', '1'))
title = os.environ.get('PLAYWRIGHT_LIST_TITLE', 'sample title')
print(json.dumps({'suites': [{'specs': [{'title': f'{title} {i}' if count > 1 else title} for i in range(count)]}]}))
'''


def git(root, *args):
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                   check=True, capture_output=True)


class SoakTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.root = Path(self.scratch.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name, content in (('mix', FAKE), ('node', FAKE), ('npx', FAKE_NPX)):
            (bin_dir / name).write_text(content)
            (bin_dir / name).chmod(0o755)
        self.browser = self.root / 'browser'
        self.browser.mkdir()
        (self.browser / 'package.json').write_text(json.dumps({'scripts': {
            'test:core': 'npm run test:a && npm run test:p',
            'test:a': 'npm run fixture:preflight && node scripts/run-browser-tests.mjs tests/a.spec.mjs',
            'test:p': 'node scripts/run-browser-tests.mjs tests/p.spec.mjs --config playwright.design-parity.config.mjs',
        }}))
        self.calls = self.root / 'calls'
        self.list_calls = self.root / 'list_calls'
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', CALLS=str(self.calls),
                        LIST_CALLS=str(self.list_calls), PLAYWRIGHT_LIST_TITLE='sample title',
                        AIUR_SOAK_BROWSER_ROOT=str(self.browser),
                        GITHUB_STEP_SUMMARY=str(self.root / 'summary'))

    def tearDown(self):
        self.scratch.cleanup()

    def soak(self, *args, cwd=None, **env):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd, capture_output=True, text=True,
                                env=dict(self.env, **env))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def test_select_lists_only_added_or_modified_exunit_files_and_specs(self):
        repo = self.root / 'repo'
        for path in ('src/test/kept_test.exs', 'src/test/edited_test.exs', 'src/test/gone_test.exs',
                     'src/browser/tests/edited.spec.mjs', 'src/lib/code.ex'):
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text('old\n')
        git(repo, 'init', '-q')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'base')
        for path in ('src/test/edited_test.exs', 'src/browser/tests/edited.spec.mjs', 'src/lib/code.ex'):
            (repo / path).write_text('new\n')
        (repo / 'src/test/support').mkdir()
        (repo / 'src/test/support/helper.ex').write_text('new\n')
        (repo / 'src/test/added_test.exs').write_text('new\n')
        (repo / 'src/test/gone_test.exs').unlink()
        git(repo, 'add', '-A')
        git(repo, 'commit', '-qm', 'pr')
        result, _ = self.soak('select', 'HEAD^1', cwd=repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'soak=true', 'soak_tests=["test/added_test.exs", "test/edited_test.exs"]',
            'soak_browser=true', 'soak_specs=["tests/edited.spec.mjs"]'])

    def test_select_without_changed_tests_selects_nothing(self):
        repo = self.root / 'repo'
        (repo / 'src/lib').mkdir(parents=True)
        (repo / 'src/lib/code.ex').write_text('old\n')
        git(repo, 'init', '-q')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'base')
        (repo / 'src/lib/code.ex').write_text('new\n')
        git(repo, 'commit', '-qam', 'pr')
        result, _ = self.soak('select', 'HEAD^1', cwd=repo)
        self.assertEqual(result.stdout.splitlines(), ['soak=false', 'soak_tests=[]', 'soak_browser=false', 'soak_specs=[]'])

    def test_exunit_runs_ten_separate_invocations_with_distinct_seeds(self):
        files = ['test/a_test.exs', 'test/b_test.exs']
        result, calls = self.soak('exunit', SOAK_TESTS=json.dumps(files))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 10)
        seeds = [call[call.index('--seed') + 1] for call in calls]
        self.assertEqual(len(set(seeds)), 10)
        for call in calls:
            self.assertEqual(call[1:3], ['test', '--seed'])
            self.assertEqual(call[4:], ['--max-cases', '8', *files])
        self.assertIn('ExUnit soak: 10 runs passed for 2 files', result.stdout)

    def test_exunit_failure_names_the_seed_and_stops(self):
        result, calls = self.soak('exunit', SOAK_TESTS='["test/a_test.exs"]', AIUR_SOAK_SEEDS='11,22,33', FAIL_ON='22')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([call[3] for call in calls], ['11', '22'])
        self.assertIn('::error::ExUnit soak run 2/10 failed with seed 22. Reproduce: cd src && '
                      'mix test --seed 22 --max-cases 8 test/a_test.exs', result.stdout)

    def test_exunit_reduces_runs_above_the_file_limit_and_skips_above_the_cap(self):
        many = [f'test/t{i}_test.exs' for i in range(11)]
        result, calls = self.soak('exunit', SOAK_TESTS=json.dumps(many))
        self.assertEqual((result.returncode, len(calls)), (0, 3))
        self.assertIn('ExUnit soak reduced to 3 runs: 11 changed files > 10', result.stdout)
        self.calls.unlink()
        result, calls = self.soak('exunit', SOAK_TESTS=json.dumps([f'test/t{i}_test.exs' for i in range(41)]))
        self.assertEqual((result.returncode, calls), (0, []))
        self.assertIn('ExUnit soak skipped: 41 changed files > 40', result.stdout)

    def test_exunit_stops_at_its_time_budget(self):
        result, calls = self.soak('exunit', SOAK_TESTS='["test/a_test.exs"]', AIUR_SOAK_BUDGET_SECONDS='0')
        self.assertEqual((result.returncode, calls), (0, []))
        self.assertIn('stopped at its 0s budget after 0/10 passing runs', result.stdout)

    def test_exunit_rejects_paths_outside_the_test_tree(self):
        for bad in ('["--include=slow_test.exs"]', '["test/../lib/x_test.exs"]', '"test/a_test.exs"'):
            result, calls = self.soak('exunit', SOAK_TESTS=bad)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])

    def test_browser_repeats_each_spec_with_its_smoke_config(self):
        specs = ['tests/a.spec.mjs', 'tests/p.spec.mjs', 'tests/build-home-x-parity.browser.spec.mjs',
                 'tests/failure-evidence.spec.mjs']
        result, calls = self.soak('browser', SOAK_SPECS=json.dumps(specs))
        self.assertEqual(result.returncode, 0, result.stderr)
        # Three runnable specs is within the full-repeat limit; the unrun fixture spec is skipped, not soaked.
        self.assertEqual(calls, [
            [str(self.browser), 'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs', '--repeat-each=5'],
            [str(self.browser), 'scripts/run-browser-tests.mjs', 'tests/p.spec.mjs',
             '--config', 'playwright.design-parity.config.mjs', '--repeat-each=5'],
            [str(self.browser), 'scripts/run-browser-tests.mjs', 'tests/build-home-x-parity.browser.spec.mjs',
             '--config', 'playwright.design-parity.config.mjs', '--repeat-each=5']])
        self.assertIn('Playwright soak skipped tests/failure-evidence.spec.mjs', result.stdout)

    def test_browser_keeps_every_smoke_selection_and_deduplicates_aliases(self):
        spec = 'tests/shared.spec.mjs'
        commands = {
            'test:core': 'npm run test:columns && npm run test:motion && npm run test:band && npm run test:duplicate',
            'test:columns': f'TZ=America/Los_Angeles node scripts/run-browser-tests.mjs {spec} tests/other.spec.mjs '
                            '--config parity.mjs --grep "columns[.]"',
            'test:motion': f'node scripts/run-browser-tests.mjs {spec} --config routine.mjs',
            'test:band': f'node scripts/run-browser-tests.mjs {spec} --config band.mjs '
                         '--grep "mobile snap" --fully-parallel --workers=2 --shard=1/4',
            'test:duplicate': f'node scripts/run-browser-tests.mjs {spec} --config routine.mjs',
            'test:full': f'node scripts/run-browser-tests.mjs {spec} --config full.mjs',
        }
        (self.browser / 'package.json').write_text(json.dumps({'scripts': commands}))
        result, calls = self.soak('browser', SOAK_SPECS=json.dumps([spec]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[2:] for call in calls], [
            [spec, '--config', 'parity.mjs', '--grep', 'columns[.]', '--repeat-each=5'],
            [spec, '--config', 'routine.mjs', '--repeat-each=5'],
            [spec, '--config', 'band.mjs', '--grep', 'mobile snap', '--fully-parallel',
             '--workers=2', '--shard=1/4', '--repeat-each=5']])
        # A failure in a later registration must fail the soak, too.
        self.calls.unlink()
        result, calls = self.soak('browser', SOAK_SPECS=json.dumps([spec]), FAIL_ON='band.mjs')
        self.assertEqual((result.returncode, len(calls)), (1, 3))
        self.assertIn('--grep \'mobile snap\' --fully-parallel --workers=2 --shard=1/4', result.stdout)

    def test_browser_does_not_discover_an_opt_in_only_registered_home_spec(self):
        (self.browser / 'package.json').write_text(json.dumps({'scripts': {
            'test:core': 'node --test scripts/unit.test.mjs',
            'test:home:full': 'node scripts/run-browser-tests.mjs tests/build-home-full.browser.spec.mjs'
        }}))
        result, calls = self.soak('browser', SOAK_SPECS='["tests/build-home-full.browser.spec.mjs"]')
        self.assertEqual((result.returncode, calls), (0, []))
        self.assertIn('browser smoke suite does not run it', result.stdout)

    def test_browser_budget_stops_between_bounded_routine_invocations(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        with patch.dict(os.environ, self.env | {'SOAK_SPECS': '["tests/a.spec.mjs", "tests/p.spec.mjs"]'}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module, 'BUDGET_SECONDS', 720), \
                patch.object(module.time, 'monotonic', side_effect=[0, 0, 0, 721]), \
                patch.object(module, 'run_browser', return_value=0) as runner, \
                patch.object(module, 'notice') as notices:
            self.assertEqual(module.soak_browser(), 0)
        runner.assert_called_once_with(
            ['node', 'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs', '--repeat-each=5'],
            'tests/a.spec.mjs', False, 1, 300)
        notices.assert_called_once_with('Playwright soak stopped at its 720s budget before tests/p.spec.mjs after 5 passing repeats')

    def test_later_invocation_cannot_exceed_the_browser_job_runtime_bound(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        with patch.dict(os.environ, self.env | {'SOAK_SPECS': '["tests/a.spec.mjs", "tests/p.spec.mjs"]'}), \
                patch.object(module, 'BROWSER_ROOT', self.browser), \
                patch.object(module.time, 'monotonic', side_effect=[0, 0, 0, 700, 700]), \
                patch.object(module, 'run_browser', return_value=0) as runner:
            self.assertEqual(module.soak_browser(), 0)
        self.assertEqual([call.args[4] for call in runner.call_args_list], [300, 300])

    def test_browser_timeout_fails_instead_of_claiming_a_pass(self):
        loader = importlib.util.spec_from_file_location('ci_soak', SCRIPT)
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        command = ['node', 'scripts/run-browser-tests.mjs', 'tests/a.spec.mjs']
        with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired(command, 1200)), \
                patch.object(module, 'notice') as notices:
            self.assertEqual(module.run(command, timeout=1200), 124)
        notices.assert_called_once_with(
            'soak run timed out after 1200s: node scripts/run-browser-tests.mjs tests/a.spec.mjs', 'error')

    def test_browser_budget_timeout_stops_successfully_after_completed_repeats(self):
        result, calls = self.soak('browser', SOAK_SPECS='["tests/a.spec.mjs"]', AIUR_SOAK_BUDGET_SECONDS='0')
        self.assertEqual((result.returncode, calls), (0, []))
        self.assertIn('Playwright soak stopped at its 0s budget before tests/a.spec.mjs after 0 passing repeats', result.stdout)

    def test_browser_failure_fails_with_a_reproduce_command(self):
        result, calls = self.soak('browser', SOAK_SPECS='["tests/a.spec.mjs", "tests/p.spec.mjs"]', FAIL_ON='tests/a.spec.mjs')
        self.assertEqual((result.returncode, len(calls)), (1, 1))
        self.assertIn('Reproduce: cd src/browser && node scripts/run-browser-tests.mjs tests/a.spec.mjs --repeat-each=5',
                      result.stdout)

    def test_browser_reduces_repeats_above_the_spec_limit(self):
        specs = [f'tests/build-home-s{i}.browser.spec.mjs' for i in range(4)]
        _result, calls = self.soak('browser', SOAK_SPECS=json.dumps(specs))
        self.assertEqual({call[-1] for call in calls}, {'--repeat-each=2'})

    def test_browser_samples_spec_with_more_than_two_thousand_generated_tests(self):
        spec = self.browser / 'tests/build-home-motion.browser.spec.mjs'
        spec.parent.mkdir(parents=True)
        spec.write_text("import { test } from '@playwright/test';\nfor (const cell of Array.from({length: 2338}, (_, index) => index)) {\n  test.describe(`cell ${cell}`, () => test(`motion [cell]+ ${cell}`, async () => {}));\n}\n")
        result, calls = self.soak('browser', SOAK_SPECS='["tests/build-home-motion.browser.spec.mjs"]', PLAYWRIGHT_LIST_COUNT='2338', PLAYWRIGHT_LIST_TITLE='motion [cell]+')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1:], ['scripts/run-browser-tests.mjs', 'tests/build-home-motion.browser.spec.mjs',
                                       '--grep', '.*' + re.escape('motion [cell]+ 0') + '.*', '--repeat-each=5'])
        self.assertIn('test(`motion [cell]+ ${cell}`', spec.read_text())
        self.assertIn('soak sampled tests/build-home-motion.browser.spec.mjs: 2338 tests exceeds 200', result.stdout)
        listed = json.loads(self.list_calls.read_text().splitlines()[0])
        self.assertEqual(listed[1:], ['playwright', 'test', 'tests/build-home-motion.browser.spec.mjs',
                                      '--list', '--reporter=json'])

    def test_exunit_timeout_still_fails_with_error_and_command(self):
        result, calls = self.soak('exunit', SOAK_TESTS='["test/a_test.exs"]',
                                  AIUR_SOAK_BUDGET_SECONDS='600', TIMEOUT_ON='--seed',
                                  AIUR_SOAK_TEST_TIMEOUT='0.05', AIUR_SOAK_SEEDS='11')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('::error::soak run timed out after 0.05s: mix test --seed 11', result.stdout)

    def test_browser_timeout_of_small_spec_fails_as_suspected_hang(self):
        result, calls = self.soak('browser', SOAK_SPECS='["tests/a.spec.mjs"]',
                                  TIMEOUT_ON='tests/a.spec.mjs', AIUR_SOAK_TEST_TIMEOUT='0.05')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('::error::Playwright suspected hang: tests/a.spec.mjs; command:', result.stdout)
        self.assertIn('node scripts/run-browser-tests.mjs tests/a.spec.mjs --repeat-each=5', result.stdout)

    def test_sample_timeout_fails_as_suspected_hang(self):
        result, calls = self.soak(
            'browser', SOAK_SPECS='["tests/build-home-motion.browser.spec.mjs"]',
            PLAYWRIGHT_LIST_COUNT='201', TIMEOUT_ON='tests/build-home-motion.browser.spec.mjs',
            AIUR_SOAK_TEST_TIMEOUT='0.05')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('::error::Playwright suspected hang:', result.stdout)
        self.assertIn('node scripts/run-browser-tests.mjs tests/build-home-motion.browser.spec.mjs --grep',
                      result.stdout)

    def test_timeout_at_exact_sample_limit_fails_as_suspected_hang(self):
        result, calls = self.soak(
            'browser', SOAK_SPECS='["tests/a.spec.mjs"]',
            PLAYWRIGHT_LIST_COUNT='200', TIMEOUT_ON='tests/a.spec.mjs',
            AIUR_SOAK_TEST_TIMEOUT='0.05')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('::error::Playwright suspected hang: tests/a.spec.mjs; command:', result.stdout)

    def test_browser_listing_timeout_fails_instead_of_reporting_no_tests(self):
        result, calls = self.soak(
            'browser', SOAK_SPECS='["tests/a.spec.mjs"]',
            LIST_TIMEOUT_ON='1', AIUR_SOAK_LIST_TIMEOUT='0.05')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('::error::Playwright test listing timed out for tests/a.spec.mjs; command:', result.stdout)
        self.assertNotIn('registration lists no tests', result.stdout)

if __name__ == '__main__':
    unittest.main()
