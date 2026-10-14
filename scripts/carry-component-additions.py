#!/usr/bin/env python3
"""Carry an open PR's added manifest members into the split layout by ID/key."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import runpy
import os
from components.manifest import read_manifest, write_manifest


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True)


def at_ref(root, ref):
    manifest = json.loads(git(root, 'show', f'{ref}:components.json'))
    if 'component_files' in manifest:
        manifest['components'] = [json.loads(git(root, 'show', f'{ref}:{name}')) for name in manifest.pop('component_files')]
    return manifest


def carry(current, before, after, key=''):
    """Refuse removals and scalar edits; append each new member at most once."""
    if before == after:
        return current
    if isinstance(before, dict) and isinstance(after, dict):
        if before.keys() != after.keys():
            raise ValueError(f'{key}: changed object keys need manual migration')
        result = copy.deepcopy(current)
        for name in before:
            result[name] = carry(current[name], before[name], after[name], f'{key}.{name}')
        return result
    if isinstance(before, list) and isinstance(after, list):
        if any(item not in after for item in before):
            raise ValueError(f'{key}: removals need manual migration')
        return current + [item for item in after if item not in before and item not in current]
    raise ValueError(f'{key}: scalar edits need manual migration')


def replay(current, before, after):
    result = copy.deepcopy(current)
    old = {c['id']: c for c in before['components']}
    new = {c['id']: c for c in after['components']}
    present = {c['id']: c for c in current['components']}
    if old.keys() - new.keys():
        raise ValueError('component removals need manual migration')
    for cid, component in new.items():
        if cid not in old:
            if cid in present and present[cid] != component:
                raise ValueError(f'{cid}: new component already exists with different content')
            present[cid] = component
        else:
            if cid not in present:
                raise ValueError(f'{cid}: component no longer exists')
            present[cid] = carry(present[cid], old[cid], component, cid)
    result['components'] = list(present.values())
    for key in before.keys() | after.keys():
        if key == 'components':
            continue
        if key not in before or key not in after:
            raise ValueError(f'{key}: new/removed metadata needs manual migration')
        result[key] = carry(current[key], before[key], after[key], key)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    root = args.root.resolve()
    if Path(git(root, 'rev-parse', '--show-toplevel').strip()).resolve() != root:
        parser.error('--root must be the repository root')
    if git(root, 'status', '--porcelain', '--', 'components.json', 'components').strip():
        parser.error('commit manifest edits before carrying another PR')
    ref = f'refs/aiur/carry/{args.pr}'
    subprocess.run(['git', '-C', str(root), 'fetch', 'origin', f'pull/{args.pr}/head:{ref}'], check=True)
    base = git(root, 'merge-base', 'origin/' + os.environ.get('AIUR_BASE_BRANCH', 'main'), ref).strip()
    validate = runpy.run_path(str(Path(__file__).with_name('check-components.py')))['validate_manifest']
    schema = json.loads((root / 'components.schema.json').read_text())
    try:
        before = validate(at_ref(root, base), schema)
        after = validate(at_ref(root, ref), schema)
        result = replay(read_manifest(root), before, after)
        validate(result, schema)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    write_manifest(root, result)
    print(f'Carried PR #{args.pr} additions by component ID/key; review the diff and run component gates.')


if __name__ == '__main__':
    main()
