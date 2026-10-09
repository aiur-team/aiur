"""Public-contract fixtures shared with the ownership test runner."""


def public_fields(entry):
    return dict(entry, kind="in-app", dependency_kind=entry["kind"],
                summary="Provides fixture behavior.", status="core", install={"type": "included"},
                docs=[], config=[], env=[], capabilities=[])


def run(component, check):
    import json
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
