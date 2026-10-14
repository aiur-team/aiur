#!/usr/bin/env python3
"""Run the existing selector's command without evaluating it as shell code."""
import shlex
import subprocess
import sys

selection = subprocess.check_output(['mix', 'aiur.affected_tests', sys.argv[1]], text=True)
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
        raise ValueError(f'unsafe affected selection requires full CI: {reason}')
    if command[:4] != ['mix', 'test', '--max-cases', '4']:
        raise ValueError('unsupported selector command')
    subprocess.run(command, check=True)
