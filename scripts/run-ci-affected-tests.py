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
TIME_BOMB_CHECK = os.environ.get('AIUR_TIME_BOMB_CHECK', str(Path(__file__).with_name('check-test-time-bombs.py')))
TIME_BOMB_TIMEOUT_SECONDS = float(os.environ.get('AIUR_TIME_BOMB_TIMEOUT_SECONDS',
                                                 str(SELECTED_TEST_TIMEOUT_SECONDS)))


def run_timed(label, command, **options):
    started = time.monotonic()
    try:
        return subprocess.run(command, check=True, **options)
    except subprocess.TimeoutExpired:
        timeout = options.get('timeout')
        print(f'::error::affected-tests {label} exceeded its {timeout}s timeout', file=sys.stderr, flush=True)
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
        ['git', 'diff', '--name-only', base, 'HEAD', '--', 'src/test'], text=True
    ).splitlines()
    return [path.removeprefix('src/') for path in paths if path.endswith('_test.exs')]


def run_merge_group_time_bombs(selected):
    started = time.monotonic()
    label = 'merge-group time-bomb rerun'
    timed_out = False
    failed = False
    with tempfile.TemporaryDirectory(prefix='aiur-time-bomb-count-') as temp_dir:
        count_file = Path(temp_dir) / 'count'
        child_env = dict(os.environ, AIUR_TIME_BOMB_COUNT_FILE=str(count_file))
        try:
            try:
                subprocess.run([sys.executable, TIME_BOMB_CHECK, *selected], check=True,
                               timeout=TIME_BOMB_TIMEOUT_SECONDS, env=child_env)
            except subprocess.TimeoutExpired:
                timed_out = True
            except subprocess.CalledProcessError:
                failed = True
                raise
        finally:
            elapsed = time.monotonic() - started
            file_count = count_file.read_text(encoding='utf-8') if count_file.exists() else 'unknown'
            report = f'{label}: {file_count} dated test files, {elapsed:.1f}s'
            if timed_out:
                report += f' (stopped at its {TIME_BOMB_TIMEOUT_SECONDS:g}s budget)'
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


def main():
    if os.environ.get('GITHUB_EVENT_NAME') == 'merge_group':
        paths = merge_group_changed_paths(sys.argv[1])
        os.environ['AIUR_CI_CHANGED_PATHS_B64'] = base64.b64encode(
            json.dumps(paths).encode('utf-8')
        ).decode('ascii')
    selection_started = time.monotonic()
    selection = subprocess.check_output(['mix', 'aiur.affected_tests', sys.argv[1]], text=True)
    print(f'::notice::affected-tests selection duration: {time.monotonic() - selection_started:.1f}s',
          file=sys.stderr, flush=True)
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
