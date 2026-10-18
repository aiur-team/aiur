#!/usr/bin/env python3
"""Select the expensive home matrix from the whole merge-group candidate diff."""
import json
import re
import subprocess
import sys
from pathlib import PurePosixPath


def touches_home(path):
    # Product, home specs/baselines, fixtures, and shared browser capture/setup
    # all affect home pixels. Workflow/selector edits also validate their wiring.
    prefixes = (
        'src/priv/static/build-home/', 'src/lib/aiur_web/build/',
        'src/browser/tests/build-home-', 'src/browser/support/',
        'src/browser/tests/support/', 'src/test/browser/',
        'src/test/fixtures/build_home/', 'src/test/support/build_home/',
        'src/test/support/browser_harness/', '.github/actions/setup-browser/',
        'src/browser/scripts/build-home-', 'src/browser/scripts/export-build-home-',
    )
    files = {
        'src/browser/package.json', 'src/browser/package-lock.json',
        'src/browser/scripts/run-browser-tests.mjs', 'src/browser/scripts/start-fixture.mjs',
        'src/browser/scripts/run-build-home-band-full.mjs',
        '.github/workflows/home-parity.yml', '.github/workflows/home-parity-nightly.yml',
        '.github/workflows/ci.yml', 'scripts/classify-home-ci.py',
        'scripts/classify-ci-changes.sh', 'scripts/check-ci-gate.py',
    }
    return (path.startswith(prefixes) or path in files
            or (path.startswith('src/browser/')
                and PurePosixPath(path).name.startswith('playwright.')
                and path.endswith('.config.mjs')))


def classify(event_file, workspace):
    event = json.loads(open(event_file, encoding='utf-8').read())
    group = event['merge_group']
    base, head = group['base_sha'], group['head_sha']
    if not all(isinstance(sha, str) and re.fullmatch(r'[0-9a-fA-F]{40}', sha)
               for sha in (base, head)):
        raise ValueError('merge_group requires full base_sha and head_sha')
    # --no-renames includes both sides of moves; deletion of a home path counts.
    paths = subprocess.check_output([
        'git', '-C', workspace, 'diff', '--no-renames', '--name-only', '-z', base, head, '--',
    ]).decode('utf-8').split('\0')
    return any(touches_home(path) for path in paths if path)


if __name__ == '__main__':
    try:
        print(f'home_changed={str(classify(*sys.argv[1:])).lower()}')
    except (KeyError, ValueError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f'home matrix classification failed: {error}', file=sys.stderr)
        sys.exit(1)
