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
ran = set()


def component(cid, paths):
    return dict(id=cid, name=cid, layer=0, kind='in-app', dependency_kind='required', paths=paths,
                summary='Provides fixture behavior.', status='core', install={'type': 'included'},
                docs=[], config=[], env=[], capabilities=[],
                facades=['Aiur.' + cid.title()], facade_pending=None,
                requires=[], optional=[], owns={k: [] for k in ('config', 'env', 'state', 'capabilities')}, prior=[])


def check(name, components, files, code=0, messages=(), change=None, git=False, format=False, declarations=None):
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
        manifest = dict(manifest_version=1, components=components, features=[])
        if change:
            change(manifest)
        (root / 'components.json').write_text(json.dumps(manifest))
        for file in files:
            path = root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
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
check('public_kind_required', [dict(component('a', []), kind='experimental')], [], 2, ('/components/0/kind',))
check('boolean_layer_rejected', [dict(component('a', []), layer=True)], [], 2, ('/components/0/layer',))
check('private_namespaces_supported', [dict(component('a', ['src/lib/a.ex']), private_namespaces=['Aiur.Codex.'])], ['src/lib/a.ex'])
check('future_public_fields_supported', [dict(component('a', ['src/lib/a.ex']), summary='Provides fixture behavior.', status='core', install={'type': 'included'}, docs=['concepts/build-orders.md'], feature_id='MP-R1')],
      ['src/lib/a.ex'], change=lambda m: m.update(features=[], directory_published=False))
check('required_property_fails', [component('a', [])], [], 2, ('/components/0/name: required property',),
      change=lambda m: m['components'][0].pop('name'))
check('empty_name_fails', [dict(component('a', []), name='')], [], 2, ('/components/0/name: empty string',))
check('duplicate_paths_fail', [component('a', ['src/lib/a.ex', 'src/lib/a.ex'])], ['src/lib/a.ex'], 2,
      ('/components/0/paths: duplicate items',))
# Public contract fixtures run through the real checker and schema.
base = component('a', ['src/lib/a.ex'])
planned = dict(component('future', []), status='planned', added_by='MP-N2')
feature = dict(id='MP-N2', name='Pairing', summary='Pairs a device with a machine.',
               extends=['a'], adds=['future'], public=False, shipped_in=None)

def public_case(name, change, components=None, code=2, messages=()):
    check(name, components or [base, planned], ['src/lib/a.ex'], code, messages,
          change=lambda m: (m.update(features=[json.loads(json.dumps(feature))]), change(m)))

public_case('missing_public_field_fails', lambda m: m['components'][0].pop('summary'),
            messages=('a:', '/summary: required property'))
public_case('planned_with_paths_fails', lambda m: (m['components'][0]['paths'].remove('src/lib/a.ex'),
                                                m['components'][1].update(paths=['src/lib/a.ex'])),
            messages=('future:', '/paths: too many items'))
public_case('planned_without_added_by_fails', lambda m: m['components'][1].pop('added_by'),
            messages=('/added_by: required property',))
public_case('feature_adds_non_planned_fails', lambda m: m['features'][0]['adds'].append('a'),
            messages=('adds a must be planned',))
public_case('planned_feature_component_unlisted_fails', lambda m: m['features'][0].update(adds=[]),
            messages=('future: missing from MP-N2 adds',))
public_case('planned_feature_wrong_owner_fails', lambda m: m['features'][0].update(id='MP-N3'),
            messages=('future: missing from MP-N2 adds',))
public_case('planned_bucket1_component_exempt_passes', lambda m: m['components'][1].update(added_by='MP-R1'),
            code=0)
public_case('planned_bucket1_unlisted_passes', lambda m: (m['components'][1].update(added_by='MP-R1'),
                                                       m['features'][0].update(adds=[])), code=0)
for field, value, name in [
    ('summary', 'Calls Aiur.Orchestrator.', 'summary_with_module_name_fails'),
    ('summary', 'Reads src/lib.', 'summary_with_path_fails'),
    ('summary', 'Handles issue #123.', 'summary_with_issue_fails'),
    ('summary', 'Stores a password.', 'summary_with_secret_fails'),
    ('summary', 'Uses 192.168.1.10.', 'summary_with_ip_fails'),
    ('summary', 'Uses machine.ts.net.', 'summary_with_hostname_fails'),
    ('summary', 'Uses https://example.com.', 'summary_with_url_fails'),
    ('name', 'Aiur.Orchestrator', 'name_with_module_fails')]:
    public_case(name, lambda m, k=field, v=value: m['components'][0].update({k: v}),
                messages=('forbidden public copy',))
for value, name, message in [
    ('x' * 141 + '.', 'summary_too_long_fails', 'string too long'),
    ('Provides behavior. ', 'summary_trailing_space_fails', 'invalid string'),
    ('Two sentences. Another sentence.', 'summary_multiple_sentences_fails', 'invalid string'),
    ('Missing punctuation', 'summary_without_sentence_fails', 'invalid string'),
    ('Two\nlines.', 'summary_newline_fails', 'invalid string')]:
    public_case(name, lambda m, v=value: m['components'][0].update(summary=v), messages=(message,))
public_case('summary_final_newline_fails', lambda m: m['components'][0].update(summary='Provides behavior.\n'),
            messages=('invalid string',))
public_case('name_final_newline_fails', lambda m: m['components'][0].update(name='Name\n'), messages=('invalid string',))
public_case('summary_uppercase_secret_fails', lambda m: m['components'][0].update(summary='Stores a PASSWORD.'),
            messages=('forbidden public copy',))
public_case('env_value_fails', lambda m: m['components'][0].update(env=['GITHUB_TOKEN=abc']),
            messages=('/env/0: invalid string',))
public_case('env_final_newline_fails', lambda m: m['components'][0].update(env=['GITHUB_TOKEN\n']),
            messages=('/env/0: invalid string',))
public_case('env_names_and_wildcard_pass', lambda m: m['components'][0].update(env=['GITHUB_TOKEN', 'GITHUB_APP_*']), code=0)
public_case('feature_bucket1_id_fails', lambda m: m['features'][0].update(id='MP-R3'), messages=('/id: invalid string',))
public_case('feature_duplicate_id_fails', lambda m: m['features'].append(dict(m['features'][0])),
            messages=('duplicate feature id',))
public_case('feature_unknown_component_fails', lambda m: m['features'][0].update(extends=['absent']),
            messages=('MP-N2: unknown component absent',))
public_case('feature_empty_union_fails', lambda m: (m['components'][1].update(added_by='MP-R1'),
                                                m['features'][0].update(extends=[], adds=[])),
            messages=('extends/adds must name a component',))
public_case('feature_private_copy_still_validated', lambda m: m['features'][0].update(summary='Calls Aiur.Private.'),
            messages=('MP-N2:', 'forbidden public copy'))
public_case('feature_public_flag_boolean_fails', lambda m: m['features'][0].update(public='true'),
            messages=('/public:',))
public_case('feature_unknown_key_fails', lambda m: m['features'][0].update(extra=True), messages=('/extra:',))
public_case('feature_release_tag_passes', lambda m: m['features'][0].update(shipped_in='v0.0.9'), code=0)
public_case('feature_empty_release_fails', lambda m: m['features'][0].update(shipped_in=''), messages=('empty string',))
public_case('features_required_fails', lambda m: m.pop('features'), messages=('/features: required property',))
for value in ['core', 'optional', 'experimental', 'deprecated']:
    public_case('status_' + value + '_passes', lambda m, v=value: m['components'][0].update(status=v), code=0)
public_case('invalid_status_fails', lambda m: m['components'][0].update(status='available'), messages=('/status:',))
public_case('invalid_dependency_kind_fails', lambda m: m['components'][0].update(dependency_kind='in-app'),
            messages=('/dependency_kind:',))
for name, install in [('included', {'type':'included'}), ('npm', {'type':'npm', 'package':'@aiur/example'}),
                      ('setup', {'type':'setup', 'docs':'guide/quick-start.md'})]:
    public_case('install_' + name + '_passes', lambda m, v=install: m['components'][0].update(install=v), code=0)
for name, install in [('missing_package', {'type':'npm'}), ('extra', {'type':'included', 'password':'abc'}),
                      ('unknown', {'type':'pip'}), ('setup_path', {'type':'setup','docs':'../secrets.md'})]:
    public_case('install_' + name + '_fails', lambda m, v=install: m['components'][0].update(install=v),
                messages=('/install:',))
for name, path in [('absolute', '/guide/tui.md'), ('traversal', '../secrets.md'), ('suffix', 'guide/tui.html')]:
    public_case('docs_' + name + '_fails', lambda m, v=path: m['components'][0].update(docs=[v]), messages=('/docs/0:',))
public_case('capability_value_fails', lambda m: m['components'][0].update(capabilities=['key=abc']), messages=('/capabilities/0:',))
public_case('config_path_fails', lambda m: m['components'][0].update(config=['../config']), messages=('/config/0:',))
public_case('install_secret_name_fails', lambda m: m['components'][0].update(install={'type':'npm','package':'password'}),
            messages=('forbidden public metadata',))
public_case('docs_secret_name_fails', lambda m: m['components'][0].update(docs=['guide/token.md']),
            messages=('forbidden public metadata',))
public_case('release_url_fails', lambda m: m['features'][0].update(shipped_in='https://example.com'),
            messages=('forbidden public metadata',))

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
    result = subprocess.run([sys.executable, str(checker)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert '21 sections, 7 fields, 70 env vars, 13 state paths owned once' in result.stdout
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
assert not selected - ran, f'unknown/unexecuted cases: {selected - ran}'
print('check-components guard: all selected cases passed')
PY
