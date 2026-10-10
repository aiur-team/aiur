#!/usr/bin/env python3
"""Prevent new oversized text files and growth of existing debt using Git blobs."""

import argparse
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile

LIMIT = 500
# Tool-written lockfiles cannot be split. They may exceed LIMIT only when the tool reproduces them byte for byte.
LOCKFILE_REGEN = {
    'package-lock.json': ['npm', 'install', '--package-lock-only', '--ignore-scripts'],
    'bun.lock': ['bun', 'install', '--lockfile-only'],
}


def git(*args):
    return subprocess.check_output(['git', '-C', str(Path.cwd()), *args], stderr=subprocess.PIPE)


def counts(revision, batch, cache):
    files = {}
    for entry in git('ls-tree', '-r', '-z', revision).split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        mode, kind, sha = metadata.split()
        if kind != b'blob':
            continue
        if mode == b'120000':
            files[path] = 'symlink'
            continue
        if sha not in cache:
            batch.stdin.write(sha + b'\n')
            batch.stdin.flush()
            header = batch.stdout.readline().split()
            if len(header) != 3 or header[1] != b'blob':
                raise ValueError('cannot read Git blob')
            blob = batch.stdout.read(int(header[2]))
            if batch.stdout.read(1) != b'\n':
                raise ValueError('incomplete Git blob response')
            try:
                blob.decode('utf-8')
                cache[sha] = 'binary' if b'\0' in blob else blob.count(b'\n') + int(bool(blob) and not blob.endswith(b'\n'))
            except UnicodeDecodeError:
                cache[sha] = 'binary'
        files[path] = cache[sha]
    return files


def lockfile_verified(head, path):
    """True when regenerating the lockfile from its sibling package.json reproduces it exactly."""
    posix = PurePosixPath(path.decode('utf-8', errors='surrogateescape'))
    prefix = '' if str(posix.parent) == '.' else f'{posix.parent}/'
    try:
        with tempfile.TemporaryDirectory(prefix='lockfile-') as scratch:
            for file in ('package.json', posix.name):
                Path(scratch, file).write_bytes(git('show', f'{head}:{prefix}{file}'))
            subprocess.run(LOCKFILE_REGEN[posix.name], cwd=scratch, check=True, capture_output=True)
            return Path(scratch, posix.name).read_bytes() == git('show', f'{head}:{posix}')
    except (subprocess.CalledProcessError, OSError):
        print(f'{posix}: lockfile unverified (tool, package.json or registry unavailable); failing closed')
        return False


def check(base, head):
    cache = {}
    with subprocess.Popen(['git', '-C', str(Path.cwd()), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as batch:
        try:
            before = counts(base, batch, cache)
            after = counts(head, batch, cache)
        finally:
            batch.stdin.close()
            batch.wait()
    failures = 0
    for path, current in sorted(after.items()):
        previous = before.get(path, 0)
        name = path.decode('utf-8', errors='backslashreplace')
        # Escape control characters so each result occupies exactly one line.
        name = name.encode('unicode_escape').decode('ascii')
        if current == 'symlink':
            print(f'{name}: symlink (not followed)')
            continue
        text_before = isinstance(previous, int)
        if current == 'binary':
            failed = text_before and path in before
        else:
            baseline = previous if text_before else 0
            failed = current > LIMIT and (baseline <= LIMIT or current > baseline)
            if not failed and 200 < current <= LIMIT and current > baseline:
                print(f'notice: {name}: {current} lines; give a cohesion reason above 200')
        if failed and isinstance(current, int) and PurePosixPath(name).name in LOCKFILE_REGEN and lockfile_verified(head, path):
            print(f'{name}: {current} lines; exempt, regenerates identically')
            continue
        if failed:
            print(f'{name}: base {previous} -> head {current} (limit {LIMIT})')
            failures += 1
    return int(bool(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', help='baseline commit (default: merge base with origin/main)')
    parser.add_argument('--head', default='HEAD', help='commit to check (default: HEAD)')
    args = parser.parse_args()
    try:
        head = git('rev-parse', '--verify', f'{args.head}^{{commit}}').decode().strip()
        base = args.base or git('merge-base', head, 'origin/main').decode().strip()
        base = git('rev-parse', '--verify', f'{base}^{{commit}}').decode().strip()
        return check(base, head)
    except (subprocess.CalledProcessError, ValueError, OSError) as error:
        print(f'file size gate: base not available; fetch origin/main (or the supplied base); {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
