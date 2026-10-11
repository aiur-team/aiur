#!/usr/bin/env python3
"""Grandfather pre-rollout PRs, then validate current local-test evidence."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
import tempfile


def timestamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def activation_time(root, base):
    # First-parent history dates rollout at landing, rather than the feature commit.
    dates = subprocess.check_output([
        'git', '-C', str(root), 'log', '--first-parent', '--diff-filter=A',
        '--format=%cI', '--reverse', base, '--', 'scripts/check-pr-body.py',
    ], text=True).splitlines()
    return timestamp(dates[0]) if dates else None


def needs_check(pr, cutoff):
    return cutoff is not None and timestamp(pr['created_at']) > cutoff


def check_evidence(pr, root):
    with tempfile.TemporaryDirectory(prefix='pr-body-') as scratch:
        body = Path(scratch) / 'body.md'
        body.write_text(pr['body'] or '', encoding='utf-8')
        return subprocess.run([
            'elixir', '-r', 'src/lib/aiur/local_test_evidence.ex',
            '-r', 'src/lib/mix/tasks/pr_body.check.ex',
            '-e', 'Mix.start(); Mix.Tasks.PrBody.Check.run(System.argv())',
            '--', '--file', str(body), '--head', pr['head']['sha'],
        ], cwd=root, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr-json', required=True)
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    pr = json.loads(Path(args.pr_json).read_text(encoding='utf-8'))
    cutoff = activation_time(root, args.base)
    if not needs_check(pr, cutoff):
        print('PR body gate: exempt (opened before rollout, or gate not yet landed on base).')
        return 0
    return check_evidence(pr, root)


if __name__ == '__main__':
    raise SystemExit(main())
