"""Drive the real offline CLI, including timestamp-independent checks."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'fixtures/stats/experiments'


class CommandTest(unittest.TestCase):
    def test_cli_reproducibility_tampering_and_invalid_annotation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for kind in ('spec', 'snapshot'):
                shutil.copyfile(FIXTURES / f'shift-{kind}.json', root / f'{kind}.json')
            def run(*args):
                return subprocess.run([str(ROOT / 'analytics/experiment-stats'),
                                       '--experiment-dir', str(root), *args],
                                      capture_output=True, text=True, check=False)
            self.assertEqual(run('--now', '2026-10-09T00:00:00Z').returncode, 0)
            first = (root / 'result.json').read_bytes()
            self.assertEqual(run('--now', '2026-10-09T00:00:00Z').returncode, 0)
            self.assertEqual(first, (root / 'result.json').read_bytes())
            self.assertEqual(run('--now', '2026-10-10T00:00:00Z').returncode, 0)
            self.assertEqual(json.loads(first)['body'], json.loads((root / 'result.json').read_text())['body'])
            self.assertEqual(run('--check').returncode, 0)
            stored = json.loads(first)
            stored['body']['metrics']['latency']['p_raw'] += 1e-30
            (root / 'result.json').write_text(json.dumps(stored))
            failed = run('--check')
            self.assertEqual(failed.returncode, 1, failed.stderr)
            self.assertIn('p_raw', failed.stderr)
            self.assertIn('result.json/body', failed.stderr)
            (root / 'annotations.json').write_text('{bad')
            failed = run()
            self.assertEqual(failed.returncode, 2)
            self.assertIn('Expecting', failed.stderr)
            self.assertEqual(json.loads((root / 'result.json').read_text()), stored)

    def test_invalid_timestamp_nonfinite_and_missing_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            command = [str(ROOT / 'analytics/experiment-stats'), '--experiment-dir', str(root)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            for kind in ('spec', 'snapshot'):
                shutil.copyfile(FIXTURES / f'guard-{kind}.json', root / f'{kind}.json')
            self.assertEqual(subprocess.run(command + ['--now', 'yesterday'], capture_output=True).returncode, 2)
            (root / 'annotations.json').write_text('{"flags":NaN}')
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertFalse((root / 'result.json').exists())
