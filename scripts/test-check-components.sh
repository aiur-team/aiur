#!/usr/bin/env bash
# Fixture tests for the stdlib ownership guard; no Elixir or Python packages.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" "$@" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
selected = set(sys.argv[2:])
checker = repo / 'scripts/check-components.py'


def component(cid, paths):
    return dict(id=cid, name=cid, layer=0, kind='required', paths=paths,
                facades=['Aiur.' + cid.title()], facade_pending=None,
                requires=[], optional=[], owns={k: [] for k in ('config', 'env', 'state', 'capabilities')}, prior=[])


def check(name, components, files, code=0, messages=(), change=None, git=False, format=False):
    if selected and name not in selected:
        return
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
        manifest = dict(manifest_version=1, components=components)
        if change:
            change(manifest)
        (root / 'components.json').write_text(json.dumps(manifest))
        for file in files:
            path = root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        if git:
            subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '--', *files], check=True)
            (root / 'src/lib/untracked.ex').touch()
        import os
        env = dict(os.environ, AIUR_COMPONENTS_ROOT=str(root))
        args = [sys.executable, str(checker), '--rules', 'ownership']
        if format:
            args.append('--format')
        result = subprocess.run(args, env=env, text=True, capture_output=True)
        output = result.stdout + result.stderr
        assert result.returncode == code, f'{name}: expected exit {code}, got {result.returncode}: {output}'
        for message in messages:
            assert message in output, f'{name}: missing {message!r}: {output}'
        if format:
            content = (root / 'components.json').read_bytes()
            assert json.loads(content) == dict(manifest, components=sorted(components, key=lambda c: (c['layer'], c['id'])))
            subprocess.run(args, env=env, check=True, capture_output=True)
            assert (root / 'components.json').read_bytes() == content, f'{name}: formatting not idempotent'
        print(f'PASS: {name}')


check('owned_once_passes', [component('a', ['src/lib/a/**']), component('b', ['packages/b/**'])],
      ['src/lib/a/a.ex', 'src/lib/a/nested/b.ex', 'packages/b/package.json'],
      messages=('all 3 source files owned', 'a: 2 files', 'b: 1 files'))
check('unowned_file_fails', [component('a', ['src/lib/a.ex'])],
      ['src/lib/a.ex', 'src/lib/unowned.ex'], 1, ('src/lib/unowned.ex: unowned file', 'nearest glob a: src/lib/a.ex'))
check('ambiguous_owner_fails', [component('a', ['src/lib/x/*.ex']), component('b', ['src/lib/x/*.ex'])],
      ['src/lib/x/file.ex'], 1, ('src/lib/x/file.ex: ambiguous ownership: a, b',))
check('more_specific_glob_wins', [component('a', ['src/lib/aiur/orchestrator/**']),
                                component('b', ['src/lib/aiur/orchestrator/comment_polling*.ex'])],
      ['src/lib/aiur/orchestrator/comment_polling.ex'], messages=('a: 0 files', 'b: 1 files'))
check('stale_glob_fails', [component('a', ['src/lib/missing/**'])], [], 1, ('src/lib/missing/**: stale path (a)',))
check('schema_violation_exits_2', [dict(component('a', []), layer=7)], [], 2, ('/components/0/layer',))
check('facade_star_requires_pending', [dict(component('a', []), facades=['*'])], [], 2,
      ('/components/0/facade_pending',))
check('facade_star_with_pending_passes', [dict(component('a', ['src/lib/a.ex']), facades=['*'], facade_pending='MP-R1-C1-T02')],
      ['src/lib/a.ex'])
check('single_star_stays_in_segment', [component('a', ['src/lib/x/*.ex'])],
      ['src/lib/x/a.ex', 'src/lib/x/nested/a.ex'], 1, ('src/lib/x/nested/a.ex: unowned file',))
check('double_star_matches_zero_depth', [component('a', ['src/lib/**/*.ex'])],
      ['src/lib/a.ex', 'src/lib/nested/a.ex'], messages=('a: 2 files',))
check('same_component_overlap_passes', [component('a', ['src/lib/x/*.ex', 'src/lib/x/*a.ex'])], ['src/lib/x/a.ex'])
check('fallback_excludes_build_outputs', [component('a', ['src/lib/a.ex'])],
      ['src/lib/a.ex', 'packages/x/node_modules/a.js', 'src/lib/_build/a.ex', 'packages/x/dist/a.js', 'src/lib/deps/a.ex'],
      messages=('all 1 source files owned',))
check('git_uses_tracked_files', [component('a', ['src/lib/a.ex'])], ['src/lib/a.ex'],
      messages=('all 1 source files owned',), git=True)
check('outside_roots_can_have_paths', [component('a', ['src/lib/a.ex', 'website/docs/**'])],
      ['src/lib/a.ex', 'website/docs/readme.md'], messages=('all 1 source files owned',))
check('format_is_deterministic', [component('z', ['src/lib/z.ex']), component('a', ['src/lib/a.ex'])],
      ['src/lib/z.ex', 'src/lib/a.ex'], format=True)
check('unknown_component_key_fails', [dict(component('a', []), extra=True)], [], 2, ('/components/0/extra',))
check('unknown_root_key_fails', [component('a', [])], [], 2, ('/extra',),
      change=lambda m: m.update(extra=True))
check('unknown_dependency_fails', [dict(component('a', []), requires=['absent'])], [], 2,
      ('/components/0/requires: unknown component absent',))
check('duplicate_component_fails', [component('a', []), component('a', [])], [], 2, ('duplicate component id',))
check('relative_paths_required', [component('a', ['../src/lib/a.ex'])], [], 2, ('/components/0/paths',))
check('binary_kind_required', [dict(component('a', []), kind='experimental')], [], 2, ('/components/0/kind',))
check('boolean_layer_rejected', [dict(component('a', []), layer=True)], [], 2, ('/components/0/layer',))
check('private_namespaces_supported', [dict(component('a', ['src/lib/a.ex']), private_namespaces=['Aiur.Codex.'])], ['src/lib/a.ex'])
check('future_public_fields_supported', [dict(component('a', ['src/lib/a.ex']), summary='A', status='core', install='', docs='', feature_id='MP-R1')],
      ['src/lib/a.ex'], change=lambda m: m.update(features=[], directory_published=False))
if not selected:
    with tempfile.TemporaryDirectory() as directory:
        import os
        root = Path(directory)
        shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
        (root / 'components.json').write_text('{broken')
        result = subprocess.run([sys.executable, str(checker)], env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)),
                                capture_output=True, text=True)
        assert result.returncode == 2 and 'components: components.json:' in result.stderr
        print('PASS: malformed_json_exits_2')
print('check-components guard: all selected cases passed')
PY
