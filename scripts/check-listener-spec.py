#!/usr/bin/env python3
"""Offline integrity gate for the committed Khala listener contract."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

DEFAULT_ROOT = Path(__file__).resolve().parents[1] / 'src/priv/listener_spec'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(entries):
    result = {}
    for name, checksum in entries:
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or '..' in path.parts
                or str(path) != name or '\\' in name
                or not re.fullmatch(r'[0-9a-f]{64}', checksum) or name in result):
            raise ValueError(f'invalid or duplicate inventory entry: {name}')
        result[name] = checksum
    return result


def check(root):
    lines = (root / 'CHECKSUM').read_text().splitlines()
    if not (lines[0] == '# source aiur-team/khala'
            and re.fullmatch(r'# git_commit [0-9a-f]{40}', lines[1])):
        raise ValueError('missing pinned source headers')
    checksums = inventory(line.split('  ', 1)[::-1] for line in lines[2:])
    paths = list(root.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('symlinks are not allowed')
    actual = {path.relative_to(root).as_posix(): digest(path)
              for path in paths if path.is_file() and path != root / 'CHECKSUM'}
    if actual != checksums:
        raise ValueError('CHECKSUM: extra, missing or changed files')
    manifest = json.loads((root / 'v1/MANIFEST.json').read_bytes())
    if manifest['spec_version'] != '1.0.0':
        raise ValueError('unsupported spec_version')
    upstream = inventory((f"v1/{row['path']}", row['sha256']) for row in manifest['files'])
    if upstream != {name: sha for name, sha in actual.items() if name != 'v1/MANIFEST.json'}:
        raise ValueError('MANIFEST: extra, missing or changed files')
    print(f'listener spec: {len(actual)} files agree with CHECKSUM and MANIFEST')


if __name__ == '__main__':
    try:
        check(Path(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_ROOT)
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        sys.exit(f'listener spec invalid: {error}')
