#!/usr/bin/env python3
"""Exercise ci-soak.py selection and runners against a temp git repo and fake mix/node executables."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('ci-soak.py')
FAKE = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([os.getcwd(), *sys.argv[1:]]) + '\\n')
fail = os.environ.get('FAIL_ON', '')
sys.exit(1 if fail and fail in sys.argv[1:] else 0)
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
        for name in ('mix', 'node'):
            (bin_dir / name).write_text(FAKE)
            (bin_dir / name).chmod(0o755)
        self.browser = self.root / 'browser'
        self.browser.mkdir()
        (self.browser / 'package.json').write_text(json.dumps({'scripts': {
            'test:a': 'npm run fixture:preflight && node scripts/run-browser-tests.mjs tests/a.spec.mjs',
            'test:p': 'node scripts/run-browser-tests.mjs tests/p.spec.mjs --config playwright.design-parity.config.mjs',
        }}))
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', CALLS=str(self.calls),
                        AIUR_SOAK_BROWSER_ROOT=str(self.browser), GITHUB_STEP_SUMMARY=str(self.root / 'summary'))

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

    def test_browser_failure_fails_with_a_reproduce_command(self):
        result, calls = self.soak('browser', SOAK_SPECS='["tests/a.spec.mjs", "tests/p.spec.mjs"]', FAIL_ON='tests/a.spec.mjs')
        self.assertEqual((result.returncode, len(calls)), (1, 1))
        self.assertIn('Reproduce: cd src/browser && node scripts/run-browser-tests.mjs tests/a.spec.mjs --repeat-each=5',
                      result.stdout)

    def test_browser_reduces_repeats_above_the_spec_limit(self):
        specs = [f'tests/build-home-s{i}.browser.spec.mjs' for i in range(4)]
        _result, calls = self.soak('browser', SOAK_SPECS=json.dumps(specs))
        self.assertEqual({call[-1] for call in calls}, {'--repeat-each=2'})


if __name__ == '__main__':
    unittest.main()
