#!/usr/bin/env python3
"""End-to-end fixtures for non-allowlistable namespace and seam restrictions."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
CHECKER = REPO / 'scripts/check-components.py'
SCHEMA = (REPO / 'components.schema.json').read_text()
MANIFEST = json.loads((REPO / 'components.json').read_text())
SELECTED = set(sys.argv[1:])
RAN = set()


def check(name, source, expected=0, message='', source_component='orchestration',
          path='src/lib/aiur/orchestrator/build_queue_claim_probe.ex', change=None):
    if SELECTED and name not in SELECTED:
        return
    RAN.add(name)
    manifest = copy.deepcopy(MANIFEST)
    components = {c['id']: c for c in manifest['components']}
    for component in components.values():
        component['paths'] = []
    components[source_component]['paths'] = [path]
    components['build-queue']['paths'].append('src/lib/providers/queue.ex')
    components['build-orders']['paths'].append('src/lib/providers/order.ex')
    if change:
        change(manifest)
    with tempfile.TemporaryDirectory(prefix='components-seams-') as directory:
        root = Path(directory)
        (root / 'components.schema.json').write_text(SCHEMA)
        (root / 'components.json').write_text(json.dumps(manifest))
        files = {path: 'defmodule Aiur.Fixture do\n' + source + '\nend\n',
                 'src/lib/providers/queue.ex': '\n'.join('defmodule ' + name + ' do\nend' for name in
                     ['Aiur.BuildQueue.Hints', 'Aiur.BuildQueue.ClaimProbe', 'Aiur.BuildQueue.Server']),
                 'src/lib/providers/order.ex': 'defmodule Aiur.BuildOrder.Graph do\nend\n'}
        for file, content in files.items():
            target = root / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        result = subprocess.run([sys.executable, str(CHECKER), '--rules', 'elixir', '--require-elixir'],
                                env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)), capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode == expected, f'{name}: expected {expected}, got {result.returncode}\n{output}'
        assert message in output, f'{name}: missing {message!r}\n{output}'
        print(f'PASS: {name}')


check('hints_seam_passes', 'Aiur.BuildQueue.Hints.rank("1")', message='R-optional: 0')
check('claim_probe_behaviour_seam', '@behaviour Aiur.BuildQueue.ClaimProbe', message='R-optional: 0',
      path='src/lib/aiur/orchestrator/other.ex')
check('claim_probe_types_pass_in_implementation', '@spec f() :: Aiur.BuildQueue.ClaimProbe.result()')
check('claim_probe_reference_elsewhere_fails', 'Aiur.BuildQueue.ClaimProbe.f()', 1, 'R-seam',
      path='src/lib/aiur/orchestrator/other.ex')
check('other_build_queue_module_from_orchestration_fails', 'Aiur.BuildQueue.Server.f()', 1, 'R-private')
check('seam_kind_is_exact', '@behaviour Aiur.BuildQueue.Hints', 1, 'R-optional')
for name, source, target in [
    ('forbidden_orchestrator_ref_fails', 'Aiur.Orchestrator.f()', 'Aiur.Orchestrator'),
    ('forbidden_github_ref_fails', 'Aiur.GitHub.Labels.f()', 'Aiur.GitHub.Labels'),
    ('forbidden_grouped_alias_fails', 'alias Aiur.{Config, Orchestrator.State}', 'Aiur.Orchestrator.State'),
    ('forbidden_literal_module_fails', 'Module.concat(["Elixir.Aiur.GitHub", "Client"])', 'Aiur.GitHub'),
    ('forbidden_module_atom_fails', ':"Elixir.Aiur.Orchestrator"', 'Aiur.Orchestrator'),
]:
    check(name, source, 1, f'R-forbid build-queue -> {target}', source_component='build-queue',
          path='src/lib/aiur/build_queue/server.ex')
# Future-regression guard: the existing walker already excludes comments and docs.
check('future_guard_comments_and_docs_ignored', '# alias Aiur.Orchestrator\n@moduledoc "Aiur.GitHub"',
      source_component='build-queue', path='src/lib/aiur/build_queue/server.ex')
check('similar_namespace_allowed', 'alias Aiur.OrchestratorExtra', source_component='build-queue',
      path='src/lib/aiur/build_queue/server.ex')
check('listener_reverse_direction_fails', 'Aiur.Orchestrator.State.f()', 1,
      'R-forbid listener-modes -> Aiur.Orchestrator.State', source_component='listener-modes',
      path='src/lib/aiur/listener/modes.ex')
# The allowed-path case is the positive half of the restriction's mutation guard.
for path, expected in [('src/lib/aiur/build_queue/server.ex', 1),
                       ('src/lib/aiur/build_queue/sources/build_order.ex', 0)]:
    check('build_order_only_in_source_module_' + str(expected), 'Aiur.BuildOrder.Graph.f()', expected,
          'R-seam' if expected else '', source_component='build-queue', path=path)
check('build_order_unused_alias_also_restricted', 'alias Aiur.BuildOrder.Graph', 1, 'R-seam',
      source_component='build-queue', path='src/lib/aiur/build_queue/server.ex')
# Future-regression guards preserve existing private/layer rules when applying seams.
check('seam_does_not_suppress_private', 'Aiur.BuildQueue.Server.f()', 1, 'R-private',
      change=lambda m: m['seams'].append(dict(m['seams'][0], to_module='Aiur.BuildQueue.Server')))
check('seam_does_not_suppress_upward', 'Aiur.BuildQueue.Hints.f()', 1, 'R-down',
      change=lambda m: next(c for c in m['components'] if c['id'] == 'orchestration').update(layer=2))
check('unknown_seam_component_rejected', 'nil', 2, 'unknown component absent',
      change=lambda m: m['seams'][0].update({'from': 'absent'}))
check('unsafe_seam_path_rejected', 'nil', 2, 'expected repository-relative glob',
      change=lambda m: m['seams'][2].update(only_paths=['../escape.ex']))
check('unknown_port_component_rejected', 'nil', 2, 'unknown component absent',
      change=lambda m: m['ports'][0].update({'from': 'absent'}))
assert not SELECTED - RAN, f'unknown/unexecuted cases: {SELECTED - RAN}'
print('component seam guard: all cases passed')
