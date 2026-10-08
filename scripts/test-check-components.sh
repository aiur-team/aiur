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
with_node = '--with-node' in sys.argv[2:]
selected = set(sys.argv[2:]) - {'--with-node'}
checker = repo / 'scripts/check-components.py'
ran = set()


def component(cid, paths):
    return dict(id=cid, name=cid, layer=0, kind='required', paths=paths,
                facades=['Aiur.' + cid.title()], facade_pending=None,
                requires=[], optional=[], owns={k: [] for k in ('config', 'env', 'state', 'capabilities')}, prior=[])


def check(name, components, files, code=0, messages=(), change=None, git=False, format=False, rules='ownership', links=None):
    if selected and name not in selected:
        return
    ran.add(name)
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
            path.write_text(files[file] if isinstance(files, dict) else '')
        for link, target in (links or {}).items():
            path = root / link
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(root / target, target_is_directory=True)
        if git:
            subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '--', *files], check=True)
            (root / 'src/lib/untracked.ex').touch()
        import os
        env = dict(os.environ, AIUR_COMPONENTS_ROOT=str(root))
        args = [sys.executable, str(checker), '--rules', rules]
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
check('future_public_fields_supported', [dict(component('a', ['src/lib/a.ex']), summary='A', status='core', install={'type': 'included'}, docs=['concepts/build-orders.md'], feature_id='MP-R1')],
      ['src/lib/a.ex'], change=lambda m: m.update(features=[], directory_published=False))
check('required_property_fails', [component('a', [])], [], 2, ('/components/0/name: required property',),
      change=lambda m: m['components'][0].pop('name'))
check('empty_name_fails', [dict(component('a', []), name='')], [], 2, ('/components/0/name: empty string',))
check('duplicate_paths_fail', [component('a', ['src/lib/a.ex', 'src/lib/a.ex'])], ['src/lib/a.ex'], 2,
      ('/components/0/paths: duplicate items',))
if with_node:
    def imports(name, source, code=0, messages=(), dependencies=None, extra=None, links=None):
        files = {'packages/a/package.json': json.dumps(dict(name='a', dependencies=dependencies or {})),
                 'packages/a/src/x.ts': source}
        files.update(extra or {})
        components = [dict(component('clients', ['packages/**']), layer=5)]
        if any(file.startswith('src/lib/') for file in files):
            components.append(component('daemon', ['src/lib/**']))
        check(name, components, files, code, messages, rules='all', links=links)

    imports('relative_inside_package_passes', 'import "./y.js";', extra={'packages/a/src/y.ts': ''})
    imports('import_into_src_fails', 'import "../../../src/lib/foo.js";', 1,
            ('R-client', 'src/lib/foo.js'))
    imports('sibling_package_fails', 'import "../../b/src/z.js";', 1, ('R-client', 'packages/b/src/z.js'),
            extra={'packages/b/package.json': '{"name":"b"}', 'packages/b/src/z.js': ''})
    imports('undeclared_npm_dep_fails', 'import "left-pad";', 1, ('undeclared npm dependency left-pad',))
    imports('computed_import_fails', 'import(`./${name}.js`);', 1, ('unanalyzable',))
    imports('computed_require_fails', 'require(name);', 1, ('unanalyzable',))
    imports('comment_mention_ignored', '// from "to top"\nconst text = `from "zero usage"`;')
    imports('contracts_import_allowed', 'import "../../aiur-contracts/src/z.js";',
            dependencies={'@aiur/contracts': '*'},
            extra={'packages/aiur-contracts/package.json': '{"name":"@aiur/contracts"}',
                   'packages/aiur-contracts/src/z.js': ''})
    imports('contracts_must_be_declared', 'import "../../aiur-contracts/src/z.js";', 1,
            ('aiur-contracts must be declared',),
            extra={'packages/aiur-contracts/package.json': '{"name":"@aiur/contracts"}',
                   'packages/aiur-contracts/src/z.js': ''})
    imports('declared_npm_and_builtins_pass', 'import "@scope/dep/subpath"; import "node:fs"; import "node:test"; require("fs/promises");',
            dependencies={'@scope/dep': '*'})
    imports('bare_prefix_only_builtin_fails', 'import "test";', 1, ('undeclared npm dependency test',))
    imports('unknown_node_builtin_fails', 'import "node:made-up";', 1, ('undeclared npm dependency',))
    for name, source in {
        'export_into_src_fails': 'export * from "../../../src/lib/foo.js";',
        'import_equals_into_src_fails': 'import x = require("../../../src/lib/foo.js");',
        'import_type_into_src_fails': 'type X = import("../../../src/lib/foo.js").X;',
        'literal_dynamic_into_src_fails': 'import("../../../src/lib/foo.js");',
        'literal_require_into_src_fails': 'require("../../../src/lib/foo.js");',
    }.items():
        imports(name, source, 1, ('R-client', 'src/lib/foo.js'))
    imports('test_outside_src_fails', '', 1, ('R-client', 'src/lib/foo.js'),
            extra={'packages/a/test/x.test.mts': 'import "../../../src/lib/foo.js";'})
    imports('symlinked_npm_into_src_fails', 'import "leak";', 1, ('R-client', 'src/lib/leak/index.js'),
            dependencies={'leak': '*'}, extra={'src/lib/leak/index.js': ''},
            links={'packages/a/node_modules/leak': 'src/lib/leak'})
    imports('relative_symlink_into_src_fails', 'import "./leak/index.js";', 1, ('R-client', 'src/lib/leak/index.js'),
            extra={'src/lib/leak/index.js': ''}, links={'packages/a/src/leak': 'src/lib/leak'})
    imports('missing_package_json_exits_2', '', 2, ('package.json',), extra={'packages/b/src/x.ts': ''})
    imports('external_resource_into_packages_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@external_resource "../../packages/a/x.json"'})
    imports('external_resource_attribute_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@resource Path.expand("../../packages/a/x.json", __DIR__)\n@external_resource @resource'})
    imports('external_resource_allowlisted', '', messages=('allowlisted', 'MP-R6 owns'),
            extra={'src/lib/aiur_web/streamdeck_key_face_contract.ex':
                   '@contract_path Path.expand("../../../packages/streamdeck/src/key-face-contract.json", __DIR__)\n@external_resource @contract_path',
                   'packages/streamdeck/package.json': '{"name":"streamdeck"}'})
    imports('allowlist_is_path_specific', '', 1, ('R-reverse-resource',),
            extra={'src/lib/aiur_web/streamdeck_key_face_contract.ex':
                   '@external_resource "../../../packages/a/other.json"'})

if not selected or 'malformed_json_exits_2' in selected:
    ran.add('malformed_json_exits_2')
    with tempfile.TemporaryDirectory() as directory:
        import os
        root = Path(directory)
        shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
        (root / 'components.json').write_text('{broken')
        result = subprocess.run([sys.executable, str(checker)], env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)),
                                capture_output=True, text=True)
        assert result.returncode == 2 and 'components: components.json:' in result.stderr
        print('PASS: malformed_json_exits_2')
assert not selected - ran, f'unknown/unexecuted cases: {selected - ran}'
print('check-components guard: all selected cases passed')
PY
