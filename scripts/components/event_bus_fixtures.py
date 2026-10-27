"""Replace the temporary ExUnit event-bus ratchet with checker parity fixtures."""
import json

from components.manifest import read_manifest


def run(check, repo):
    bus = next(c for c in read_manifest(repo)['components'] if c['id'] == 'event-bus')

    def contract(root):
        path = root / 'components.json'
        manifest = json.loads(path.read_text())
        caller, provider = manifest['components']
        caller.update(id=bus['id'], layer=bus['layer'], requires=bus['requires'], optional=bus['optional'])
        # Isolate the structural rules; the seam fixtures exercise the strict shipped allowlist.
        caller['boundary_reference_allowlist'] = bus['boundary_reference_allowlist'] + [
            'Aiur.Orchestrator', 'Aiur.Orchestrator.State', 'Aiur.Config.State']
        provider.update(id='kernel', facades=['Aiur.JSONSafe'])
        (root / 'src/lib/b.ex').write_text('defmodule Aiur.JSONSafe do\nend\n')
        for name, layer, facade in [('config', 0, 'Aiur.Config'), ('orchestration', 3, 'Aiur.Orchestrator')]:
            component = json.loads(json.dumps(provider))
            component.update(id=name, layer=layer, paths=[f'src/lib/{name}.ex'], facades=[facade])
            manifest['components'].append(component)
            (root / f'src/lib/{name}.ex').write_text(
                f'defmodule {facade} do\nend\ndefmodule {facade}.State do\nend\n')
        path.write_text(json.dumps(manifest))

    fixture = 'private_module_fails'

    def source(target):
        return f'# aiur:event-bus-boundary-member\ndefmodule Aiur.Events.Exchange do\n  def run, do: {target}.run()\nend\n'

    # Future-regression guards: these rules already enforce the shipped boundary.
    check('event_bus_private_module_fails', fixture, 1,
          ('R-private event-bus -> Aiur.Orchestrator.State',),
          source=source('Aiur.Orchestrator.State'), change=contract)
    check('event_bus_upward_reference_fails', fixture, 1,
          ('R-down event-bus -> Aiur.Orchestrator', 'R-declared event-bus -> Aiur.Orchestrator'),
          source=source('Aiur.Orchestrator'), change=contract)
    check('event_bus_kernel_config_pass', fixture, messages=('R-declared: 0', 'R-private: 0', 'R-down: 0'),
          source=source('Aiur.Config') + source('Aiur.JSONSafe'), change=contract)

    def allowed(root):
        contract(root)
        directory = root / 'scripts/components/allowlist'
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'event-bus.tsv').write_text(
            'R-private\tAiur.Config.State\t#3367 fixture exception\n')

    check('event_bus_live_ratchet_passes', fixture, messages=('R-private: 1',),
          source=source('Aiur.Config.State'), change=allowed)
    check('event_bus_stale_ratchet_fails', fixture, 1,
          ('stale allowlist entry: R-private event-bus -> Aiur.Config.State',),
          source=source('Aiur.Config'), change=allowed)

    def membership(root):
        marked = {p.relative_to(repo).as_posix() for p in (repo / 'src/lib/aiur').rglob('*.ex')
                  if '# aiur:event-bus-boundary-member' in p.read_text()}
        assert 'src/lib/aiur/events/journal.ex' in marked, 'journal must remain a bus member'
        event_paths = {p for p in bus['paths'] if p.startswith('src/lib/aiur/events/')}
        assert event_paths == {p for p in marked if p.startswith('src/lib/aiur/events/')} | {
            'src/lib/aiur/events/trust_classifier.ex',
            # MP-R2-C6-T04: PubSub consumer adapter, outside the bus-core boundary.
            'src/lib/aiur/events/durable_consumer/export_source.ex'}, 'manifest must own every marked event module and trust port'
        assert marked <= set(bus['paths']), 'manifest must own marked members outside events too'
        contract(root)
        directory = root / 'src/lib/aiur/events'
        directory.mkdir(parents=True)
        (directory / 'new_boundary_member.ex').write_text(
            '# aiur:event-bus-boundary-member\ndefmodule Aiur.Events.NewBoundaryMember do\nend\n')

    check('event_bus_new_member_requires_ownership', fixture, 1,
          ('src/lib/aiur/events/new_boundary_member.ex: unowned file',),
          source=source('Aiur.Config'), change=membership)
