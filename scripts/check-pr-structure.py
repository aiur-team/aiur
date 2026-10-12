#!/usr/bin/env python3
"""Run the cheap committed-head gates CI enforces: size, docs prose/table, components,
bare receives, format and the state-writer allowlist."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, help='authoritative integration branch commit')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'])
        if dirty:
            print('structural gate: commit all changes before running', file=sys.stderr)
            return 1
        commands = [
            [sys.executable, 'scripts/check-file-size.py', '--base', args.base],
            ['node', 'scripts/check-docs-prose.mjs'],
            [sys.executable, '-B', 'scripts/check-components.py', '--require-elixir', '--growth-base', args.base],
            [sys.executable, 'scripts/check-bare-assert-receive.py'],
            ['mix', 'format', '--check-formatted'],
            ['mix', 'test', '--max-cases', '4', 'test/aiur/orchestrator/state_owners_test.exs'],
        ]
        failed = False
        for command in commands:
            cwd = root / 'src' if command[0] == 'mix' else root
            result = subprocess.run(command, cwd=cwd, env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)))
            failed |= result.returncode != 0
        return int(failed)
    except (OSError, subprocess.SubprocessError) as error:
        print(f'structural gate: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
