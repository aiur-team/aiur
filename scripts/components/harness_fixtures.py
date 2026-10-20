"""Exercise the shipped harness namespace contract through the real walker."""
import json


def run(check, repo):
    def contract(root):
        path = root / 'components.json'
        manifest = json.loads(path.read_text())
        harness = json.loads((repo / 'components/harness-adapters.json').read_text())
        caller, provider = manifest['components']
        caller.update(id='orchestration', requires=['harness-adapters'])
        provider.update(id='harness-adapters', facades=harness['facades'],
                        facade_pending=None, private_namespaces=harness['private_namespaces'])
        path.write_text(json.dumps(manifest))
        (root / 'src/lib/b.ex').write_text('''defmodule Aiur.Codex.Frames do
end
defmodule Aiur.Claude.Frames do
end
defmodule Aiur.Muse.Frames do
end
defmodule Aiur.OpenAICompat.Frames do
end
defmodule Aiur.CodingAgent do
end
defmodule Aiur.ModelAvailability do
end
''')

    fixture = 'private_module_fails'
    private = 'defmodule Aiur.Orchestrator.Foo do\n  alias Aiur.Codex.Frames\nend\n'
    check('harness_private_namespace_violation', fixture, 1,
          ('R-private orchestration -> Aiur.Codex.Frames',), source=private, change=contract)
    for namespace in ('Claude', 'Muse', 'OpenAICompat'):
        check('harness_private_' + namespace, fixture, 1,
              ('R-private orchestration -> Aiur.' + namespace + '.Frames',),
              source=private.replace('Codex', namespace), change=contract)
    # Future-regression guards: docs, declared facades and stale-row handling already work.
    check('harness_comment_mention_ok', fixture, messages=('R-private: 0',), change=contract,
          source='''defmodule Aiur.Orchestrator.Foo do
  @moduledoc "Aiur.Codex.Frames"
  @doc "Aiur.Claude.Frames"
  @typedoc "Aiur.OpenAICompat.Frames"
  @type example :: atom()
  # alias Aiur.Muse.Frames
end
''')
    check('harness_neutral_contracts_ok', fixture, messages=('R-private: 0',), change=contract,
          source='defmodule A do\n  Aiur.CodingAgent.run()\n  Aiur.ModelAvailability.run()\nend\n')

    def allowed(root):
        contract(root)
        path = root / 'scripts/components/allowlist/orchestration.tsv'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('R-private\tAiur.Codex.Frames\t#3474 fixture exception\n')

    check('harness_allowlisted_alias_ok', fixture, messages=('R-private: 1',), source=private, change=allowed)
    check('harness_stale_exception_fails', fixture, 1,
          ('stale allowlist entry: R-private orchestration -> Aiur.Codex.Frames',),
          source='defmodule A do\nend\n', change=allowed)
    check('harness_literal_violation', fixture, 1, ('R-private orchestration -> Aiur.Codex.Frames',),
          source='defmodule A do\n  @provider :"Elixir.Aiur.Codex.Frames"\nend\n', change=contract)

    def facade_exception(root):
        contract(root)
        path = root / 'components.json'
        manifest = json.loads(path.read_text())
        manifest['components'][1]['facades'].append('Aiur.Codex.Frames')
        path.write_text(json.dumps(manifest))

    check('harness_explicit_facade_ok', fixture, messages=('R-private: 0',), source=private, change=facade_exception)
