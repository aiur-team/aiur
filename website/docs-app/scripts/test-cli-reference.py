#!/usr/bin/env python3
"""Exercise the shipped CLI checker with split pages and real parser sources."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class CliReferenceTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        sources = [
            'scripts/aiurdev',
            'scripts/lib/aiurdev-harness.sh',
            'src/lib/aiur/cli.ex',
            'src/lib/aiur/experiments_cli.ex',
            'src/lib/aiur/alerts_cli.ex',
            'src/lib/aiur/pr_merge_cli.ex',
            'analytics/lib/analytics/experiment_stats_cmd.py',
            'website/docs-app/scripts/check-cli-reference.sh',
        ]
        sources += [str(p.relative_to(REPO)) for p in (REPO / 'packaging/npm/aiur-cli/libexec').rglob('*.sh')]
        sources += ['packaging/npm/aiur-cli/libexec/aiur-mise-doctor']
        sources += [str(p.relative_to(REPO)) for p in (REPO / 'website/docs-app/reference').glob('*.md')]
        for name in sources:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, target)

    def check(self):
        return subprocess.run(['bash', str(self.root / 'website/docs-app/scripts/check-cli-reference.sh')],
                              capture_output=True, text=True)

    def test_split_reference_covers_every_shipped_command_and_flag(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_removing_a_documented_flag_still_reports_it(self):
        reference = self.root / 'website/docs-app/reference'
        for page in reference.glob('*.md'):
            page.write_text(page.read_text().replace('--allow-remote', '--force'))
        topic = reference / 'cli-split-fixture.md'
        topic.write_text('| `--allow-remote` | Permit the remote test sandbox. | `scripts/aiurdev --test --allow-remote` |\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        topic.unlink()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing CLI rendered-flag marker: --allow-remote', result.stderr)
        self.assertIn('CLI flag lacks syntax, default/interaction, or runnable-example row: --allow-remote', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
