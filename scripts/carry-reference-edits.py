#!/usr/bin/env python3
"""Carry an open PR's unsplit CLI/config edits into their topic sections."""
import argparse
import csv
import difflib
import os
from pathlib import Path
import re
import subprocess


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True)


def sections(source):
    matches = list(re.finditer(r'^#{2,6} .+$', source, re.MULTILINE))
    result = {}
    for i, match in enumerate(matches):
        if match.group() in result:
            raise ValueError('duplicate headings need manual migration')
        end = matches[i + 1].start() if i + 1 < len(matches) else len(source)
        result[match.group()] = source[match.start():end]
    return source[:matches[0].start()] if matches else source, result


def merge_section(before, current, incoming):
    original = before.splitlines(keepends=True)
    edits = []
    for source in (current, incoming):
        lines = source.splitlines(keepends=True)
        for tag, start, end, left, right in difflib.SequenceMatcher(None, original, lines).get_opcodes():
            if tag == 'equal':
                continue
            edit = (start, end, lines[left:right])
            if edit in edits:
                continue
            if any(max(start, old_start) < min(end, old_end) or
                   (start == end and old_start <= start < old_end) or
                   (old_start == old_end and start <= old_start < end) or
                   start == end == old_start == old_end for old_start, old_end, _ in edits):
                raise ValueError('overlapping edits need manual migration')
            edits.append(edit)
    for start, end, replacement in sorted(edits, reverse=True):
        original[start:end] = replacement
    return ''.join(original)


def carry(root, before, after, rows):
    proposed = {}
    for source in before:
        old_prefix, old = sections(before[source])
        new_prefix, new = sections(after[source])
        # ponytail: new headings and introduction edits require manual migration.
        if old_prefix != new_prefix or old.keys() != new.keys():
            raise ValueError(f'{source}: new headings or introduction edits need manual migration')
        routes = {row['heading']: row for row in rows if row['source'] == source}
        for heading in old:
            if old[heading] == new[heading]:
                continue
            route = routes[heading]
            path = root / 'website/docs-app/reference' / route['destination']
            current = proposed.get(path, path.read_text())
            _, present = sections(current)
            old_text, new_text = old[heading], new[heading]
            for link in routes.values():
                if link['destination'] != route['destination']:
                    target = f"./{Path(link['destination']).stem}#{link['anchor']}"
                    old_text = old_text.replace(f"(#{link['anchor']})", f'({target})')
                    new_text = new_text.replace(f"(#{link['anchor']})", f'({target})')
            actual = present[heading]
            if actual.strip() == new_text.strip():
                continue
            merged = merge_section(old_text.strip() + '\n', actual.strip() + '\n', new_text.strip() + '\n')
            proposed[path] = current.replace(actual, merged.rstrip() + '\n\n', 1)
    return proposed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    root = args.root.resolve()
    if Path(git(root, 'rev-parse', '--show-toplevel').strip()).resolve() != root:
        parser.error('--root must be the repository root')
    if git(root, 'status', '--porcelain', '--', 'website/docs-app/reference').strip():
        parser.error('commit reference edits before carrying another PR')
    ref = f'refs/aiur/reference-carry/{args.pr}'
    subprocess.run(['git', '-C', str(root), 'fetch', 'origin', f'pull/{args.pr}/head:{ref}'], check=True)
    base = git(root, 'merge-base', 'origin/' + os.environ.get('AIUR_BASE_BRANCH', 'main'), ref).strip()
    with (root / 'scripts/reference-sections.tsv').open() as file:
        rows = list(csv.DictReader(file, delimiter='\t'))
    sources = sorted({row['source'] for row in rows})
    before = {name: git(root, 'show', f'{base}:website/docs-app/reference/{name}') for name in sources}
    after = {name: git(root, 'show', f'{ref}:website/docs-app/reference/{name}') for name in sources}
    try:
        proposed = carry(root, before, after, rows)
    except (KeyError, ValueError) as error:
        parser.error(str(error))
    for path, source in proposed.items():
        path.write_text(source)
    print(f'Carried PR #{args.pr} reference edits into {len(proposed)} topic pages; review and run docs gates.')


if __name__ == '__main__':
    main()
