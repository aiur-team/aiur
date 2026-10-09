"""Remove spent allowlist exemptions and explain the remaining boundary debt."""
from collections import Counter
import os
from pathlib import Path
import re
import subprocess
import sys

TICKET_REASON = re.compile(r'^(MP-[A-Z0-9-]+|U[0-9]+|#[0-9]+)\b')
DIRECTORY = 'scripts/components/allowlist'


def stale_entries(root, allowed, violations, rules, prune):
    stale = {key for key in allowed - violations.keys() if key[0] in rules}
    if prune:
        for path in sorted((root / DIRECTORY).glob('*.tsv')):
            rows = path.read_text().splitlines(keepends=True)
            kept = [row for row in rows if (row.split('\t')[0], path.stem,
                    row.split('\t')[1] if '\t' in row else '') not in stale]
            if kept != rows:
                path.write_text(''.join(kept))
        return set()
    for rule, source, target in sorted(stale):
        print(f'components: stale allowlist entry: {rule} {source} -> {target}; delete it')
    return stale


def growth_errors(root, base):
    if not re.fullmatch(r'[0-9a-f]{7,40}', base):
        raise ValueError('--growth-base must be a commit SHA')
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)
    if git('cat-file', '-e', f'{base}^{{commit}}').returncode:
        if git('fetch', '--depth=1', 'origin', base).returncode:
            print(f'components: warning: growth base {base} not fetchable; growth guard skipped',
                  file=sys.stderr)
            return False
    tracked = git('ls-tree', '-r', '--name-only', base, '--', DIRECTORY)
    if tracked.returncode:
        raise ValueError(f'cannot read growth base: {tracked.stderr.strip()}')
    base_paths = set(tracked.stdout.splitlines())
    current_paths = {p.relative_to(root).as_posix() for p in (root / DIRECTORY).glob('*.tsv')}
    failed = False
    for name in sorted(base_paths | current_paths):
        if not name.endswith('.tsv'):
            continue
        previous = git('show', f'{base}:{name}') if name in base_paths else None
        if previous is not None and previous.returncode:
            raise ValueError(f'cannot read base allowlist: {previous.stderr.strip()}')
        # Rows are exemptions, not physical line counts; comments cannot grant one.
        old_rows = Counter(previous.stdout.splitlines()) if previous else Counter()
        path = root / name
        rows = path.read_text().splitlines() if path.exists() else []
        for row in rows:
            if not row.strip() or row.startswith('#'):
                continue
            if old_rows[row]:
                old_rows[row] -= 1
                continue
            fields = row.split('\t')
            if len(fields) != 3 or not TICKET_REASON.match(fields[2]):
                print(f'components: {name}: added allowlist entry requires a ticket reason: {row}')
                failed = True
    return failed


def write_summary(violations, allowed, stale, rules, largest_scc, elapsed):
    destination = os.environ.get('GITHUB_STEP_SUMMARY')
    if not destination:
        return
    lines = ['### Component boundaries', '']
    for rule in rules:
        total = sum(key[0] == rule for key in violations)
        accepted = sum(key[0] == rule for key in violations.keys() & allowed)
        obsolete = sum(key[0] == rule for key in stale)
        lines.append(f'- {rule}: {total} violations, {accepted} allowed, '
                     f'{total - accepted} new, {obsolete} stale')
    lines.extend([f'- Largest SCC: {largest_scc} components', f'- Runtime: {elapsed:.3f} s', ''])
    with Path(destination).open('a') as stream:
        stream.write('\n'.join(lines) + '\n')
