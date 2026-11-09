#!/usr/bin/env python3
"""Reject agent scratch files and empty Elixir sources added to a pull request."""
import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys


def forbidden(path: str) -> bool:
    parts = PurePosixPath(path).parts
    if len(parts) >= 2 and parts[0] == '.agents' and parts[1] != 'skills':
        return True
    return PurePosixPath(path).name.startswith(('workpad-', 'pr-body-')) and PurePosixPath(path).suffix == '.md'


def empty_elixir(numstat_line: str) -> bool:
    """`git diff --numstat` reports `0<TAB>0<TAB>path` for an added empty file."""
    insertions, deletions, path = numstat_line.split('\t', 2)
    return insertions == deletions == '0' and PurePosixPath(path).suffix in ('.ex', '.exs')


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
        # An empty module is never intended: #7920 was a stray file from the warm base
        # that `git add -A` swept into PRs.
        added = subprocess.check_output(
            ['git', '-C', str(root), 'diff', '--numstat', '--no-renames', '--diff-filter=A', args.base, 'HEAD', '--'],
            text=True,
        ).splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        print(f'check-agent-scratch: could not read PR diff: {error}', file=sys.stderr)
        return 1

    rejected = [path for path in paths if forbidden(path)]
    rejected += [line.split('\t', 2)[2] for line in added if empty_elixir(line)]
    if rejected:
        print('check-agent-scratch: PR adds forbidden agent scratch files or empty Elixir sources:', file=sys.stderr)
        for path in rejected:
            print(f'  {path}', file=sys.stderr)
        return 1
    print('check-agent-scratch: no forbidden agent scratch files or empty Elixir sources')
    return 0


if __name__ == '__main__':
    sys.exit(main())
