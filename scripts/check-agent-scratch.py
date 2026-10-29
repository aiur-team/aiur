#!/usr/bin/env python3
"""Reject agent scratch files that were added to a pull request."""
import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys


def forbidden(path: str) -> bool:
    parts = PurePosixPath(path).parts
    if len(parts) >= 2 and parts[0] == '.agents' and parts[1] != 'skills':
        return True
    return PurePosixPath(path).name.startswith(('workpad-', 'pr-body-')) and PurePosixPath(path).suffix == '.md'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, help='PR base commit')
    args = parser.parse_args()
    try:
        root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
        paths = subprocess.check_output(
            ['git', '-C', str(root), 'diff', '--name-only', '--diff-filter=ACMR', args.base, 'HEAD', '--'],
            text=True,
        ).splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        print(f'check-agent-scratch: could not read PR diff: {error}', file=sys.stderr)
        return 1

    rejected = [path for path in paths if forbidden(path)]
    if rejected:
        print('check-agent-scratch: PR adds forbidden agent scratch files:', file=sys.stderr)
        for path in rejected:
            print(f'  {path}', file=sys.stderr)
        return 1
    print('check-agent-scratch: no forbidden agent scratch files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
