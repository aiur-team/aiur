import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from analytics import ledger_store
from analytics.ledger_backfill import main
from .test_ledger import event


class EnrichmentTests(unittest.TestCase):
    def test_backfill_fetches_missing_facts_once_and_uses_canonical_size_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stream = root / 'telemetry.ndjson'
            stream.write_text(''.join(json.dumps(row) + '\n' for row in [event('dispatch', '10:00'), event('pr_merged', '11:00')]))
            facts = {'coverage': 'available', 'pr_created_at': '2026-10-09T10:20:00Z', 'pr_ready_at': None,
                     'changed_files': 4, 'commit_count': 2, 'review_count': 3, 'body': 'PRIVATE'}
            response = SimpleNamespace(returncode=0, stdout='build message\n' + json.dumps({'42': {'facts': facts}}), stderr='')
            args = ['--telemetry', str(stream), '--state-node', str(root), '--repo', 'owner/repo', '--since', '2026-10-09']
            with patch('analytics.ledger_enrich.subprocess.run', return_value=response) as fetch:
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(main(args), 0)
                self.assertEqual(json.loads(output.getvalue())['observed_percent'], 100.0)
                record = json.loads((root / 'analytics/tickets/42.json').read_text())
                self.assertEqual(record['milestones']['pr_opened']['source'], 'github')
                self.assertEqual(record['facts']['files'], 4)
                self.assertEqual(record['facts']['commits'], 2)
                self.assertEqual(record['facts']['reviews_count'], 3)
                self.assertNotIn('PRIVATE', (root / 'analytics/backfill-facts.ndjson').read_text())
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(main(args), 0)
                self.assertEqual(fetch.call_count, 1)

    def test_fetch_failure_is_reported_and_offline_mode_makes_no_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stream = root / 'telemetry.ndjson'
            stream.write_text(json.dumps(event('pr_merged', '11:00')) + '\n')
            args = ['--telemetry', str(stream), '--state-node', str(root), '--repo', 'owner/repo', '--since', '2026-10-09']
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(['--telemetry', str(stream), '--state-node', str(root), '--since', '2026-10-09'])
            self.assertFalse((root / 'analytics').exists())
            with patch('analytics.ledger_enrich.subprocess.run', return_value=SimpleNamespace(returncode=1)) as fetch:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(main(args), 1)
                self.assertIn('facts_command_failed', errors.getvalue())
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(main(args + ['--no-facts']), 0)
                self.assertEqual(fetch.call_count, 1)
                record = json.loads((root / 'analytics/tickets/42.json').read_text())
                self.assertEqual(record['milestones']['first_dispatch']['status'], 'unavailable')
