#!/usr/bin/env python3
"""Report plan drift without editing the pack (stdlib only).

python3 -I scripts/plan_refresh.py --repo . --from OLD --to NEW \
  --pack docs/research/aiur-mobile-and-platform --pack-ref RESEARCH_REF \
  --u8-ledger docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv \
  --out report.md
Omit --pack-ref to read a local pack directory. Ledger is a local CSV path.
"""
import argparse
import csv
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOTS = ('src', 'packages', 'packaging', 'website', 'scripts', '.github')
CITATION = re.compile(r'`((?:src|packages|packaging|website|scripts|\.github)/[^`\s:]+)(?::(\d+)(?:-(\d+))?)?`')
HEADER = ['path', 'release_lines', 'package', 'frozen_owner', 'frozen_disposition', 'confidence']
CONTRACTS = ('identity-and-capabilities', 'events-and-replay',
             'command-request-and-resolution', 'conversations-transcripts-anchors')


def git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.decode(errors='replace').strip())
    return result.stdout


def tree(repo, ref):
    return set(git(repo, 'ls-tree', '-r', '--name-only', '-z', ref).decode().split('\0')) - {''}


def frontmatter(text):
    if not text.startswith('---\n'):
        return {}
    return dict(re.findall(r'^([\w_]+):\s*(.*?)\s*$', text.split('---', 2)[1], re.M))


def expand(pattern):
    match = re.search(r'\{([^{}]+)\}', pattern)
    if not match:
        return [pattern]
    return [item for value in match[1].split(',')
            for item in expand(pattern[:match.start()] + value + pattern[match.end():])]


def matches(path, pattern):
    # Unlike fnmatch, a single star must not cross a directory boundary.
    expression = ''
    i = 0
    while i < len(pattern):
        if pattern[i:i + 3] == '**/':
            expression += '(?:.*/)?'
            i += 3
        elif pattern[i:i + 2] == '**':
            expression += '.*'
            i += 2
        else:
            expression += {'*': '[^/]*', '?': '[^/]'}.get(pattern[i], re.escape(pattern[i]))
            i += 1
    return re.fullmatch(expression, path) is not None


def manifest(repo, ref, files):
    paths = ['components.json'] if 'components.json' in files else sorted(
        p for p in files if p.startswith('components/') and p.endswith('.json'))
    components = {}
    for path in paths:
        data = json.loads(git(repo, 'show', f'{ref}:{path}'))
        for component in data['components']:
            identifier, globs = component['id'], component['paths']
            if not isinstance(identifier, str) or not isinstance(globs, list) or not all(
                    isinstance(p, str) for p in globs) or identifier in components:
                raise ValueError(f'invalid/duplicate component in {path}')
            components[identifier] = globs
    return components


def owner(path, components):
    hits = [(len(re.split(r'[*?{]', glob)[0]), identifier)
            for identifier, globs in components.items() for glob in globs
            if any(matches(path, p) for p in expand(glob))]
    if not hits:
        return 'unassigned'
    best = max(score for score, _ in hits)
    return ', '.join(sorted({identifier for score, identifier in hits if score == best}))


def line_status(diff, start, end):
    offset = 0
    changed = False
    for match in re.finditer(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', diff, re.M):
        old, count, _, added = [int(x) if x is not None else 1 for x in match.groups()]
        if count == 0:
            changed |= start <= old < end
            if old < start:
                offset += added
        else:
            changed |= old <= end and old + count - 1 >= start
            if old + count - 1 < start:
                offset += added - count
    if changed:
        return 'LINES-CHANGED'
    if offset:
        return f'LINES-SHIFTED :{start + offset}-{end + offset}'
    return 'OK'


def read_pack(repo, pack, ref):
    if ref:
        prefix = str(pack).rstrip('/') + '/'
        paths = sorted(p for p in tree(repo, ref) if p.startswith(prefix) and p.endswith('.md'))
        documents = {p[len(prefix):]: git(repo, 'show', f'{ref}:{p}').decode() for p in paths}
    else:
        directory = Path(pack)
        documents = {str(p.relative_to(directory)): p.read_text() for p in sorted(directory.rglob('*.md'))}
    if not documents:
        raise ValueError('pack contains no Markdown documents')
    return documents


def load_ledger(path):
    with Path(path).open(newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != HEADER:
            raise ValueError(f'ledger header must be {",".join(HEADER)}')
        rows = {}
        for row in reader:
            if not row['path'] or not row['package'] or row['path'] in rows:
                raise ValueError('ledger has empty or duplicate path/package')
            rows[row['path']] = row['package']
        return rows


def report(repo, before, after, documents, ledger):
    old_files, new_files = tree(repo, before), tree(repo, after)
    old_components = manifest(repo, before, old_files)
    new_components = manifest(repo, after, new_files)
    records = git(repo, 'diff', '--name-status', '-z', '-M50%', before, after, '--', *ROOTS).decode().split('\0')
    moves, added = {}, []
    while records and records[0]:
        status, path = records.pop(0), records.pop(0)
        if status.startswith('R'):
            moves[path] = records.pop(0)
        elif status == 'A':
            added.append(path)
    counts = Counter()
    citations, sizes, rows, contracts = [], [], [], []
    blobs, diffs = {}, {}
    for name, text in documents.items():
        meta = frontmatter(text)
        ticket = meta.get('ticket_id', name)
        cited = set()
        for match in CITATION.finditer(text):
            path, start, end = match.groups()
            target = moves.get(path, path)
            cited.add((path, target))
            status = 'OK'
            if path not in old_files:
                status = 'UNRESOLVED (absent at from)'
            elif target not in new_files:
                status = 'GONE'
            elif path in moves:
                status = f'MOVED {path} → {target}'
            if start and path in old_files and target in new_files:
                key = (path, target)
                if key not in diffs:
                    diffs[key] = git(repo, 'diff', '--no-ext-diff', '--no-textconv', '-M50%', '-U0',
                                     before, after, '--', path, target).decode()
                lines = line_status(diffs[key], int(start), int(end or start))
                if lines != 'OK':
                    status = lines if status == 'OK' else status + '; ' + lines
            splits = [p for p in added if Path(p).stem.startswith(Path(path).stem) and p != target]
            if splits and (path in moves or target not in new_files):
                status += '; SPLIT? ' + ', '.join(splits)
            counts[status.split()[0]] += 1
            location = text[:match.start()].count('\n') + 1
            citations.append((ticket, f'{name}:{location}', match[0].strip('`'), status))
        if 'ticket_id' in meta:
            oversized = False
            for path, target in sorted(cited):
                if target not in new_files:
                    continue
                if target not in blobs:
                    blobs[target] = git(repo, 'show', f'{after}:{target}')
                blob = blobs[target]
                length = blob.count(b'\n') + int(bool(blob) and not blob.endswith(b'\n'))
                if length <= 500:
                    continue
                oversized = True
                package = ledger.get(target)
                declared = meta.get('size_owner', '')
                status = ('UNASSIGNED (>500, not in ledger — ask U0)' if package is None else
                          'MATCH' if declared == package else f'MISMATCH (ledger says {package})')
                sizes.append((ticket, target, str(length), declared, status))
            if not oversized and meta.get('size_owner', '').split(' ')[0] not in ('', 'n/a'):
                sizes.append((ticket, '—', '—', meta['size_owner'], 'NO-LONGER-OVERSIZED'))
        if name.endswith('migration-plan.md'):
            for line in text.splitlines():
                cells = [c.strip() for c in line.strip('|').split('|')]
                if not cells or not re.fullmatch(r'PR-\d+', cells[0]):
                    continue
                patterns = re.findall(r'`([^`]+)`', cells[1])
                found = set()
                for pattern in patterns:
                    for glob in expand(pattern):
                        candidates = [glob] if glob.startswith(ROOTS) else [
                            'src/lib/' + glob if glob.startswith('aiur_web/') else 'src/lib/aiur/' + glob]
                        found.update(p for p in old_files if any(matches(p, g) for g in candidates))
                surviving = [p for p in found if moves.get(p, p) in new_files]
                changed = [p for p in found if p in moves or p not in new_files]
                state = ('unresolved' if not found else 'deleted' if not surviving else
                         'unchanged' if not changed else 'moved' if len(changed) == len(found) and len(surviving) == len(found)
                         else 'partly moved')
                destinations = [f'{moves.get(p, p)} ({owner(moves.get(p, p), new_components)})'
                                for p in sorted(surviving)]
                rows.append((cells[0], cells[1], state, '<br>'.join(destinations) or '—'))
    for contract in CONTRACTS:
        name = f'contracts/{contract}.md'
        meta = frontmatter(documents.get(name, ''))
        contracts.append((contract, *(meta.get(k, 'unavailable') for k in ('status', 'base_main_sha', 'date'))))
    output = [f'# Plan refresh: {before} → {after}', '',
              '## Summary counts', '', f'{len(moves)} file moves; {len(citations)} citations; ' +
              (', '.join(f'{key}: {value}' for key, value in sorted(counts.items())) or 'no citations'),
              f'{len(rows)} migration rows; {len(sizes)} size-owner outcomes.', '']

    def table(title, headers, data):
        output.extend([f'## {title}', '', '| ' + ' | '.join(headers) + ' |',
                       '| ' + ' | '.join('---' for _ in headers) + ' |'])
        for row in data:
            output.append('| ' + ' | '.join(str(v).replace('|', '\\|').replace('\n', ' ') for v in row) + ' |')
        output.append('')

    for label, components in ((before, old_components), (after, new_components)):
        if not components:
            output.extend([f'Component manifest absent at {label}; file mode only.', ''])
    table('Component path map', ['Component', 'Old globs', 'New globs'],
          [(c, ', '.join(old_components.get(c, [])), ', '.join(new_components.get(c, [])))
           for c in sorted(old_components.keys() | new_components.keys())])
    table('PR-xx rows', ['Row', 'Today', 'Status', 'Current locations (component)'], rows)
    table('Stale citations by ticket', ['Ticket / document', 'Source', 'Citation', 'Status'], sorted(citations))
    table('Size owners by ticket', ['Ticket', 'Path', 'Lines', 'Declared owner', 'Status'], sizes)
    table('Contract versions (metadata only)', ['Contract', 'Status', 'Base main SHA', 'Date'], contracts)
    return '\n'.join(output).rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'from', 'to', 'pack', 'u8-ledger', 'out'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--pack-ref', help='Git ref containing the repository-relative pack')
    args = parser.parse_args()
    try:
        # Resolve refs before constructing revision:path expressions or diff arguments.
        before = git(args.repo, 'rev-parse', '--verify', '--end-of-options', getattr(args, 'from') + '^{commit}').decode().strip()
        after = git(args.repo, 'rev-parse', '--verify', '--end-of-options', args.to + '^{commit}').decode().strip()
        ref = git(args.repo, 'rev-parse', '--verify', '--end-of-options', args.pack_ref + '^{commit}').decode().strip() if args.pack_ref else None
        ledger = load_ledger(args.u8_ledger)
        documents = read_pack(args.repo, args.pack, ref)
        output = report(args.repo, before, after, documents, ledger)
        Path(args.out).write_text(output + '\n')
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'plan-refresh: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
