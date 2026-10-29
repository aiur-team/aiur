"""Exercise explicit field overrides through the real manifest schema and checker."""


def run(component, check):
    declarations = {
        'src/lib/aiur/config/schema.ex': '''defmodule Aiur.Config.Schema do
    embeds_one(:events, Events)
end
''',
        'src/lib/aiur/config/schema/events.ex': '''defmodule Aiur.Config.Schema.Events do
    field(:codeowners_refresh_seconds, :integer)
    field(:custom_events_per_turn_max, :integer)
end
''',
        'src/lib/aiur/env/schema.ex': '    {"AIUR_FIXTURE", type: :string}\n',
        'src/lib/aiur/config/paths.ex': '  def fixture_dir, do: "/fixture"\n',
    }
    owner = component('bus', list(declarations))
    owner['owns'].update(config=['events'], env=['AIUR_FIXTURE'], state=['fixture_dir'])
    github = component('github', [])
    github['owns']['config'] = ['events.codeowners_refresh_seconds']

    check('nested_config_override_passes', [owner, github], [], declarations=declarations,
          messages=('1 sections, 0 fields, 1 env vars, 1 state paths owned once',))
    check('nested_config_unknown_field_fails', [owner, github], [], 1,
          ("'events.missing' is stale (github)",), declarations=declarations,
          change=lambda m: m['components'][1]['owns'].update(config=['events.missing']))
    check('nested_config_unknown_section_fails', [owner, github], [], 1,
          ("'missing.codeowners_refresh_seconds' is stale (github)",), declarations=declarations,
          change=lambda m: m['components'][1]['owns'].update(config=['missing.codeowners_refresh_seconds']))
    second = component('other', [])
    second['owns']['config'] = ['events.codeowners_refresh_seconds']
    check('nested_config_duplicate_override_fails', [owner, github, second], [], 1,
          ("'events.codeowners_refresh_seconds' owned twice: github, other",), declarations=declarations)
    # Future regression guard: malformed paths were rejected before nested overrides.
    check('nested_config_malformed_path_fails', [owner, github], [], 2,
          ('/components/1/owns/config/0',), declarations=declarations,
          change=lambda m: m['components'][1]['owns'].update(config=['events..codeowners_refresh_seconds']))
    check('nested_config_override_requires_root_owner', [owner, github], [], 1,
          ("'events' has no owner",), declarations=declarations,
          change=lambda m: m['components'][0]['owns'].update(config=[]))
