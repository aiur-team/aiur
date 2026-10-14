#!/usr/bin/env python3
"""Exercise the frozen GitHub facade boundary using the real manifest."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from components.manifest import read_manifest

REPO = Path(__file__).resolve().parent.parent
MANIFEST = read_manifest(REPO)


def check(target, expected):
    manifest = copy.deepcopy(MANIFEST)
    for component in manifest['components']:
        component['paths'] = []
        component['status'] = 'core'
        if component['id'] == 'orchestration':
            component['paths'] = ['src/lib/aiur/orchestrator/probe.ex']
            component['optional'] = sorted(set(component['optional'] + ['github']))
            component['dependency_kind'] = 'optional'
        if component['id'] == 'github':
            component['paths'] = ['src/lib/aiur/github/probe.ex']
    manifest['features'] = []
    with tempfile.TemporaryDirectory(prefix='github-component-') as directory:
        root = Path(directory)
        (root / 'components.json').write_text(json.dumps(manifest))
        (root / 'components.schema.json').write_text((REPO / 'components.schema.json').read_text())
        files = {
            'src/lib/aiur/orchestrator/probe.ex': f'defmodule Aiur.Orchestrator.Probe do\n  def read, do: {target}.read()\nend\n',
            'src/lib/aiur/github/probe.ex': f'defmodule {target} do\n  def read, do: :ok\nend\n',
        }
        for path, body in files.items():
            file = root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(body)
        result = subprocess.run([sys.executable, str(REPO / 'scripts/check-components.py'), '--rules', 'elixir', '--require-elixir'],
                                env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)), capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode == expected, output
        if expected:
            assert f'R-private orchestration -> {target}:' in output, output
        print(f'PASS: GitHub facade {target} -> {expected}')


# Future regression guard: existing Client access must remain allowed.
check('Aiur.GitHub.Client', 0)
# Future regression guard: main's status command already consumes this facade.
check('Aiur.GitHub.ResourceStore.Memory', 0)
# RequestLog is internal at this census; PollSnapshots is already an external API.
check('Aiur.GitHub.RequestLog', 1)
