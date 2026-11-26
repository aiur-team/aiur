#!/usr/bin/env python3
"""Clear untracked skill materializations that would obstruct a Git merge."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

SKILL_ROOTS = ('.claude/skills', '.codex/skills', '.agents/skills')


def git(workspace, *args):
    return subprocess.check_output(['git', '-C', str(workspace), *args], stderr=subprocess.STDOUT)


def incoming_skill_paths(workspace, base):
    paths = git(
        workspace, 'diff', '--diff-filter=ACMRT', '--name-only', '-z',
        'HEAD', base, '--', *SKILL_ROOTS,
    )
    return [os.fsdecode(path) for path in paths.split(b'\0') if path]


def tracked(workspace, path):
    result = subprocess.run(
        ['git', '-C', str(workspace), 'ls-files', '--error-unmatch', '-z', '--', path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def incoming_blob(workspace, base, path):
    entry = git(workspace, 'ls-tree', '-z', base, '--', path).split(b'\0', 1)[0]
    if not entry or b'\t' not in entry:
        return None
    metadata, entry_path = entry.split(b'\t', 1)
    if entry_path != os.fsencode(path):
        return None
    mode, _kind, oid = metadata.split(b' ', 2)
    return mode, git(workspace, 'cat-file', 'blob', oid.decode('ascii'))


def same_as_incoming(path, incoming):
    if incoming is None or path.is_dir() and not path.is_symlink():
        return False
    mode, blob = incoming
    if mode == b'120000':
        return path.is_symlink() and os.fsencode(os.readlink(path)) == blob
    return path.is_file() and not path.is_symlink() and path.read_bytes() == blob


def untracked_obstruction(workspace, relative):
    parts = Path(relative).parts
    candidate = workspace
    for index, part in enumerate(parts):
        candidate = candidate / part
        if not os.path.lexists(candidate):
            return None
        parent = index < len(parts) - 1
        if parent and candidate.is_dir() and not candidate.is_symlink():
            continue
        obstruction = Path(*parts[:index + 1]).as_posix()
        return None if tracked(workspace, obstruction) else (candidate, obstruction)
    return None


def move_to_git_backup(workspace, path, relative):
    git_dir = Path(os.fsdecode(git(workspace, 'rev-parse', '--absolute-git-dir').strip()))
    backup_root = git_dir / 'aiur' / 'skill-collisions' / f'{time.time_ns()}-{os.getpid()}'
    destination = backup_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    os.replace(path, destination)
    return destination


def prepare(workspace, base):
    workspace = Path(workspace).resolve()
    for relative in incoming_skill_paths(workspace, base):
        if not relative.startswith(tuple(root + '/' for root in SKILL_ROOTS)) and relative not in SKILL_ROOTS:
            continue
        found = untracked_obstruction(workspace, relative)
        if found is None:
            continue
        path, obstruction = found

        if same_as_incoming(path, incoming_blob(workspace, base, relative)):
            path.unlink()
            print(f'removed identical untracked skill materialization: {relative}')
        else:
            backup = move_to_git_backup(workspace, path, obstruction)
            print(f'preserved conflicting untracked skill materialization: {relative} -> {backup}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', default='.', help='Git workspace to prepare')
    parser.add_argument('--base', required=True, help='fetched ref that will be merged')
    args = parser.parse_args()
    try:
        prepare(args.workspace, args.base)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        detail = error.output.decode('utf-8', errors='replace') if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f'skill mount merge preflight failed: {detail}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
