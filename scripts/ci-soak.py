#!/usr/bin/env python3
"""Soak the tests a PR adds or modifies: repeat them with fresh seeds so a flake fails its own PR.

  ci-soak.py select <base>   print GitHub outputs for the files changed between <base> and HEAD
  ci-soak.py exunit          run SOAK_TESTS (JSON list, relative to src/) N times, one seed each
  ci-soak.py browser         run SOAK_SPECS (JSON list, relative to src/browser/) with --repeat-each

Keep selection, smoke discovery, and execution together because CI invokes this
standalone script from separate ExUnit and browser working directories.
"""
import json
import os
from pathlib import Path
import random
import re
import shlex
import socket
import subprocess
import sys
import time

EXUNIT_RUNS, EXUNIT_REDUCED_RUNS, EXUNIT_FULL_LIMIT, EXUNIT_MAX_FILES = 10, 3, 10, 40
# affected-tests uses 4; more concurrent cases surface shared-state and timing races sooner.
MAX_CASES = 8
SPEC_REPEATS, SPEC_REDUCED_REPEATS, SPEC_FULL_LIMIT, SPEC_MAX_FILES = 5, 2, 3, 10
RUN_TIMEOUT_SECONDS = 300
BROWSER_RUN_TIMEOUT_SECONDS = 20 * 60
MAX_BROWSER_TESTS_PER_SPEC = 200
BROWSER_LIST_TIMEOUT_SECONDS = 60
BUDGET_SECONDS = int(os.environ.get('AIUR_SOAK_BUDGET_SECONDS', str(12 * 60)))
BROWSER_ROOT = Path(os.environ.get('AIUR_SOAK_BROWSER_ROOT', Path(__file__).resolve().parent.parent / 'src/browser'))
DURATION_SOURCE = Path(__file__).resolve().parent.parent / 'src/browser/scripts/browser-smoke-durations.mjs'
RUN_TIMED_OUT = object()


def notice(message, level='notice'):
    print(f'::{level}::{message}', flush=True)
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        with open(summary_path, 'a', encoding='utf-8') as summary:
            summary.write(f'{message}\n')


def repeats(count, full, reduced, full_limit, max_files):
    """Full repeats for a small change, fewer above full_limit, none above max_files."""
    if count == 0 or count > max_files:
        return 0
    return full if count <= full_limit else reduced


def smoke_scripts(scripts):
    """Follow the same npm aliases as smoke, ignoring opt-in/full-only scripts."""
    pending = ['test:core', 'test:home-css']
    seen = set()
    while pending:
        name = pending.pop(0)
        if name in seen or name not in scripts:
            continue
        seen.add(name)
        command = scripts[name]
        yield name, command
        for segment in command.split('&&'):
            tokens = shlex.split(segment)
            if 'npm' in tokens:
                index = tokens.index('npm')
                if tokens[index + 1:index + 2] == ['run'] and len(tokens) > index + 2:
                    pending.append(tokens[index + 2])


def browser_invocations(spec, scripts):
    """Keep every smoke registration's filters/options, rather than just its first config."""
    invocations = []
    registered = False
    for _name, command in smoke_scripts(scripts):
        for segment in command.split('&&'):
            tokens = shlex.split(segment)
            runner = 'scripts/run-browser-tests.mjs'
            if runner not in tokens or spec not in tokens:
                continue
            registered = True
            index = tokens.index(runner)
            # Only soak the changed spec, retaining grep, config, worker and shard selections.
            args = [token for token in tokens[index + 1:]
                    if not (token.startswith('tests/') and token.endswith('.spec.mjs') and token != spec)]
            assignments = [token for token in tokens[:index - 1] if '=' in token]
            invocation = [*(['env', *assignments] if assignments else []), 'node', runner, *args]
            if invocation not in invocations:
                invocations.append(invocation)
    if registered:
        return invocations
    name = Path(spec).name
    # Mirrors browser-suites.mjs: only entirely unregistered home specs are discovered.
    mentioned = any(spec in shlex.split(segment) for command in scripts.values()
                    for segment in command.split('&&'))
    if (not mentioned and spec == f'tests/{name}' and name.startswith('build-home-')
            and name.endswith('.browser.spec.mjs')):
        config = ['--config', 'playwright.design-parity.config.mjs'] if name.endswith('-parity.browser.spec.mjs') else []
        return [['node', 'scripts/run-browser-tests.mjs', spec, *config]]
    return []


def browser_duration(spec, invocation, scripts, durations):
    """Return the recorded duration for this spec's matching smoke registration."""
    seconds = []
    runner = 'scripts/run-browser-tests.mjs'
    invocation_args = invocation[invocation.index(runner) + 1:]
    for script_name, command in smoke_scripts(scripts):
        for segment in command.split('&&'):
            tokens = shlex.split(segment)
            if runner not in tokens or spec not in tokens:
                continue
            args = tokens[tokens.index(runner) + 1:]
            args = [token for token in args
                    if not (token.startswith('tests/') and token.endswith('.spec.mjs') and token != spec)]
            if args == invocation_args and script_name in durations:
                seconds.append(durations[script_name])
    # A changed smoke spec without a matching recorded command is least known;
    # keep it first so its result is not consistently lost behind measured suites.
    return max(seconds, default=0)


def select(base):
    changed = subprocess.check_output(['git', 'diff', '--name-only', '--diff-filter=AMR', '-z', base, 'HEAD'], text=True)
    paths = [path for path in changed.split('\0') if path]
    tests = sorted(path.removeprefix('src/') for path in paths
                   if path.startswith('src/test/') and path.endswith('_test.exs'))
    specs = sorted(path.removeprefix('src/browser/') for path in paths
                   if path.startswith('src/browser/tests/') and path.endswith('.spec.mjs'))
    print(f'soak={str(bool(tests)).lower()}')
    print(f'soak_tests={json.dumps(tests)}')
    print(f'soak_browser={str(bool(specs)).lower()}')
    print(f'soak_specs={json.dumps(specs)}')
    print(f'soak selection: {len(tests)} ExUnit files, {len(specs)} Playwright specs', file=sys.stderr)


def load_list(name, prefix, suffix):
    files = json.loads(os.environ[name])
    if not isinstance(files, list) or not all(isinstance(f, str) and f.startswith(prefix) and f.endswith(suffix)
                                              and '..' not in f.split('/') for f in files):
        raise ValueError(f'{name} must be a JSON list of {prefix}*{suffix} paths')
    return files


def run(command, cwd=None, timeout=RUN_TIMEOUT_SECONDS):
    try:
        return subprocess.run(command, cwd=cwd, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        notice(f'soak run exceeded {timeout:.0f}s', 'error')
        return RUN_TIMED_OUT


def plan_runs(kind, count, full, reduced, full_limit, max_files):
    n = repeats(count, full, reduced, full_limit, max_files)
    if count > max_files:
        notice(f'{kind} soak skipped: {count} changed files > {max_files}; the merge-group full suite still runs them once')
    elif n and n < full:
        notice(f'{kind} soak reduced to {n} runs: {count} changed files > {full_limit}')
    return n


def soak_exunit():
    files = load_list('SOAK_TESTS', 'test/', '_test.exs')
    n = plan_runs('ExUnit', len(files), EXUNIT_RUNS, EXUNIT_REDUCED_RUNS, EXUNIT_FULL_LIMIT, EXUNIT_MAX_FILES)
    fixed = os.environ.get('AIUR_SOAK_SEEDS')
    seeds = [int(s) for s in fixed.split(',')][:n] if fixed else random.SystemRandom().sample(range(1, 1_000_000), n)
    started = time.monotonic()
    for index, seed in enumerate(seeds, 1):
        if time.monotonic() - started >= BUDGET_SECONDS:
            notice(f'ExUnit soak stopped at its {BUDGET_SECONDS}s budget after {index - 1}/{n} passing runs')
            break
        command = ['mix', 'test', '--seed', str(seed), '--max-cases', str(MAX_CASES), *files]
        print(f'::group::ExUnit soak run {index}/{n}: seed {seed}', flush=True)
        status = run(command)
        print('::endgroup::', flush=True)
        if status != 0:
            notice(f'ExUnit soak run {index}/{n} failed with seed {seed}. Reproduce: cd src && {shlex.join(command)}', 'error')
            return 1
    else:
        if n:
            notice(f'ExUnit soak: {n} runs passed for {len(files)} files in {time.monotonic() - started:.0f}s')
    return 0


def soak_browser():
    specs = load_list('SOAK_SPECS', 'tests/', '.spec.mjs')
    scripts = json.loads((BROWSER_ROOT / 'package.json').read_text())['scripts']
    duration_text = DURATION_SOURCE.read_text()
    duration_block = duration_text.split('export const recordedSeconds = {', 1)[1].split('\n}', 1)[0]
    durations = {}
    for line in duration_block.splitlines():
        match = re.match(r"\s*'([^']+)':\s*([\d.]+),?\s*$", line)
        if match:
            durations[match.group(1)] = float(match.group(2))
    invocations = {spec: browser_invocations(spec, scripts) for spec in specs}
    for spec, commands in invocations.items():
        if not commands:
            notice(f'Playwright soak skipped {spec}: the browser smoke suite does not run it')
    runnable = [spec for spec, commands in invocations.items() if commands]
    runnable.sort(key=lambda spec: max(
        (browser_duration(spec, invocation, scripts, durations) for invocation in invocations[spec]), default=0))
    n = plan_runs('Playwright', len(runnable), SPEC_REPEATS, SPEC_REDUCED_REPEATS, SPEC_FULL_LIMIT, SPEC_MAX_FILES)
    started = time.monotonic()
    completed = 0
    for spec in runnable if n else []:
        for invocation in invocations[spec]:
            elapsed = time.monotonic() - started
            if elapsed >= BUDGET_SECONDS:
                notice(f'Playwright soak stopped at its {BUDGET_SECONDS}s budget before {spec} after {completed} passing repeats')
                return 0
            listing_timeout = min(BROWSER_LIST_TIMEOUT_SECONDS, max(0.001, (BUDGET_SECONDS - elapsed) / 2))
            listed = browser_test_list(invocation, timeout=listing_timeout)
            elapsed = time.monotonic() - started
            remaining = BUDGET_SECONDS - elapsed
            if remaining <= 0:
                notice(f'Playwright soak stopped at its {BUDGET_SECONDS}s budget before {spec} after {completed} passing repeats')
                return 0
            if listed == []:
                notice(f'Playwright soak skipped {spec}: registration lists no tests')
                continue
            sampled = listed is not None and len(listed) > MAX_BROWSER_TESTS_PER_SPEC
            if listed is None:
                notice(f'Playwright soak could not count tests for {spec}; running this registration unsampled')
            estimated_seconds = browser_duration(spec, invocation, scripts, durations) * n
            if listed is not None and not sampled and estimated_seconds > remaining:
                notice(f'Playwright soak skipped {spec}: estimated {estimated_seconds:.0f}s exceeds {remaining:.0f}s remaining budget')
                continue
            commands = []
            if sampled:
                notice(f'Playwright soak sampled {spec}: {len(listed)} tests exceeds '
                       f'{MAX_BROWSER_TESTS_PER_SPEC}; rotating one listed test per repeat')
                sample_count = min(n, len(listed))
                sampled_titles = random.SystemRandom().sample(listed, sample_count)
                commands = [[*sample_grep(invocation, sampled_titles[index % sample_count]), '--repeat-each=1']
                            for index in range(n)]
            else:
                commands = [[*invocation, f'--repeat-each={n}']]
            for command in commands:
                elapsed = time.monotonic() - started
                if elapsed >= BUDGET_SECONDS:
                    notice(f'Playwright soak stopped at its {BUDGET_SECONDS}s budget before {spec} after {completed} passing repeats')
                    return 0
                print(f'::group::Playwright soak: {shlex.join(command)}', flush=True)
                timeout = max(1, BROWSER_RUN_TIMEOUT_SECONDS - elapsed)
                status = run_browser(command, spec, timeout)
                print('::endgroup::', flush=True)
                if status is RUN_TIMED_OUT:
                    notice(f'Playwright soak stopped at its runtime bound after {completed} passing repeats')
                    return 0
                if status != 0:
                    notice(f'Playwright soak failed for {spec}. Reproduce: cd src/browser && {shlex.join(command)}', 'error')
                    return 1
                completed += 1 if sampled else n
    if completed:
        notice(f'Playwright soak: {completed} repeats passed for {len(runnable)} specs')
    return 0

def browser_test_list(invocation, timeout=BROWSER_LIST_TIMEOUT_SECONDS):
    """List one smoke registration's actual Playwright tests and preserve its filters."""
    runner = invocation.index('scripts/run-browser-tests.mjs')
    args = invocation[runner + 1:]
    command = ['npx', 'playwright', 'test', *args, '--list', '--reporter=json']
    environment = os.environ.copy()
    if invocation[0] == 'env':
        for assignment in invocation[1:runner - 1]:
            key, value = assignment.split('=', 1)
            environment[key] = value
    with socket.socket() as port_socket:
        port_socket.bind(('127.0.0.1', 0))
        environment['AIUR_BROWSER_PORT'] = str(port_socket.getsockname()[1])
        try:
            result = subprocess.run(command, cwd=BROWSER_ROOT, capture_output=True, text=True,
                                    timeout=timeout, env=environment)
        except subprocess.TimeoutExpired:
            notice(f'Playwright soak could not list {args[0]} within {timeout:g}s; '
                   f'running this registration unsampled; command: {shlex.join(command)}')
            return None
    if result.returncode:
        notice(f'Playwright soak could not list {args[0]}; running this registration unsampled; '
               f'command: {shlex.join(command)}; {result.stderr.strip()}')
        return None
    try:
        return playwright_titles(json.loads(result.stdout))
    except (json.JSONDecodeError, TypeError, KeyError, AttributeError) as error:
        notice(f'Playwright soak received invalid test listing for {args[0]}; '
               f'running this registration unsampled; command: {shlex.join(command)} ({error})')
        return None


def playwright_titles(report):
    titles = []

    def visit(suite, parents=()):
        title = suite.get('title', '')
        parts = parents + ((title,) if title and not title.endswith('.spec.mjs') else ())
        titles.extend((parts + (test['title'],)) for test in suite.get('specs', []))
        for child in suite.get('suites', []):
            visit(child, parts)

    for suite in report.get('suites', []):
        visit(suite)
    return titles


def sample_grep(command, title_parts):
    """Add an escaped title filter while retaining a registration's existing grep."""
    runner = command.index('scripts/run-browser-tests.mjs')
    args = command[runner + 1:]
    pattern = '.*' + '.*'.join(re.escape(part) for part in title_parts) + '.*'
    for index, arg in enumerate(args):
        if arg in ('--grep', '-g') and index + 1 < len(args):
            args[index + 1] = f'(?=.*(?:{args[index + 1]}))(?=.*(?:{pattern})).*'
            return command[:runner + 1] + args
        if arg.startswith('--grep='):
            original = arg.split('=', 1)[1]
            args[index] = f'--grep=(?=.*(?:{original}))(?=.*(?:{pattern})).*'
            return command[:runner + 1] + args
    args.extend(['--grep', pattern])
    return command[:runner + 1] + args


def run_browser(command, spec, timeout):
    try:
        return subprocess.run(command, cwd=BROWSER_ROOT, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        notice(f'Playwright soak skipped: over budget: {spec}; command: {shlex.join(command)} '
               f'(timed out after {timeout:g}s)')
        return RUN_TIMED_OUT


def main(argv):
    if argv[:1] == ['select'] and len(argv) == 2:
        return select(argv[1]) or 0
    if argv == ['exunit']:
        return soak_exunit()
    if argv == ['browser']:
        return soak_browser()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
