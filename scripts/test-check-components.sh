#!/usr/bin/env bash
# Ownership fixtures need only Python; --with-elixir requires reference fixtures.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" "$@" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
with_node = '--with-node' in sys.argv[2:]
with_elixir = '--with-elixir' in sys.argv[2:]
selected = set(sys.argv[2:]) - {'--with-node', '--with-elixir'}
checker = repo / 'scripts/check-components.py'
ran = set()


def component(cid, paths):
    return dict(id=cid, name=cid, layer=0, kind='required', paths=paths,
                facades=['Aiur.' + cid.title()], facade_pending=None,
                requires=[], optional=[], owns={k: [] for k in ('config', 'env', 'state', 'capabilities')}, prior=[])


def check(name, components, files, code=0, messages=(), change=None, git=False, format=False, declarations=None, rules='ownership', links=None):
    if selected and name not in selected:
        return
    ran.add(name)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
        components = json.loads(json.dumps(components))
        if declarations is None:
            declarations = {
                'src/lib/aiur/config/schema.ex': '    embeds_one(:fixture, Fixture)\n    field(:scalar, :integer)\n',
                'src/lib/aiur/env/schema.ex': '    {"AIUR_FIXTURE", type: :string}\n',
                'src/lib/aiur/config/paths.ex': '  def fixture_dir, do: "/fixture"\n'}
            components[0]['paths'].extend(declarations)
            components[0]['owns'].update(config=['fixture', 'scalar'], env=['AIUR_FIXTURE'], state=['fixture_dir'])
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
        for file, content in declarations.items():
            path = root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        if git:
            subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '--', *files, *declarations], check=True)
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
      messages=('all 6 source files owned', 'a: 5 files', 'b: 1 files'))
check('unowned_file_fails', [component('a', ['src/lib/a.ex'])],
      ['src/lib/a.ex', 'src/lib/unowned.ex'], 1, ('src/lib/unowned.ex: unowned file', 'nearest glob a: src/lib/a.ex'))
check('ambiguous_owner_fails', [component('a', ['src/lib/x/*.ex']), component('b', ['src/lib/x/*.ex'])],
      ['src/lib/x/file.ex'], 1, ('src/lib/x/file.ex: ambiguous ownership: a, b',))
check('more_specific_glob_wins', [component('a', ['src/lib/aiur/orchestrator/**']),
                                component('b', ['src/lib/aiur/orchestrator/comment_polling*.ex'])],
      ['src/lib/aiur/orchestrator/comment_polling.ex'], messages=('a: 3 files', 'b: 1 files'))
check('stale_glob_fails', [component('a', ['src/lib/missing/**'])], [], 1, ('src/lib/missing/**: stale path (a)',))
check('schema_violation_exits_2', [dict(component('a', []), layer=7)], [], 2, ('/components/0/layer',))
check('facade_star_requires_pending', [dict(component('a', []), facades=['*'])], [], 2,
      ('/components/0/facade_pending',))
check('facade_star_with_pending_passes', [dict(component('a', ['src/lib/a.ex']), facades=['*'], facade_pending='MP-R1-C1-T02')],
      ['src/lib/a.ex'])
check('single_star_stays_in_segment', [component('a', ['src/lib/x/*.ex'])],
      ['src/lib/x/a.ex', 'src/lib/x/nested/a.ex'], 1, ('src/lib/x/nested/a.ex: unowned file',))
check('double_star_matches_zero_depth', [component('a', ['src/lib/**/*.ex'])],
      ['src/lib/a.ex', 'src/lib/nested/a.ex'], messages=('a: 5 files',))
check('same_component_overlap_passes', [component('a', ['src/lib/x/*.ex', 'src/lib/x/*a.ex'])], ['src/lib/x/a.ex'])
check('fallback_excludes_build_outputs', [component('a', ['src/lib/a.ex'])],
      ['src/lib/a.ex', 'packages/x/node_modules/a.js', 'src/lib/_build/a.ex', 'packages/x/dist/a.js', 'src/lib/deps/a.ex'],
      messages=('all 4 source files owned',))
check('git_uses_tracked_files', [component('a', ['src/lib/a.ex'])], ['src/lib/a.ex'],
      messages=('all 4 source files owned',), git=True)
check('outside_roots_can_have_paths', [component('a', ['src/lib/a.ex', 'website/docs/**'])],
      ['src/lib/a.ex', 'website/docs/readme.md'], messages=('all 4 source files owned',))
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
    imports('multiline_external_resource_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@external_resource Path.expand(\n  "../../packages/a/x.json",\n  __DIR__\n)'})
    imports('multiline_resource_attribute_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@resource Path.expand(\n  "../../packages/a/x.json",\n  __DIR__\n)\n@external_resource @resource'})
    for protocol in ('file', 'link'):
        imports(protocol + '_dependency_into_sibling_fails', 'import "b";', 1, ('R-client', 'packages/b'),
                dependencies={'b': protocol + ':../b'}, extra={'packages/b/package.json': '{"name":"b"}'})
    imports('file_dependency_into_src_fails', 'import "daemon";', 1, ('R-client', 'src/lib'),
            dependencies={'daemon': 'file:../../src/lib'}, extra={'src/lib/foo.ex': ''})
    imports('file_dependency_contracts_allowed', 'import "@aiur/contracts";',
            dependencies={'@aiur/contracts': 'file:../aiur-contracts'},
            extra={'packages/aiur-contracts/package.json': '{"name":"@aiur/contracts"}'})
    imports('parenthesized_external_resource_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@external_resource(\n  "../../packages/a/x.json"\n)'})
    imports('resource_alias_chain_reported', '', 1, ('R-reverse-resource',),
            extra={'src/lib/foo.ex': '@path "../../packages/a/x.json"\n@resource @path\n@external_resource @resource'})
    imports('external_resource_allowlisted', '', messages=('allowlisted', 'MP-R6 owns'),
            extra={'src/lib/aiur_web/streamdeck_key_face_contract.ex':
                   '@contract_path Path.expand("../../../packages/streamdeck/src/key-face-contract.json", __DIR__)\n@external_resource @contract_path',
                   'packages/streamdeck/package.json': '{"name":"streamdeck"}'})
    imports('allowlist_is_path_specific', '', 1, ('R-reverse-resource',),
            extra={'src/lib/aiur_web/streamdeck_key_face_contract.ex':
                   '@external_resource "../../../packages/a/other.json"'})

declarations = {
    'src/lib/aiur/config/schema.ex': '    embeds_one(:tracker, Tracker)\n    field(:debug, :boolean)\n',
    'src/lib/aiur/env/schema.ex': '    {"AIUR_FIXTURE", type: :string}\n',
    'src/lib/aiur/config/paths.ex': '  def fixture_dir, do: "/fixture"\n  defp private_path, do: "/private"\n  def repo_name, do: "repo"\n'}
owner = component('a', list(declarations))
owner['owns'].update(config=['tracker', 'debug'], env=['AIUR_FIXTURE'], state=['fixture_dir'])
check('declarations_owned_once_passes', [owner], [], declarations=declarations,
      messages=('1 sections, 1 fields, 1 env vars, 1 state paths owned once',))
for kind, name in [('config', 'tracker'), ('config', 'debug'), ('env', 'AIUR_FIXTURE'), ('state', 'fixture_dir')]:
    check(f'{name}_without_owner_fails', [owner], [], 1, (f"'{name}' has no owner",),
          change=lambda m, k=kind, n=name: m['components'][0]['owns'][k].remove(n), declarations=declarations)
    second = component('b', [])
    second['owns'][kind] = [name]
    check(f'{name}_owned_twice_fails', [owner, second], [], 1, (f"'{name}' owned twice: a, b",), declarations=declarations)
    check(f'{name}_stale_owner_fails', [owner], [], 1, ('is stale (a)',),
          change=lambda m, k=kind, n=name: m['components'][0]['owns'][k].append('STALE' if k == 'env' else 'stale_path'), declarations=declarations)
for kind, file in [('config', 'src/lib/aiur/config/schema.ex'), ('env', 'src/lib/aiur/env/schema.ex'), ('state', 'src/lib/aiur/config/paths.ex')]:
    check(f'zero_{kind}_matches_is_broken_matcher', [owner], [], 2,
          (f'O-{kind}: matcher is broken, not the schema',), declarations=dict(declarations, **{file: '# no declarations'}))
check('new_section_without_owner_fails', [owner], [], 1, ("'extra' has no owner",),
      declarations=dict(declarations, **{'src/lib/aiur/config/schema.ex': declarations['src/lib/aiur/config/schema.ex'] + '    embeds_one(:extra, Extra)\n'}))
check('new_env_without_owner_fails', [owner], [], 1, ("'AIUR_NEW' has no owner",),
      declarations=dict(declarations, **{'src/lib/aiur/env/schema.ex': declarations['src/lib/aiur/env/schema.ex'] + '    {"AIUR_NEW", type: :string}\n'}))
check('unknown_shared_component_fails', [dict(owner, shared_with=['absent'])], [], 2,
      ('unknown component absent',), declarations=declarations)
for kind, name in [('config', 'bad.section'), ('env', 'lowercase'), ('state', 'repo_name')]:
    check(f'invalid_{kind}_format_fails', [owner], [], 2, ('invalid string',),
          change=lambda m, k=kind, n=name: m['components'][0]['owns'][k].append(n), declarations=declarations)
if not selected or 'real_tree_passes' in selected:
    ran.add('real_tree_passes')
    result = subprocess.run([sys.executable, str(checker), '--rules', 'ownership'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert '21 sections, 7 fields, 70 env vars, 15 state paths owned once' in result.stdout
    print('PASS: real_tree_passes')
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
if with_node and (not selected or 'missing_typescript_exits_2' in selected):
    ran.add('missing_typescript_exits_2')
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        shutil.copyfile(checker, root / 'check-components.py')
        shutil.copytree(repo / 'scripts/components', root / 'components', ignore=shutil.ignore_patterns('node_modules'))
        result = subprocess.run([sys.executable, str(root / 'check-components.py')],
                                env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(repo)), capture_output=True, text=True)
        assert result.returncode == 2, result.stdout + result.stderr
        assert 'TypeScript missing; run npm ci --prefix scripts/components --ignore-scripts' in result.stderr, result.stderr
        assert 'ERR_MODULE_NOT_FOUND' not in result.stderr, result.stderr
        print('PASS: missing_typescript_exits_2')
if with_elixir and not shutil.which('elixir'):
    sys.exit('Elixir missing; install via mise (--with-elixir cannot skip fixtures)')
if not with_elixir:
    print('SKIP: Elixir reference fixtures (use --with-elixir in lint)')
else:
    import os

    def reference_check(name, fixture, code=0, messages=(), source=None, change=None, args=(), verify=None):
        if selected and name not in selected:
            return
        ran.add(name)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(repo / 'scripts/components/fixtures' / fixture, root, dirs_exist_ok=True)
            shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
            if source is not None:
                (root / 'src/lib/a.ex').write_text(source)
            if change:
                change(root)
            command = [sys.executable, str(checker), '--rules', 'elixir', '--require-elixir', *args]
            result = subprocess.run(command, env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)),
                                    capture_output=True, text=True)
            output = result.stdout + result.stderr
            assert result.returncode == code, f'{name}: expected {code}, got {result.returncode}: {output}'
            for message in messages:
                assert message in output, f'{name}: missing {message!r}: {output}'
            if verify:
                verify(root, command)
            print(f'PASS: {name}')

    reference_check('undeclared_dependency_fails', 'undeclared_dependency_fails', 1, ('R-declared a -> B.Facade',))
    reference_check('declared_facade_passes', 'declared_facade_passes')
    reference_check('private_module_fails', 'private_module_fails', 1, ('R-private a -> B.Internal',))
    reference_check('facade_star_allows_any', 'facade_star_allows_any')
    reference_check('alias_resolution_counts', 'alias_resolution_counts', 1, ('R-private a -> B.Internal',))
    reference_check('doc_mentions_ignored', 'doc_mentions_ignored', messages=('R-private: 0',))
    reference_check('allowlisted_violation_passes', 'allowlisted_violation_passes', messages=('R-private: 1',))
    reference_check('new_violation_beside_allowlist_fails', 'new_violation_beside_allowlist_fails', 1,
                    ('R-private a -> B.Other',))
    reference_check('composition_root_exempt', 'composition_root_exempt', messages=('R-private: 0', 'R-declared: 0'))
    reference_check('alias_as_resolves', 'private_module_fails', 1, ('R-private a -> B.Internal',),
                    source='defmodule A do\n alias B.Internal, as: Hidden\n def f, do: Hidden.f()\nend\n')
    reference_check('alias_scope_does_not_leak', 'private_module_fails', messages=('R-private: 0',),
                    source='defmodule A do\n def f do\n alias B.Internal, as: Hidden\n end\n def g, do: Hidden.f()\nend\n')
    for name, form in [('import_reference_counts', 'import B.Internal'), ('use_reference_counts', 'use B.Internal'),
                       ('behaviour_reference_counts', '@behaviour B.Internal'),
                       ('type_reference_counts', '@spec f() :: B.Internal.t()')]:
        reference_check(name, 'private_module_fails', 1, ('R-private a -> B.Internal',),
                        source=f'defmodule A do\n {form}\nend\n')
    reference_check('parse_failure_exits_2', 'private_module_fails', 2, ('src/lib/a.ex', 'module walker failed'),
                    source='defmodule A do\n')
    reference_check('unresolved_internal_is_warning', 'private_module_fails', messages=('1 unresolved internal targets',),
                    source='defmodule A do\n Aiur.Generated.f()\n Enum.map([])\nend\n')

    def optional(root):
        path = root / 'components.json'
        manifest = json.loads(path.read_text())
        manifest['components'][0]['requires'] = []
        manifest['components'][0]['optional'] = ['b']
        path.write_text(json.dumps(manifest))

    reference_check('optional_facade_passes', 'declared_facade_passes', change=optional)
    reference_check('facade_is_exact', 'private_module_fails', 1, ('R-private a -> B.Internal',))
    reference_check('primary_source_module', 'private_module_fails', 1, ('src/lib/a.ex:4 (A)',),
                    source='defmodule A do\nend\ndefmodule Second do\n B.Internal.f()\nend\n')
    reference_check('baseline_overwrite_refused', 'allowlisted_violation_passes', 2,
                    ('baseline already exists',), args=('--write-baseline',))

    def malformed_allowlist(root):
        (root / 'scripts/components/allowlist/a.tsv').write_text('R-private\tB.Internal\n')

    reference_check('malformed_allowlist_exits_2', 'allowlisted_violation_passes', 2,
                    ('expected rule, target_module, reason TSV',), change=malformed_allowlist)

    def committed_fixture(root):
        subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                        'commit', '-qm', 'Fixture baseline'], check=True)

    def verify_baseline(root, command):
        sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        path = root / 'scripts/components/allowlist/a.tsv'
        expected = f'# rule\ttarget_module\treason\nR-private\tB.Internal\tbaseline {sha}\n'
        assert path.read_text() == expected, 'baseline must contain the actual violation and implementation SHA'
        command = [arg for arg in command if arg != '--write-baseline']
        result = subprocess.run(command, env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)), capture_output=True)
        assert result.returncode == 0, result.stderr

    reference_check('baseline_generation_and_recheck', 'private_module_fails', change=committed_fixture,
                    args=('--write-baseline',), verify=verify_baseline)

    def untracked_syntax_error(root):
        committed_fixture(root)
        (root / 'src/lib/untracked.ex').write_text('defmodule Unfinished do\n')

    reference_check('untracked_parse_error_ignored', 'declared_facade_passes', change=untracked_syntax_error,
                    messages=('all 2 source files owned',))
    reference_check('nested_namespace_resolves', 'private_module_fails', 1,
                    ('R-private a -> Aiur.Parent.Aiur.Child',),
                    source='defmodule A do\n Aiur.Parent.Aiur.Child.f()\nend\n',
                    change=lambda root: (root / 'src/lib/b.ex').write_text(
                        'defmodule Aiur.Parent do\n defmodule Aiur.Child do\n end\nend\n'))
    reference_check('absolute_nested_module_resolves', 'private_module_fails', 1,
                    ('R-private a -> B.Internal',),
                    change=lambda root: (root / 'src/lib/b.ex').write_text(
                        'defmodule Parent do\n defmodule Elixir.B.Internal do\n end\nend\n'))

    def verify_application_primary(root, command):
        result = subprocess.run(['elixir', str(repo / 'scripts/components/module_references.exs'), str(root)],
                                text=True, capture_output=True, check=True)
        assert 'R\tsrc/lib/aiur.ex\tAiur.Application\tB.Internal\t' in result.stdout

    reference_check('application_primary_module', 'composition_root_exempt', verify=verify_application_primary)

    if not selected or 'missing_elixir_exits_2' in selected:
        ran.add('missing_elixir_exits_2')
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(checker), '--rules', 'elixir', '--require-elixir'],
                                    env=dict(os.environ, PATH=directory), capture_output=True, text=True)
            assert result.returncode == 2 and 'Elixir missing; install via mise' in result.stderr, result.stderr
            print('PASS: missing_elixir_exits_2')

assert not selected - ran, f'unknown/unexecuted cases: {selected - ran}'
print('check-components guard: all selected cases passed')
PY
