"""Tracked-text census; totals include copies, churn excludes their reused lines."""

from fnmatch import fnmatchcase
import json

# First match wins. Keep all area rules here, including lockfile names.
AREA_RULES = (
    ('generated/vendor', ('src/priv/static/vendor/*', '*.min.js', 'package-lock.json',
                          'npm-shrinkwrap.json', '*.lock', 'bun.lockb', 'pnpm-lock.yaml')),
    ('test', ('src/test/*', '*test*')),
    ('source', ('src/lib/*',)),
    ('docs', ('docs/*', 'website/docs-app/*', '*.md')),
    ('other', ('*',)),
)


def area(path):
    name = path.decode('utf-8', errors='surrogateescape')
    basename = name.rsplit('/', 1)[-1]
    return next(label for label, patterns in AREA_RULES
                if any(fnmatchcase(name, p) or fnmatchcase(basename, p) for p in patterns))


def changes(raw):
    """Read NUL-delimited numstat, including two-path rename/copy records."""
    entries = iter(raw.split(b'\0'))
    for entry in entries:
        if not entry:
            continue
        added, removed, path = entry.split(b'\t', 2)
        old, new = (next(entries), next(entries)) if not path else (path, path)
        yield added, removed, old, new


def text_churn(git, base, head, old, new):
    # Blob IDs remove path attributes that can suppress numstat even with --text.
    blobs = [git('rev-parse', f'{rev}:{path.decode("utf-8", errors="surrogateescape")}').decode().strip()
             for rev, path in ((base, old), (head, new))]
    raw = git('diff', '--text', '--no-ext-diff', '--no-textconv', '--numstat', *blobs, '--')
    return tuple(raw.split(b'\t', 2)[:2]) if raw else (b'0', b'0')


def line_churn(added, removed, before, after, git, base, head, old, new):
    if added != b'-':
        return int(added), int(removed)
    if old not in before:
        return after[new], 0
    if new not in after:
        return 0, before[old]
    return tuple(map(int, text_churn(git, base, head, old, new)))


def record_change(rows, before, after, change, git, base, head):
    added, removed, old, new = change
    previous, current = before.get(old, 0), after.get(new, 0)
    binary = 'binary' in (previous, current)
    if binary or 'symlink' in (previous, current):
        # Git has no usable text numstat for these transitions; retain the text side.
        if isinstance(previous, int):
            rows[area(old)]['removed'] += previous
        if isinstance(current, int):
            rows[area(new)]['added'] += current
        return int(binary)
    added, removed = line_churn(added, removed, before, after, git, base, head, old, new)
    rows[area(new)]['added'] += added
    rows[area(old)]['removed'] += removed
    if old != new:
        rows[area(old)]['moved'] += max(0, min(previous - removed, current - added))
    return 0


def census(before, after, git, base, head):
    rows = {label: dict(base=0, head=0, added=0, removed=0, moved=0) for label, _ in AREA_RULES}
    for tree, column in ((before, 'base'), (after, 'head')):
        for path, count in tree.items():
            if isinstance(count, int):
                rows[area(path)][column] += count
    raw = git('diff', '--no-ext-diff', '--no-textconv', '--text', '-M', '-C', '--find-copies-harder',
              '--numstat', '-z', base, head, '--')
    binary_changes = sum(record_change(rows, before, after, change, git, base, head) for change in changes(raw))
    return {'areas': rows, 'binary_changes': binary_changes}


def render(report, as_json):
    if as_json:
        print(json.dumps(report, sort_keys=True))
        return
    print('| Area | Base | Head | Added | Removed | Moved |')
    print('| --- | ---: | ---: | ---: | ---: | ---: |')
    for label, row in report['areas'].items():
        print('| ' + ' | '.join([label, *(str(row[c]) for c in ('base', 'head', 'added', 'removed', 'moved'))]) + ' |')
    print(f'\nBinary changes: {report["binary_changes"]} (files, not lines).')
    print('Moves/copies are credited to the base path area; symlink blobs are excluded.')
    print('Base/head are tree totals; copies and cross-area moves can change totals without text churn.')
