#!/usr/bin/env python3
"""Exercise file-pattern state ownership through the public checker."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / 'scripts'))
from components.public_fixtures import fixture_component


def run(name, state, paths, code, expected):
    component = fixture_component('a', paths + ['src/lib/aiur/config/schema.ex',
        'src/lib/aiur/env/schema.ex', 'src/lib/aiur/config/paths.ex'])
    component['owns']['state'] = state
    component['owns'].update(config=['fixture'], env=['AIUR_FIXTURE'])
    if not any(value.endswith(('_dir', '_path')) for value in state):
        component['owns']['state'].append('fixture_dir')
    manifest = {'manifest_version': 1, 'directory_published': False,
                'components': [component], 'features': []}
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
        (root / 'components.json').write_text(json.dumps(manifest))
        for path, content in {
            'src/lib/aiur/config/schema.ex': 'embeds_one(:fixture, Fixture)\n',
            'src/lib/aiur/env/schema.ex': '{"AIUR_FIXTURE", type: :string}\n',
            'src/lib/aiur/config/paths.ex': 'def fixture_dir, do: "/tmp"\n',
        }.items():
            file = root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        for path in paths:
            if path.endswith('.json') or '*' in path:
                file = root / path.replace('*', 'sample')
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
        env = dict(__import__('os').environ, AIUR_COMPONENTS_ROOT=str(root))
        result = subprocess.run([sys.executable, str(repo / 'scripts/check-components.py'),
                                 '--rules', 'ownership'], env=env, capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode == code, f'{name}: {output}'
        assert expected in output, f'{name}: missing {expected!r}: {output}'
    print(f'PASS: {name}')


run('valid state file pattern', ['file: src/runtime/event-id.json'],
    ['src/runtime/event-id.json'], 0, '1 state paths owned once')
run('stale state file pattern', ['file: src/runtime/missing.json'], [], 1,
    'state file pattern')
run('malformed state file pattern', ['file: ../outside.json'], [], 2, 'invalid string')
declarations = ['src/lib/aiur/config/schema.ex', 'src/lib/aiur/env/schema.ex',
                'src/lib/aiur/config/paths.ex']
second = fixture_component('b', ['src/runtime/subscriptions/*.json', *declarations])
first = fixture_component('a', ['src/runtime/subscriptions/*.json', *declarations])
for item in (first, second):
    item['owns'].update(state=['file: src/runtime/subscriptions/*.json', 'fixture_dir'],
                        config=['fixture'], env=['AIUR_FIXTURE'])
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
    (root / 'components.json').write_text(json.dumps({'manifest_version': 1,
        'directory_published': False, 'components': [first, second], 'features': []}))
    for path, content in {
        'src/lib/aiur/config/schema.ex': 'embeds_one(:fixture, Fixture)\n',
        'src/lib/aiur/env/schema.ex': '{"AIUR_FIXTURE", type: :string}\n',
        'src/lib/aiur/config/paths.ex': 'def fixture_dir, do: "/tmp"\n',
    }.items():
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
    env = dict(__import__('os').environ, AIUR_COMPONENTS_ROOT=str(root))
    result = subprocess.run([sys.executable, str(repo / 'scripts/check-components.py'),
        '--rules', 'ownership'], env=env, capture_output=True, text=True)
    output = result.stdout + result.stderr
    assert result.returncode == 1 and 'owned twice: a, b' in output, output
print('PASS: duplicate state file pattern')
