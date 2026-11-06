#!/usr/bin/env python3
"""Run the existing selector's command without evaluating it as shell code."""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

SELECTED_TEST_TIMEOUT_SECONDS = 600
MAX_CHANGED_TEST_MODULES = 8
# The enclosing `affected tests` job caps itself with `timeout-minutes`; a job
# killed by that cap reports nothing that separates it from a failing test
# (#7545). This module keeps its own phases inside the same cap so the cap is
# only reachable through an explicit, named timeout error below.
# `scripts/test-ci-events.mjs` pins this to the workflow's `timeout-minutes`.
JOB_TIMEOUT_MINUTES = 25
JOB_TIMEOUT_SECONDS = JOB_TIMEOUT_MINUTES * 60
# Checkout, toolchain setup and the architectural guards run before this script
# inside the same job; the slowest of the last 20 merge-group runs spent 215s
# there, so 300s of the cap stays reserved for them.
PRE_RUNNER_RESERVE_SECONDS = 300
JOB_BUDGET_SECONDS = JOB_TIMEOUT_SECONDS - PRE_RUNNER_RESERVE_SECONDS
JOB_STARTED_AT = time.monotonic()
TIME_BOMB_CHECK = os.environ.get('AIUR_TIME_BOMB_CHECK', str(Path(__file__).with_name('check-test-time-bombs.py')))
TIME_BOMB_TIMEOUT_SECONDS = float(os.environ.get('AIUR_TIME_BOMB_TIMEOUT_SECONDS',
                                                 str(SELECTED_TEST_TIMEOUT_SECONDS)))


def job_budget_remaining():
    """Return the seconds this step may still spend inside the job's timeout."""
    return JOB_BUDGET_SECONDS - (time.monotonic() - JOB_STARTED_AT)


def report_job_budget():
    print(f'::notice::affected-tests job budget: {JOB_BUDGET_SECONDS}s for this step inside the '
          f'{JOB_TIMEOUT_MINUTES}-minute job timeout, keeping {PRE_RUNNER_RESERVE_SECONDS}s for the '
          'checkout, toolchain setup and architectural guards that run before it',
          file=sys.stderr, flush=True)


def report_job_timeout(label):
    print(f'::error::affected-tests hit the job\'s {JOB_TIMEOUT_MINUTES}-minute timeout while '
          f'running {label}: the {JOB_BUDGET_SECONDS}s budget for this step is spent. A timeout '
          'ended this run, not a failing test.',
          file=sys.stderr, flush=True)


def run_timed(label, command, **options):
    started = time.monotonic()
    timeout = options.get('timeout')
    remaining = job_budget_remaining()
    if remaining <= 0:
        report_job_timeout(label)
        raise SystemExit(1)
    budget_bounded = timeout is not None and remaining < timeout
    if budget_bounded:
        options['timeout'] = remaining
    try:
        return subprocess.run(command, check=True, **options)
    except subprocess.TimeoutExpired:
        if budget_bounded:
            report_job_timeout(label)
        else:
            print(f'::error::affected-tests {label} exceeded its {timeout}s timeout',
                  file=sys.stderr, flush=True)
        raise
    finally:
        elapsed = time.monotonic() - started
        print(f'::notice::affected-tests {label} duration: {elapsed:.1f}s', file=sys.stderr, flush=True)


def run_selected_tests(command):
    return run_timed('selected tests', command, timeout=SELECTED_TEST_TIMEOUT_SECONDS)


def defer_to_merge_group(notice):
    print(f'::notice::{notice}', flush=True)
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        with open(summary_path, 'a', encoding='utf-8') as summary:
            summary.write(f'{notice}\n')


def changed_test_files(base):
    paths = subprocess.check_output(
        ['git', 'diff', '--name-only', base, 'HEAD', '--', 'test'], text=True
    ).splitlines()
    return [path.removeprefix('src/') for path in paths if path.endswith('_test.exs')]


def run_merge_group_time_bombs(selected):
    started = time.monotonic()
    label = 'merge-group time-bomb rerun'
    timed_out = False
    failed = False
    remaining = job_budget_remaining()
    if remaining <= 0:
        report_job_timeout(label)
        raise SystemExit(1)
    budget_bounded = remaining < TIME_BOMB_TIMEOUT_SECONDS
    timeout = remaining if budget_bounded else TIME_BOMB_TIMEOUT_SECONDS
    with tempfile.TemporaryDirectory(prefix='aiur-time-bomb-count-') as temp_dir:
        count_file = Path(temp_dir) / 'count'
        child_env = dict(os.environ, AIUR_TIME_BOMB_COUNT_FILE=str(count_file))
        try:
            try:
                subprocess.run([sys.executable, TIME_BOMB_CHECK, *selected], check=True,
                               timeout=timeout, env=child_env)
            except subprocess.TimeoutExpired:
                if budget_bounded:
                    report_job_timeout(label)
                    raise
                timed_out = True
            except subprocess.CalledProcessError:
                failed = True
                raise
        finally:
            elapsed = time.monotonic() - started
            file_count = count_file.read_text(encoding='utf-8') if count_file.exists() else 'unknown'
            report = f'{label}: {file_count} dated test files, {elapsed:.1f}s'
            if timed_out:
                report += f' (stopped at its {timeout:g}s budget)'
                print(f'::warning::affected-tests {report}', file=sys.stderr, flush=True)
            elif not failed:
                print(f'::notice::affected-tests {label} duration: {elapsed:.1f}s', file=sys.stderr, flush=True)
            summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
            if summary_path:
                with open(summary_path, 'a', encoding='utf-8') as summary:
                    summary.write(f'{report}\n')


def merge_group_changed_paths(base):
    """Return paths changed by this merge-group candidate vs its base."""
    return subprocess.check_output(
        ['git', 'diff', '--name-only', f'{base}...HEAD'], text=True
    ).splitlines()


def changed_test_modules(base):
    """Return added or modified ExUnit modules introduced by this PR."""
    changed = subprocess.check_output(
        ['git', 'diff', '--name-only', '--diff-filter=ACMRT', f'{base}...HEAD', '--', 'test'],
        text=True,
    ).splitlines()
    return sorted({
        path.removeprefix('src/')
        for path in changed
        if path.startswith('src/test/') and path.endswith('_test.exs')
    })


def run_changed_test_modules(base):
    modules = changed_test_modules(base)
    for path in modules[:MAX_CHANGED_TEST_MODULES]:
        run_timed(f'changed test module {path}',
                  ['mix', 'test', '--max-cases', '4', path],
                  timeout=SELECTED_TEST_TIMEOUT_SECONDS)
    skipped = modules[MAX_CHANGED_TEST_MODULES:]
    if skipped:
        print('::notice::changed-module isolation ran the first '
              f'{MAX_CHANGED_TEST_MODULES} of {len(modules)} modules; '
              'the grouped affected-tests run still covers skipped modules: '
              + ', '.join(skipped), flush=True)


def main():
    report_job_budget()
    if os.environ.get('GITHUB_EVENT_NAME') == 'merge_group':
        paths = merge_group_changed_paths(sys.argv[1])
        os.environ['AIUR_CI_CHANGED_PATHS_B64'] = base64.b64encode(
            json.dumps(paths).encode('utf-8')
        ).decode('ascii')
    run_changed_test_modules(sys.argv[1])

    selection = run_timed('selection', ['mix', 'aiur.affected_tests', sys.argv[1]],
                          timeout=SELECTED_TEST_TIMEOUT_SECONDS,
                          stdout=subprocess.PIPE, text=True).stdout
    print(selection, flush=True)

    commands = [line for line in selection.splitlines() if line.startswith('cd src && mise exec -- ')]
    if not commands:
        if '# no affected test files detected' not in selection:
            raise ValueError('selector did not produce a supported command')
        if os.environ.get('GITHUB_EVENT_NAME') == 'merge_group':
            print('::notice::merge-group time-bomb guard has no selected tests', flush=True)
        return
    else:
        if len(commands) != 1:
            raise ValueError('selector produced multiple commands')
        command = shlex.split(commands[0].removeprefix('cd src && mise exec -- '))
        if os.environ.get('GITHUB_EVENT_NAME') == 'merge_group':
            selected = changed_test_files(sys.argv[1])
            if selected:
                run_merge_group_time_bombs(selected)
            else:
                print('::notice::merge-group time-bomb guard has no changed test files', flush=True)
            return
        if command == ['make', 'ci']:
            reason = next((line.removeprefix('# full suite recommended: ')
                           for line in selection.splitlines()
                           if line.startswith('# full suite recommended: ')), 'unknown')
            defer_to_merge_group(f'Unsafe affected selection deferred to full CI in the merge queue: {reason}')
        elif command[:4] != ['mix', 'test', '--max-cases', '4']:
            raise ValueError('unsupported selector command')
        else:
            selected_count = len(command[4:])
            if selected_count > 300:
                notice = f'selection {selected_count} files > 300; covered by the merge_group full suite'
                defer_to_merge_group(notice)
            else:
                run_selected_tests(command)
                run_timed('time-bomb rerun', [sys.executable, TIME_BOMB_CHECK, *command[4:]],
                          timeout=SELECTED_TEST_TIMEOUT_SECONDS)


if __name__ == '__main__':
    main()
