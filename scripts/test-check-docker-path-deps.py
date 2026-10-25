#!/usr/bin/env python3
"""Prove the Docker path dependency guard catches an omitted COPY."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class DockerPathDependencyTest(unittest.TestCase):
    def test_missing_copy_fails_and_covering_copy_passes(self):
        with tempfile.TemporaryDirectory(prefix='docker-path-deps-', dir=os.environ.get('TMPDIR')) as temp:
            root = Path(temp)
            (root / 'src').mkdir()
            (root / 'scripts').mkdir()
            (root / 'src/mix.exs').write_text('deps: [{:voice_converse, path: "../packages/elixir/voice_converse"}]\n')
            checker = root / 'scripts/check-docker-path-deps.py'
            checker.write_text((SOURCE / 'check-docker-path-deps.py').read_text())
            dockerfile = root / 'Dockerfile'
            dockerfile.write_text('FROM ubuntu\n')
            result = subprocess.run(['python3', str(checker)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('packages/elixir/voice_converse', result.stderr)
            dockerfile.write_text('RUN mix deps.get\nCOPY . .\n')
            result = subprocess.run(['python3', str(checker)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            dockerfile.write_text('COPY packages/elixir/ ./somewhere/\n')
            result = subprocess.run(['python3', str(checker)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            dockerfile.write_text('COPY packages/elixir/ ./packages/elixir/\n')
            result = subprocess.run(['python3', str(checker)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
