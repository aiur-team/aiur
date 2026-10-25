#!/usr/bin/env python3
"""Ensure every literal Mix path dependency is copied into the Docker build."""
from pathlib import Path
import posixpath
import re
import sys


ROOT = Path(__file__).resolve().parent.parent


def main():
    mix = (ROOT / 'src/mix.exs').read_text()
    dockerfile = (ROOT / 'Dockerfile').read_text()
    dependencies = [posixpath.normpath(posixpath.join('src', path)) for path in
                    re.findall(r'\{:[\w]+,\s*path:\s*"([^"]+)"', mix)]
    copied = []
    before_deps = dockerfile.split('mix deps.get', 1)[0]
    for line in before_deps.splitlines():
        match = re.match(r'^COPY\s+(\S+)\s+(\S+)\s*$', line)
        if match:
            copied.append(match.groups())
    missing = [path for path in dependencies if not any(_copies(source, target, path) for source, target in copied)]
    if missing:
        print('Dockerfile does not copy Mix path dependencies: ' + ', '.join(missing), file=sys.stderr)
        return 1
    print(f'All {len(dependencies)} Mix path dependencies are copied into the Docker build.')
    return 0


def _copies(source, target, dependency):
    if source.startswith('--'):
        return False
    source = posixpath.normpath(source)
    target = posixpath.normpath(posixpath.join('opt/aiur', target.lstrip('/')))
    if source == '.':
        suffix = dependency
    elif dependency.startswith(source.rstrip('/') + '/'):
        suffix = dependency[len(source.rstrip('/')) + 1:]
    elif dependency == source:
        suffix = ''
    else:
        return False
    return posixpath.normpath(posixpath.join(target, suffix)) == posixpath.normpath('opt/aiur/' + dependency)


if __name__ == '__main__':
    sys.exit(main())
