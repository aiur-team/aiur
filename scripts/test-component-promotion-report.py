#!/usr/bin/env python3
"""Exercise the component report against a fixture with both debt directions."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
checker = repo / 'scripts/check-components.py'
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    shutil.copytree(repo / 'scripts/components/fixtures/promotion_report', root, dirs_exist_ok=True)
    shutil.copyfile(repo / 'components.schema.json', root / 'components.schema.json')
    sys.path.insert(0, str(repo / 'scripts'))
    from components.public_fixtures import complete_fixture
    complete_fixture(root)
    result = subprocess.run([sys.executable, str(checker), '--rules', 'elixir',
                             '--component', 'a', '--report'],
                            env=dict(os.environ, AIUR_COMPONENTS_ROOT=str(root)),
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    for row in ('outbound\tR-private\ta\tB.Internal\tlive',
                'inbound\tR-private\tb\tA\tlive',
                'outbound\tR-declared\ta\tB.Gone\tstale'):
        assert row in output, f'missing {row!r}: {output}'
print('PASS: component_debt_reports_both_directions')
