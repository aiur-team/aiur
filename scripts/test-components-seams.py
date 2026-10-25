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
from components.manifest import read_manifest
MANIFEST = read_manifest(REPO)
MANIFEST['seams'] = [json.loads(path.read_text()) for path in sorted((REPO / 'scripts/components/seams').glob('*.json'))]
SELECTED = set(sys.argv[1:])
RAN = set()



def lifecycle_writer_seam(manifest):
    """Find the build-queue lifecycle-writer seam by identity, not list position."""
    matches = [s for s in manifest['seams'] if s['from'] == 'build-queue'
               and s['to_module'] == 'Aiur.Orchestrator.TicketTransition' and s.get('allow_forbidden')]
    assert len(matches) == 1, f'expected one build-queue lifecycle-writer seam, found {len(matches)}'
    return matches[0]


def check(name, source, expected=0, message='', source_component='orchestration',
          path='src/lib/aiur/orchestrator/build_queue_claim_probe.ex', change=None, preamble=''):
    if SELECTED and name not in SELECTED:
        return
    RAN.add(name)
    manifest = copy.deepcopy(MANIFEST)
    components = {c['id']: c for c in manifest['components']}
    for component in components.values():
        component['paths'] = []
        component['status'] = 'core'
    manifest['features'] = []
    components[source_component]['paths'] = [path]
    components['build-queue']['paths'].append('src/lib/providers/queue.ex')
    components['build-orders']['paths'].append('src/lib/providers/order.ex')
    if change:
        change(manifest)
    with tempfile.TemporaryDirectory(prefix='components-seams-') as directory:
        root = Path(directory)
        (root / 'components.schema.json').write_text(SCHEMA)
        (root / 'components.json').write_text(json.dumps(manifest))
        files = {path: preamble + 'defmodule Aiur.Fixture do\n' + source + '\nend\n',
                 'src/lib/providers/queue.ex': '\n'.join('defmodule ' + name + ' do\nend' for name in
                     ['Aiur.BuildQueue.Hints', 'Aiur.BuildQueue.ClaimProbe', 'Aiur.BuildQueue.Server']),
                 'src/lib/providers/order.ex': 'defmodule Aiur.BuildOrder.GraphProjection do\nend\n'}
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


check('sanctioned_lifecycle_writer_passes', 'Aiur.Orchestrator.TicketTransition.write_state()',
      source_component='build-queue', path='src/lib/aiur/build_queue/write_protocol.ex')
check('sanctioned_lifecycle_alias_passes', 'alias Aiur.Orchestrator.TicketTransition',
      source_component='build-queue', path='src/lib/aiur/build_queue/write_protocol.ex')
check('lifecycle_exception_other_path_fails', 'Aiur.Orchestrator.TicketTransition.write_state()', 1,
      'R-forbid build-queue -> Aiur.Orchestrator.TicketTransition:',
      source_component='build-queue', path='src/lib/aiur/build_queue/server.ex')
check('lifecycle_exception_child_module_fails', 'Aiur.Orchestrator.TicketTransition.Other.f()', 1,
      'R-forbid build-queue -> Aiur.Orchestrator.TicketTransition.Other:',
      source_component='build-queue', path='src/lib/aiur/build_queue/write_protocol.ex')
check('ordinary_seam_cannot_override_forbid', 'Aiur.Orchestrator.TicketTransition.write_state()', 1,
      'R-forbid build-queue -> Aiur.Orchestrator.TicketTransition:', source_component='build-queue',
      path='src/lib/aiur/build_queue/write_protocol.ex',
      change=lambda m: lifecycle_writer_seam(m).pop('allow_forbidden'))
check('hints_seam_passes', 'Aiur.BuildQueue.Hints.rank("1")', message='R-optional: 0')
check('claim_probe_behaviour_seam', '@behaviour Aiur.BuildQueue.ClaimProbe', message='R-optional: 0',
      path='src/lib/aiur/orchestrator/other.ex')
check('claim_probe_types_pass_in_implementation', '@spec f() :: Aiur.BuildQueue.ClaimProbe.result()')
check('claim_probe_reference_elsewhere_fails', 'Aiur.BuildQueue.ClaimProbe.f()', 1, 'R-seam',
      path='src/lib/aiur/orchestrator/other.ex')
check('other_build_queue_module_from_orchestration_fails', 'Aiur.BuildQueue.Server.f()', 1,
      'R-private orchestration -> Aiur.BuildQueue.Server:')
check('seam_kind_is_exact', '@behaviour Aiur.BuildQueue.Hints', 1,
      'R-optional orchestration -> Aiur.BuildQueue.Hints:')
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


# Event-bus boundary references include declarations and literals, even when unused.
def event_bus_boundary_check(name, source, targets, expected, message, *, source_path='src/lib/aiur/events/exchange.ex',
                             source_module='Aiur.Events.Exchange', boundary_member=True):
    manifest = copy.deepcopy(MANIFEST)
    components = {c['id']: c for c in manifest['components']}
    for component in components.values():
        component['paths'] = []
        component['status'] = 'core'
    manifest['features'] = []
    components['event-bus']['facades'] = ['Aiur.Events.Exchange', 'Aiur.Events.Topic']
    components['event-bus']['requires'] = ['orchestration', 'config', 'kernel']
    components['event-bus']['paths'] = [source_path, 'src/lib/aiur/events/topic.ex']
    components['orchestration']['paths'] = ['src/lib/aiur/orchestrator/state.ex']
    components['orchestration']['facades'] = ['Aiur.Orchestrator.State']
    components['config']['paths'] = ['src/lib/aiur/config.ex', 'src/lib/aiur/workflow.ex']
    components['config']['facades'] = ['Aiur.Config']
    components['config']['layer'] = 0
    components['kernel']['paths'] = ['src/lib/aiur/json_store.ex', 'src/lib/aiur/json_safe.ex',
                                     'src/lib/aiur/shell.ex']
    components['kernel']['facades'] = ['Aiur.JsonStore', 'Aiur.JSONSafe', 'Aiur.Shell']
    components['kernel']['layer'] = 0
    # Edge-rule fixtures opt into the tested target so they reach R-private/R-down;
    # the dedicated allowlist fixtures below exercise the default contract.
    if expected == 1 and message.startswith(('R-down', 'R-private')):
        components['event-bus']['boundary_reference_allowlist'].extend(targets)
    with tempfile.TemporaryDirectory(prefix='event-bus-alias-') as directory:
        root = Path(directory)
        (root / 'components.schema.json').write_text(SCHEMA)
        (root / 'components.json').write_text(json.dumps(manifest))
        marker = '# aiur:event-bus-boundary-member\n' if boundary_member else ''
        files = {
            source_path: marker + f'defmodule {source_module} do\n' + source + '\nend\n',
            'src/lib/aiur/orchestrator/state.ex': '\n'.join(
                f'defmodule {target} do\nend' for target in targets if target.startswith('Aiur.Orchestrator.')),
            'src/lib/aiur/config.ex': 'defmodule Aiur.Config do\nend\n',
            'src/lib/aiur/json_store.ex': 'defmodule Aiur.JsonStore do\nend\n',
            'src/lib/aiur/json_safe.ex': 'defmodule Aiur.JSONSafe do\nend\n',
            'src/lib/aiur/shell.ex': 'defmodule Aiur.Shell do\nend\n',
            'src/lib/aiur/workflow.ex': 'defmodule Aiur.Workflow do\nend\n',
            'src/lib/aiur/events/topic.ex': 'defmodule Aiur.Events.Topic do\nend\ndefmodule Aiur.PubSub do\nend\n',
        }
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


for name, source, target, rule in [
    ('event_bus_alias_public_upward_fails', 'alias Aiur.Orchestrator.State', 'Aiur.Orchestrator.State', 'R-down'),
    ('event_bus_alias_private_upward_fails', 'alias Aiur.Orchestrator.Internal', 'Aiur.Orchestrator.Internal', 'R-private'),
    ('event_bus_grouped_alias_public_upward_fails', 'alias Aiur.Orchestrator.{State, Internal}', 'Aiur.Orchestrator.State', 'R-down'),
    ('event_bus_grouped_alias_private_upward_fails', 'alias Aiur.Orchestrator.{State, Internal}', 'Aiur.Orchestrator.Internal', 'R-private'),
]:
    if not SELECTED or name in SELECTED:
        RAN.add(name)
        event_bus_boundary_check(name, source, [target], 1, f'{rule} event-bus -> {target}')
if not SELECTED or 'event_bus_kernel_alias_passes' in SELECTED:
    RAN.add('event_bus_kernel_alias_passes')
    event_bus_boundary_check('event_bus_kernel_alias_passes',
                          'alias Aiur.Config\nalias Aiur.JsonStore\nalias Aiur.JSONSafe\nalias Aiur.Events.Topic',
                          ['Aiur.Config', 'Aiur.JsonStore', 'Aiur.JSONSafe', 'Aiur.Events.Topic'], 0, 'R-down: 0')
for name, source, target in [
    ('event_bus_pubsub_alias_forbidden', 'alias Phoenix.PubSub', 'Phoenix.PubSub'),
    ('event_bus_kernel_alias_forbidden', 'alias Aiur.Shell', 'Aiur.Shell'),
    ('event_bus_config_alias_forbidden', 'alias Aiur.Workflow', 'Aiur.Workflow'),
    ('event_bus_boundary_literal_forbidden', '"Aiur.Orchestrator"', 'Aiur.Orchestrator'),
    ('event_bus_boundary_qualified_call_forbidden', 'Aiur.Shell.run()', 'Aiur.Shell'),
]:
    if not SELECTED or name in SELECTED:
        RAN.add(name)
        event_bus_boundary_check(name, source, [target], 1, f'R-forbid event-bus -> {target}')
if not SELECTED or 'event_bus_nonmember_pubsub_call_passes' in SELECTED:
    RAN.add('event_bus_nonmember_pubsub_call_passes')
    event_bus_boundary_check('event_bus_nonmember_pubsub_call_passes',
                             'Phoenix.PubSub.subscribe(Aiur.PubSub, topic)', [], 0, 'R-down: 0',
                             source_path='src/lib/aiur/agent_pubsub.ex', source_module='Aiur.AgentPubSub',
                             boundary_member=False)
check('file_level_alias_is_forbidden', 'nil', 1, 'R-forbid build-queue -> Aiur.Orchestrator:',
      source_component='build-queue', path='src/lib/aiur/build_queue/server.ex',
      preamble='alias Aiur.Orchestrator\n')
check('listener_reverse_direction_fails', 'Aiur.Orchestrator.State.f()', 1,
      'R-forbid listener-modes -> Aiur.Orchestrator.State', source_component='listener-modes',
      path='src/lib/aiur/listener/modes.ex')
# The allowed-path case is the positive half of the restriction's mutation guard.
for path, expected in [('src/lib/aiur/build_queue/server.ex', 1),
                       ('src/lib/aiur/build_queue/sources/build_order.ex', 0)]:
    check('build_order_only_in_source_module_' + str(expected), 'Aiur.BuildOrder.GraphProjection.f()', expected,
          'R-seam' if expected else '', source_component='build-queue', path=path)
check('build_order_unused_alias_also_restricted', 'alias Aiur.BuildOrder.GraphProjection', 1, 'R-seam',
      source_component='build-queue', path='src/lib/aiur/build_queue/server.ex')
# Future-regression guards preserve existing private/layer rules when applying seams.
check('seam_does_not_suppress_private', 'Aiur.BuildQueue.Server.f()', 1,
      'R-private orchestration -> Aiur.BuildQueue.Server:',
      change=lambda m: m['seams'].append(dict(m['seams'][0], to_module='Aiur.BuildQueue.Server')))
check('seam_does_not_suppress_upward', 'Aiur.BuildQueue.Hints.f()', 1,
      'R-down orchestration -> Aiur.BuildQueue.Hints:',
      change=lambda m: next(c for c in m['components'] if c['id'] == 'orchestration').update(layer=2))
check('unknown_seam_component_rejected', 'nil', 2, 'unknown component absent',
      change=lambda m: m['seams'][0].update({'from': 'absent'}))
check('unsafe_seam_path_rejected', 'nil', 2, 'expected repository-relative glob',
      change=lambda m: m['seams'][2].update(only_paths=['../escape.ex']))
check('unknown_port_component_rejected', 'nil', 2, 'unknown component absent',
      change=lambda m: m['ports'][0].update({'from': 'absent'}))
# Regression guard: the seam lookup must not depend on where the seam sits in the list.
def _reorder_guard():
    manifest = copy.deepcopy(MANIFEST)
    expected = lifecycle_writer_seam(manifest)
    manifest['seams'].reverse()
    assert lifecycle_writer_seam(manifest) == expected
    manifest['seams'].append({'from': 'orchestration', 'to_module': 'Aiur.Fixture.Tail', 'kind': 'reference', 'reason': 'x'})
    assert lifecycle_writer_seam(manifest) == expected


if not SELECTED or 'seam_lookup_is_order_independent' in SELECTED:
    RAN.add('seam_lookup_is_order_independent')
    _reorder_guard()
    print('PASS: seam_lookup_is_order_independent')
assert not SELECTED - RAN, f'unknown/unexecuted cases: {SELECTED - RAN}'
print('component seam guard: all cases passed')
