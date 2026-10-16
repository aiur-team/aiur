#!/usr/bin/env python3
"""Run the existing selector's command without evaluating it as shell code."""
import os
import shlex
import selectors
import signal
import subprocess
import sys
import time

SELECTOR_TIMEOUT_SECONDS = int(os.environ.get('AIUR_CI_SELECTOR_TIMEOUT_SECONDS', 8 * 60))


def run_selector(base):
    selector_env = os.environ.copy()
    selector_env["AIUR_CI_SELECTOR_DIAGNOSTICS"] = "1"
    process = subprocess.Popen(
        ['mix', 'aiur.affected_tests', base],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=selector_env,
    )
    output = bytearray()
    deadline = time.monotonic() + SELECTOR_TIMEOUT_SECONDS
    selector_timed_out = False
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                selector_timed_out = True
                break
            if not selector.select(remaining):
                if time.monotonic() >= deadline:
                    selector_timed_out = True
                    break
                continue
            chunk = os.read(process.stdout.fileno(), 8192)
            if chunk:
                output.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            else:
                selector.unregister(process.stdout)

    timed_out = selector_timed_out or (time.monotonic() >= deadline and process.poll() is None)
    if not timed_out and process.poll() is None:
        try:
            process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True

    if timed_out:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        # The group can outlive its leader (for example, a child that ignores
        # SIGTERM), so check and kill the group independently before returning.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process.poll() is None:
            process.wait()
        process.stdout.close()
        raise TimeoutError(
            f'affected-test selector exceeded {SELECTOR_TIMEOUT_SECONDS}s; '
            'see the last selector stage above'
        )

    process.stdout.close()
    selection = output.decode(errors='replace')
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, process.args)
    # Preserve the legacy blank line after the selector output.
    print(flush=True)
    return selection


selection = run_selector(sys.argv[1])


def defer_to_merge_group(notice):
    print(f'::notice::{notice}', flush=True)
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        with open(summary_path, 'a', encoding='utf-8') as summary:
            summary.write(f'{notice}\n')


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
            subprocess.run(command, check=True)
