#!/usr/bin/env python3
"""Grandfather pre-rollout PRs, then validate current local-test evidence."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
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


TESTED_HEAD = re.compile(r'^Tested head: ([0-9a-fA-F]{40})\s*$', re.M)
CLASSIFY = '''
[approved, current, main, body, head] = System.argv()
read = &(&1 |> File.read!() |> JSON.decode!())
case Aiur.Events.GithubCIPoller.ApprovalCarry.classify_diffs(read.(approved), read.(current), read.(main), File.read!(body), head) do
  :carried -> :ok
  verdict -> IO.inspect(verdict, label: "PR body gate: contribution differs"); System.halt(1)
end
'''


def compare(repo, base, head):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/compare/{base}...{head}'], text=True))


def is_ancestor(root, tested, head):
    return subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', tested, head],
                          capture_output=True, check=False).returncode == 0


def identical_contribution(pr, tested, root):
    """The #4710 approval-carry comparison: only base commits came in since the tested ancestor."""
    head = pr['head']['sha']
    if not is_ancestor(root, tested, head):
        return False
    repo, base = pr['base']['repo']['full_name'], pr['base']['ref']
    try:
        approved, current = compare(repo, base, tested), compare(repo, base, head)
        bases = approved['merge_base_commit']['sha'], current['merge_base_commit']['sha']
        main = {'files': []} if bases[0] == bases[1] else compare(repo, *bases)
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f'PR body gate: contribution comparison unavailable: {error}')
        return False
    if main.get('status', 'ahead') != 'ahead':
        return False
    with tempfile.TemporaryDirectory(prefix='pr-body-carry-') as scratch:
        paths = []
        for name, content in [('approved', json.dumps(approved)), ('current', json.dumps(current)),
                              ('main', json.dumps(main)), ('body', pr['body'] or '')]:
            path = Path(scratch) / name
            path.write_text(content, encoding='utf-8')
            paths.append(str(path))
        return subprocess.run([
            'elixir', '-r', 'src/lib/aiur/events/github_ci_poller/approval_carry.ex',
            '-e', CLASSIFY, '--', *paths, tested,
        ], cwd=root, check=False).returncode == 0


def evidence_head(pr, root):
    """Return the head the evidence must name and the mode that accepts it."""
    head = pr['head']['sha']
    match = TESTED_HEAD.search(pr['body'] or '')
    tested = match and match.group(1).lower()
    if tested and tested != head.lower() and identical_contribution(pr, tested, root):
        return tested, f'identical contribution since {tested}'
    return head, 'exact head'


def check_evidence(pr, root):
    head, mode = evidence_head(pr, root)
    print(f'PR body gate: Tested head mode: {mode}')
    with tempfile.TemporaryDirectory(prefix='pr-body-') as scratch:
        body = Path(scratch) / 'body.md'
        body.write_text(pr['body'] or '', encoding='utf-8')
        return subprocess.run([
            'elixir', '-r', 'src/lib/aiur/local_test_evidence.ex',
            '-r', 'src/lib/mix/tasks/pr_body.check.ex',
            '-e', 'Mix.start(); Mix.Tasks.PrBody.Check.run(System.argv())',
            '--', '--file', str(body), '--head', head,
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
