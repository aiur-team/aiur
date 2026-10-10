#!/usr/bin/env python3
"""Check the shipped pr-lifecycle boundary against real Elixir references."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((REPO / 'components.json').read_text())
MANIFEST['seams'] = [json.loads(path.read_text()) for path in sorted((REPO / 'scripts/components/seams').glob('*.json'))]


def check(name, source_component, source, expected, message):
    manifest = copy.deepcopy(MANIFEST)
    paths = {'pr-lifecycle': 'src/lib/aiur/pr_lifecycle/health_scanner.ex',
             'orchestration': 'src/lib/aiur/orchestrator/state.ex'}
    for component in manifest['components']:
        component['paths'] = [paths[component['id']]] if component['id'] in paths else []
    with tempfile.TemporaryDirectory(prefix='pr-lifecycle-', dir=os.environ.get('TMPDIR')) as directory:
        root = Path(directory)
        (root / 'components.json').write_text(json.dumps(manifest))
        (root / 'components.schema.json').write_text((REPO / 'components.schema.json').read_text())
        for component, path in paths.items():
            module = 'Aiur.PRLifecycle.HealthScanner' if component == 'pr-lifecycle' else 'Aiur.Orchestrator.State'
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f'defmodule {module} do\n{source if component == source_component else ""}\nend\n')
        result = subprocess.run(
            ['python3', str(REPO / 'scripts/check-components.py'), '--rules', 'elixir', '--require-elixir'],
            env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)), capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode == expected, output
        assert message in output, output
        print(f'PASS: {name}')


check('independent_scanner_passes', 'pr-lifecycle', 'nil', 0, 'R-declared: 0')
check('scanner_cannot_reference_orchestration', 'pr-lifecycle', 'alias Aiur.Orchestrator.State',
      1, 'R-forbid pr-lifecycle -> Aiur.Orchestrator.State:')
check('orchestration_cannot_reference_scanner', 'orchestration', 'Aiur.PRLifecycle.HealthScanner.start_link([])',
      1, 'R-declared orchestration -> Aiur.PRLifecycle.HealthScanner:')
