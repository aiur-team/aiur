#!/usr/bin/env python3
"""Run the existing selector's command without evaluating it as shell code."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

SELECTED_TEST_TIMEOUT_SECONDS = 600
TIME_BOMB_CHECK = os.environ.get('AIUR_TIME_BOMB_CHECK', str(Path(__file__).with_name('check-test-time-bombs.py')))


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


def main():
    selection_started = time.monotonic()
    selection = subprocess.check_output(['mix', 'aiur.affected_tests', sys.argv[1]], text=True)
    print(f'::notice::affected-tests selection duration: {time.monotonic() - selection_started:.1f}s',
          file=sys.stderr, flush=True)
    print(selection, flush=True)

    commands = [line for line in selection.splitlines() if line.startswith('cd src && mise exec -- ')]
    if not commands:
        if '# no affected test files detected' not in selection:
            raise ValueError('selector did not produce a supported command')
    else:
        if len(commands) != 1:
            raise ValueError('selector produced multiple commands')
        command = shlex.split(commands[0].removeprefix('cd src && mise exec -- '))
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
