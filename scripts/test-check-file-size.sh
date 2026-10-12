#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
checker = source / 'scripts/check-file-size.py'
workflow = (source / '.github/workflows/ci.yml').read_text()
job = workflow.split('  workflow-security:', 1)[1].split('  merge-ruleset-drift:', 1)[0]
assert 'docs_only' not in job
assert 'fetch-depth: 0' in job
assert 'run: bash scripts/test-check-file-size.sh' in job
for name, expression in [('EVENT_NAME', 'github.event_name'), ('PR_BASE', 'github.event.pull_request.base.sha'),
                         ('MERGE_BASE', 'github.event.merge_group.base_sha'), ('PUSH_BEFORE', 'github.event.before')]:
    assert f'{name}: ${{{{ {expression} }}}}' in job
step = job.split('      - name: File size gate\n', 1)[1]
script = '\n'.join(line[10:] for line in step.split('        run: |\n', 1)[1].splitlines() if line.startswith('          '))


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args]).decode().strip()


def commit(repo):
    git(repo, 'add', '.')
    git(repo, 'commit', '--allow-empty', '-qm', 'fixture')
    return git(repo, 'rev-parse', 'HEAD')


def write(repo, files):
    for name, data in files.items():
        path = repo / name
        if data is None:
            path.unlink(missing_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


def run(repo, expected, snippet='', *args):
    result = subprocess.run(['python3', str(checker), *args], cwd=repo, capture_output=True, text=True)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    assert snippet in result.stdout + result.stderr, (snippet, result.stdout, result.stderr)
    return result.stdout


def lines(n):
    return b'x\n' * n


with tempfile.TemporaryDirectory(prefix='file-size-', dir=os.environ.get('TMPDIR')) as scratch:
    root = Path(scratch)
    repo = root / 'repo'
    repo.mkdir()
    git(repo, 'init', '-q', '-b', 'feature')
    git(repo, 'config', 'user.email', 'fixture@example.invalid')
    git(repo, 'config', 'user.name', 'Fixture')
    cases = [
        ('new 500', {}, {'file': lines(500)}, 0, 'notice: file: 500 lines'),
        ('new 501', {}, {'file': lines(501)}, 1, 'file: base 0 -> head 501 (limit 500)'),
        ('no final newline', {}, {'file': lines(499) + b'x'}, 0, 'file: 500 lines'),
        ('unchanged debt', {'file': lines(700)}, {'file': lines(700)}, 0, ''),
        ('crossing limit', {'file': lines(480)}, {'file': lines(520)}, 1, 'base 480 -> head 520'),
        ('shrinking debt', {'file': lines(700)}, {'file': lines(699)}, 0, ''),
        ('growing debt', {'file': lines(700)}, {'file': lines(701)}, 1, 'base 700 -> head 701'),
        ('rename debt', {'old': lines(700)}, {'old': None, 'new': lines(700)}, 1, 'new: base 0 -> head 700'),
        ('copy debt', {'old': lines(700)}, {'new': lines(700)}, 1, 'new: base 0 -> head 700'),
        ('text to NUL binary', {'file': lines(10)}, {'file': lines(10) + b'\0'}, 1, 'base 10 -> head binary'),
        ('text to invalid UTF-8', {'file': lines(10)}, {'file': b'\xff'}, 1, 'base 10 -> head binary'),
        ('new binary', {}, {'file': lines(900) + b'\0'}, 0, ''),
        ('binary to oversized text', {'file': b'\0'}, {'file': lines(501)}, 1, 'base binary -> head 501'),
        ('cohesion notice', {}, {'file': lines(250)}, 0, 'notice: file: 250 lines; give a cohesion reason'),
        ('growing cohesion notice', {'file': lines(201)}, {'file': lines(250)}, 0, 'notice: file: 250 lines'),
        ('empty file', {}, {'file': b''}, 0, ''),
        ('empty count', {'file': b''}, {'file': lines(501)}, 1, 'base 0 -> head 501'),
        ('CRLF', {}, {'file': b'x\r\n' * 500}, 0, 'file: 500 lines'),
        ('unusual path', {}, {'tab\tline\nfile': lines(501)}, 1, 'tab\\tline\\nfile: base 0 -> head 501'),
    ]
    for title, before, after, expected, snippet in cases:
        for path in repo.iterdir():
            if path.is_file() or path.is_symlink():
                path.unlink()
        write(repo, before)
        base = commit(repo)
        write(repo, after)
        head = commit(repo)
        run(repo, expected, snippet, '--base', base, '--head', head)
        print(f'PASS: {title}')

    base = commit(repo)
    (root / 'outside').write_bytes(lines(900))
    (repo / 'link').symlink_to(root / 'outside')
    head = commit(repo)
    run(repo, 0, 'link: symlink (not followed)', '--base', base)
    print('PASS: symlink to untracked 900-line target')

    # Baselines deliberately differ from origin/main=HEAD: empty comparisons must not pass.
    for path in repo.iterdir():
        if path.is_file() or path.is_symlink():
            path.unlink()
    write(repo, {'file': lines(480)})
    base = commit(repo)
    write(repo, {'file': lines(520)})
    head = commit(repo)
    git(repo, 'update-ref', 'refs/remotes/origin/main', head)
    (repo / 'scripts').mkdir()
    (repo / 'scripts/check-file-size.py').write_bytes(checker.read_bytes())
    env = dict(os.environ, PR_BASE=base, MERGE_BASE=base, PUSH_BEFORE=base)
    for event, before in [('pull_request', base), ('merge_group', base), ('push', base), ('push', '0' * 40)]:
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', script], cwd=repo,
                                env=dict(env, EVENT_NAME=event, PUSH_BEFORE=before), capture_output=True, text=True)
        assert result.returncode == 1 and 'base 480 -> head 520' in result.stdout, result
        print(f'PASS: workflow {event} baseline {"zeros" if before.startswith("000") else "event"}')
    git(repo, 'config', 'remote.origin.url', str(repo))
    git(repo, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
    git(repo, 'update-ref', 'refs/remotes/origin/integration', base)
    git(repo, 'branch', '--set-upstream-to=origin/integration', 'feature')
    for detached in [False, True]:
        if detached:
            git(repo, 'update-ref', '--no-deref', 'HEAD', head)
            git(repo, 'update-ref', 'refs/remotes/origin/main', base)
        result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', script], cwd=repo,
                                env=dict(env, EVENT_NAME='workflow_dispatch'), capture_output=True, text=True)
        assert result.returncode == 1 and 'base 480 -> head 520' in result.stdout, result
        print(f'PASS: workflow_dispatch {"detached fallback" if detached else "upstream"}')
    run(repo, 1, 'base 480 -> head 520')
    print('PASS: default merge base with origin/main')
    run(repo, 1, 'base not available; fetch origin/main', '--base', 'missing-base')
    git(repo, 'update-ref', '-d', 'refs/remotes/origin/main')
    run(repo, 1, 'base not available; fetch origin/main')
    print('PASS: unavailable base fails closed')
    shallow = root / 'shallow'
    subprocess.run(['git', '-C', str(root), 'clone', '-q', '--depth=1', f'file://{repo}', str(shallow)], check=True)
    run(shallow, 1, 'base not available; fetch origin/main', '--base', base)
    print('PASS: shallow checkout fails closed')

    write(repo, {'file': lines(480)})
    base = commit(repo)
    write(repo, {'website/docs-app/oversized.md': lines(501)})
    head = commit(repo)
    assert git(repo, 'diff', '--name-only', base, head) == 'website/docs-app/oversized.md'
    result = subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c', script], cwd=repo,
                            env=dict(env, EVENT_NAME='pull_request', PR_BASE=base), capture_output=True, text=True)
    assert result.returncode == 1 and 'website/docs-app/oversized.md: base 0 -> head 501' in result.stdout, result
    print('PASS: website-only PR fixture runs the workflow gate')

    # Lockfile class: a fake npm "regenerates" whatever FAKE_LOCK holds, so each case controls the tool's output.
    tools = root / 'tools'
    tools.mkdir()
    (tools / 'npm').write_text('#!/bin/sh\ncp "$FAKE_LOCK" package-lock.json\n')
    (tools / 'npm').chmod(0o755)
    generated = lines(3028)
    (root / 'generated').write_bytes(generated)
    lock_env = dict(os.environ, FAKE_LOCK=str(root / 'generated'))

    def lock_case(title, files, expected, snippet, env):
        write(repo, {'pkg/package.json': b'{}\n', 'pkg/package-lock.json': None, 'pkg/data.json': None})
        base = commit(repo)
        write(repo, files)
        head = commit(repo)
        result = subprocess.run(['python3', str(checker), '--base', base, '--head', head], cwd=repo,
                                env=env, capture_output=True, text=True)
        assert result.returncode == expected and snippet in result.stdout, (title, result)
        print(f'PASS: {title}')

    with_tools = dict(lock_env, PATH=f'{tools}:{os.environ["PATH"]}')
    offline = root / 'offline'
    offline.mkdir()
    (offline / 'npm').write_text('#!/bin/sh\nexit 1\n')
    (offline / 'npm').chmod(0o755)
    no_tools = dict(lock_env, PATH=f'{offline}:{os.environ["PATH"]}')
    lock_case('generated lockfile above 500 lines is exempt', {'pkg/package-lock.json': generated}, 0,
              'pkg/package-lock.json: 3028 lines; exempt', with_tools)
    lock_case('hand-edited lockfile fails', {'pkg/package-lock.json': generated.replace(b'x', b'y', 1)}, 1,
              'pkg/package-lock.json: base 0 -> head 3028', with_tools)
    lock_case('lockfile fails closed when the registry is unreachable', {'pkg/package-lock.json': generated}, 1,
              'lockfile unverified', no_tools)
    lock_case('501-line non-lockfile JSON still fails', {'pkg/data.json': lines(501)}, 1,
              'pkg/data.json: base 0 -> head 501', with_tools)
PY
