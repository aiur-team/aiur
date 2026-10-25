#!/usr/bin/env python3
"""Exercise workspace merges with materialized, untracked skill paths."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / 'scripts/prepare-skill-mount-merge.py'
HOOKS = ROOT / '.aiur/hooks'


def git(cwd, *args, check=True):
    return subprocess.run(
        ['git', '-C', str(cwd), *args], capture_output=True, text=True, check=check,
    )


def commit(repo, message):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-qm', message)


def fixture(root, tracked_path, incoming, materialized=None):
    root.mkdir(parents=True)
    source = root / 'source'
    workspace = root / 'workspace'
    source.mkdir()
    git(source, 'init', '-q', '-b', 'main')
    git(source, 'config', 'user.name', 'Skill merge test')
    git(source, 'config', 'user.email', 'skill-merge@example.invalid')
    (source / 'base.txt').write_text('base\n')
    commit(source, 'base')
    git(root, 'clone', '-q', str(source), str(workspace))
    git(workspace, 'config', 'user.name', 'Skill merge test')
    git(workspace, 'config', 'user.email', 'skill-merge@example.invalid')
    git(workspace, 'switch', '-q', '-c', 'worker')
    (workspace / 'feature.txt').write_text('preserve worker work\n')
    commit(workspace, 'worker work')

    destination = source / tracked_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(incoming, bytes):
        destination.write_bytes(incoming)
    else:
        destination.symlink_to(incoming)
    commit(source, 'add tracked skill path')
    git(workspace, 'fetch', 'origin', 'main')

    installed = workspace / tracked_path
    installed.parent.mkdir(parents=True, exist_ok=True)
    materialized = incoming if materialized is None else materialized
    if isinstance(materialized, bytes):
        installed.write_bytes(materialized)
    else:
        installed.symlink_to(materialized)
    return workspace


def prepare_and_merge(workspace):
    result = subprocess.run(
        [sys.executable, str(PREPARE), '--workspace', str(workspace), '--base', 'origin/main'],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    merged = git(workspace, 'merge', '--no-edit', 'origin/main', check=False)
    assert merged.returncode == 0, merged.stdout + merged.stderr
    assert (workspace / 'feature.txt').read_text() == 'preserve worker work\n'
    return result.stdout


def test_identical_materialization(root):
    content = b'new reference\n'
    workspace = fixture(
        root, '.claude/skills/aiur-run/references/continuous-build-intake.md', content,
    )
    blocked = git(workspace, 'merge', '--no-edit', 'origin/main', check=False)
    assert blocked.returncode != 0 and 'would be overwritten' in blocked.stdout + blocked.stderr
    assert 'removed identical untracked skill materialization' in prepare_and_merge(workspace)
    assert (workspace / '.claude/skills/aiur-run/references/continuous-build-intake.md').read_bytes() == content
    print('PASS: identical untracked Claude skill materialization no longer blocks base merge')


def test_different_materialization_is_preserved(root):
    workspace = fixture(
        root / 'different', '.claude/skills/aiur-agent/new-reference.md',
        b'upstream reference\n', b'workspace materialization\n',
    )
    output = prepare_and_merge(workspace)
    assert 'preserved conflicting untracked skill materialization' in output
    git_dir = Path(git(workspace, 'rev-parse', '--absolute-git-dir').stdout.strip())
    backups = list((git_dir / 'aiur/skill-collisions').rglob('new-reference.md'))
    assert len(backups) == 1 and backups[0].read_bytes() == b'workspace materialization\n'
    assert (workspace / '.claude/skills/aiur-agent/new-reference.md').read_bytes() == b'upstream reference\n'
    print('PASS: differing untracked skill materialization is preserved outside the checkout')


def test_tracked_link_materialization(root):
    workspace = fixture(
        root / 'link', '.codex/skills/release', '../../.claude/skills/release',
    )
    assert 'removed identical untracked skill materialization' in prepare_and_merge(workspace)
    assert (workspace / '.codex/skills/release').is_symlink()
    print('PASS: identical untracked Codex skill link no longer blocks base merge')


def main():
    hook = HOOKS.read_text()
    prepare_at = hook.index('scripts/prepare-skill-mount-merge.py')
    merge_at = hook.index('git merge --no-edit "origin/$base_branch"')
    assert prepare_at < merge_at, 'before_run must clear skill collisions after fetch and before merge'
    with tempfile.TemporaryDirectory(prefix='skill-merge-', dir=os.environ.get('TMPDIR')) as scratch:
        root = Path(scratch)
        test_identical_materialization(root / 'identical')
        test_different_materialization_is_preserved(root)
        test_tracked_link_materialization(root)


if __name__ == '__main__':
    main()
