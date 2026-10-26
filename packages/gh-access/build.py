#!/usr/bin/env python3
"""Compose wrappers without runtime policy loading."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARTS = ROOT / 'src/priv/github_guard'


def compose(adapter='standalone', deny_merge=False):
    if adapter == 'aiur' and deny_merge:
        raise ValueError('--deny-merge is standalone-only; Aiur policy is mandatory')
    entries = [line.split() for line in (PARTS / 'parts.tsv').read_text().splitlines()]
    sources = []
    if adapter == 'standalone':
        sources.append((PARTS / 'standalone.sh').read_text())
    for group, name in entries:
        if group not in ('core', 'aiur-policy'):
            raise ValueError(f'untagged fragment: {name}')
        include = adapter == 'aiur' or group == 'core'
        if adapter == 'standalone' and name == '20-b-merge-functions.sh' and deny_merge:
            include = True
        if include:
            source = (PARTS / 'gh' / name).read_text()
            if not source.startswith('# Fragment of the assembled `gh` guard '):
                raise ValueError(f'invalid fragment header: {name}')
            sources.append(source.split('\n', 1)[1])
        if adapter == 'standalone' and name == '15-c-disposition.sh':
            sources.append((PARTS / 'policy-none.sh').read_text())
        if adapter == 'standalone' and name == '20-c-agent-gate.sh' and deny_merge:
            sources.append('if merge_or_approve_command "$@"; then\n'
                           '  echo "gh-access: merge/approve refused by build policy" >&2\n'
                           '  exit 77\nfi\n')
    return ''.join(sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter', choices=['aiur', 'standalone'], default='standalone')
    parser.add_argument('--deny-merge', action='store_true', help='standalone: refuse merge/approve commands')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    script = compose(args.adapter, args.deny_merge)
    recursion = (ROOT / 'src/priv/guard_recursion.sh').read_text().replace('@TOOL@', 'GH').replace('@tool@', 'gh')
    script = script.replace('# @aiur-recursion-guard@\n', recursion)
    files = {
        'gh-access' if args.adapter == 'standalone' else 'gh': script,
        ('gh-access-broker' if args.adapter == 'standalone' else 'aiur-github-budget'): ''.join((ROOT / 'src/priv/github_budget' / name).read_text()
                                   for name in ['00_schema.py', '10_admission.py', '20_report_and_cli.py']),
        'github_budget_metrics.py': (ROOT / 'src/priv/github_budget_metrics.py').read_text(),
    }
    for name, source in files.items():
        target = args.output / name
        target.write_text(source)
        target.chmod(0o755)


if __name__ == '__main__':
    main()
