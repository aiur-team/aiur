#!/usr/bin/env python3
"""Run the committed-head size, docs prose/table, and component gates."""
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
            [sys.executable, '-B', 'scripts/check-components.py', '--require-elixir'],
        ]
        failed = False
        for command in commands:
            result = subprocess.run(command, cwd=root, env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)))
            failed |= result.returncode != 0
        return int(failed)
    except (OSError, subprocess.SubprocessError) as error:
        print(f'structural gate: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
