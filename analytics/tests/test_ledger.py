import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from analytics import ledger, ledger_schema, ledger_store, reduce as reducer
from analytics.ledger_backfill import main as backfill


def event(name, at, boot='A', ticket='42', **attrs):
    raw = {'schema_version': 3, 'kind': 'lifecycle', 'timestamp': '2026-10-09T' + at + ':00Z',
           'boot_id': boot, 'sequence': int(at.replace(':', '')), 'record_id': boot + name + at,
           'attributes': {'ticket': ticket, 'event': name, 'boundary': 'point', **attrs}}
    record, warning = reducer.parse_line(json.dumps(raw), boot, 1)
    assert warning is None
    return record


class LedgerTests(unittest.TestCase):
    def test_cross_launch_cohort_and_mixed_retry(self):
        dispatch = event('dispatch', '10:00', backend='claude', attempt_id='try1')
        merged = event('pr_merged', '11:00', boot='B')
        record = ledger.build_ticket_record([dispatch, merged], [])
        self.assertEqual(record['cohort']['backend'], 'claude')
        self.assertEqual(record['milestones']['merged'], {'at': '2026-10-09T11:00:00Z', 'status': 'observed', 'source': 'telemetry'})
        self.assertEqual(record['milestones']['first_dispatch']['at'], '2026-10-09T10:00:00Z')
        retry = event('dispatch', '10:30', boot='B', backend='codex', attempt_id='try2', retry_attempt=1)
        record = ledger.build_ticket_record([dispatch, retry, merged], [])
        self.assertEqual(record['cohort']['backend'], 'mixed')
        self.assertIn('backend', record['cohort']['mixed'])
        self.assertEqual(record['counts']['dispatches'], 2)
        self.assertEqual(record['counts']['retries'], 1)
        ledger_schema.validate(record)

    def test_context_selected_at_dispatch_not_latest_in_boot(self):
        first = event('context', '09:00', config_hash='old')
        last = event('context', '11:00', config_hash='new')
        for row in (first, last):
            row['kind'] = 'run_context'
        record = ledger.build_ticket_record([event('dispatch', '10:00')], [first, last])
        self.assertEqual(record['attempts'][0]['run_context']['config_hash'], 'old')
        self.assertEqual(record['cohort']['config_hash'], 'old')

    def test_dwell_rounds_facts_usage_and_revert(self):
        events = [event('dispatch', '09:00'), event('implement', '09:01', boundary='start'),
                  event('state_change', '10:00', from_state='in-progress', to_state='ci-wait'),
                  event('state_change', '10:20', from_state='ci-wait', to_state='rework'),
                  event('state_change', '10:30', from_state='rework', to_state='ci-wait'),
                  event('state_change', '10:40', from_state='ci-wait', to_state='rework'),
                  event('state_change', '10:45', from_state='rework', to_state='human-review'),
                  event('ticket_usage', '11:00', input_tokens=123, cost_amount=0.5, coverage='complete'),
                  event('pr_facts', '11:01', pr_created_at='2026-10-09T09:30:00Z',
                        pr_ready_at='2026-10-09T09:35:00Z', first_review_at='2026-10-09T10:20:00Z',
                        first_approval_at='2026-10-09T10:50:00Z', merged_at='2026-10-09T11:00:00Z',
                        merge_commit_sha='abc', additions=12, changes_requested_count=2)]
        record = ledger.build_ticket_record(events, [], timeline=[{'sha': 'def', 'revert_of': 'abc'}])
        self.assertEqual(record['durations_ms']['ci_wait_total'], 1800000)
        self.assertEqual(record['durations_ms']['rework_total'], 900000)
        self.assertEqual(record['counts']['rework_rounds'], 2)
        self.assertEqual(record['counts']['changes_requested'], 2)
        self.assertEqual(record['facts']['reverted_by'], 'def')
        self.assertEqual(record['usage']['input_tokens'], 123)
        self.assertEqual(record['milestones']['first_work']['at'], '2026-10-09T09:01:00Z')
        self.assertEqual(record['milestones']['first_approval']['source'], 'github')
        ledger_schema.validate(record)

    def test_twenty_minute_ci_wait(self):
        record = ledger.build_ticket_record([
            event('state_change', '10:00', from_state='in-progress', to_state='ci-wait'),
            event('state_change', '10:20', from_state='ci-wait', to_state='human-review')], [])
        self.assertEqual(record['durations_ms']['ci_wait_total'], 1200000)

    def test_missing_dispatch_is_unavailable_not_a_plausible_default(self):
        merged = event('pr_merged', '11:00')
        merged['schema_version'] = 2
        record = ledger.build_ticket_record([merged], [])
        self.assertEqual(record['milestones']['first_dispatch'], {'at': None, 'status': 'unavailable', 'source': 'missing'})
        self.assertTrue(record['quality']['capture_partial'])
        self.assertTrue(record['quality']['pre_x1'])
        self.assertEqual(record['cohort']['backend'], 'unknown')
        ledger_schema.validate(record)
        record['body'] = 'private prose'
        with self.assertRaises(ValueError):
            ledger_schema.validate(record)

    def test_incremental_retention_history_noop_and_truncated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a, b = root / 'a.ndjson', root / 'b.ndjson'
            dispatch = event('dispatch', '10:00', backend='claude', body='PRIVATE')
            opened = event('pr_opened', '10:10')
            merged = event('pr_merged', '11:00', boot='B')
            def write(path, records):
                path.write_text(''.join(json.dumps(row) + '\n' for row in records))
            write(a, [dispatch, opened])
            write(b, [dispatch, merged])
            with b.open('a') as handle:
                handle.write('{broken')
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                written = ledger_store.materialize([a, b], root)
            self.assertIn('truncated_line', stderr.getvalue())
            self.assertEqual(len(written), 1)
            target = Path(written[0])
            record = json.loads(target.read_text())
            self.assertEqual(record['counts']['dispatches'], 1)
            self.assertEqual(record['cohort']['backend'], 'claude')
            self.assertNotIn('PRIVATE', (root / 'analytics/ledger-cursor.json').read_text())
            mtime = target.stat().st_mtime_ns
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ledger_store.materialize([a, b], root, since='2026-10-09'), [])
            self.assertEqual(target.stat().st_mtime_ns, mtime)
            a.unlink()
            timeline = root / 'analytics/repo-timeline.ndjson'
            facts = event('pr_facts', '11:10', boot='B', merge_commit_sha='abc')
            write(b, [merged, facts])
            timeline.write_text(json.dumps({'sha': 'def', 'revert_of': 'abc'}) + '\n')
            ledger_store.materialize([b], root)
            updated = json.loads(target.read_text())
            self.assertEqual(updated['milestones']['first_dispatch']['at'], '2026-10-09T10:00:00Z')
            self.assertEqual(updated['facts']['reverted_by'], 'def')
            self.assertEqual(len(list((target.parent / '.history').glob('*.json'))), 1)
            ledger_schema.validate(updated)


    def test_blocker_clearance_is_derived_and_terminal_history_is_capped(self):
        record = ledger.build_ticket_record([event('dispatch', '10:00', blockers=['7', '8'])], [],
                                            facts={'blocker_merges': {'7': '2026-10-09T09:00:00Z', '8': '2026-10-09T09:30:00Z'}})
        self.assertEqual(record['milestones']['blockers_cleared'],
                         {'at': '2026-10-09T09:30:00Z', 'status': 'derived', 'source': 'telemetry'})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'telemetry.ndjson'
            path.write_text(json.dumps(event('pr_merged', '10:00')) + '\n')
            ledger_store.materialize([path], root)
            for minute in range(1, 8):
                row = event('pr_facts', '10:%02d' % minute, additions=minute)
                with path.open('a') as handle:
                    handle.write(json.dumps(row) + '\n')
                ledger_store.materialize([path], root)
            self.assertEqual(len(list((root / 'analytics/tickets/.history').glob('42.*.json'))), 5)
            self.assertEqual(json.loads((root / 'analytics/tickets/42.json').read_text())['facts']['additions'], 7)

    def test_malformed_input_is_reported_and_adjacent_ticket_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'telemetry.ndjson'
            bad = event('dispatch', '10:00', backend={'body': 'private'})
            path.write_text(json.dumps(bad) + '\n' + json.dumps(event('pr_merged', '11:00')) + '\n')
            with contextlib.redirect_stderr(io.StringIO()) as warnings:
                ledger_store.materialize([path], root)
            self.assertIn('invalid_ledger_input', warnings.getvalue())
            self.assertTrue((root / 'analytics/tickets/42.json').exists())
            self.assertNotIn('private', (root / 'analytics/ledger-cursor.json').read_text())

    def test_event_key_dedupe_and_since(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a, b = root / 'a.ndjson', root / 'b.ndjson'
            row = event('ci_result', '10:00', outcome='failed', event_key='same')
            duplicate = {**row, 'record_id': 'second'}
            a.write_text(json.dumps(row) + '\n')
            b.write_text(json.dumps(duplicate) + '\n')
            self.assertEqual(ledger_store.materialize([a,b], root, since='2026-10-10'), [])
            ledger_store.materialize([a,b], root, since='2026-10-09')
            record = json.loads((root / 'analytics/tickets/42.json').read_text())
            self.assertEqual(record['counts']['ci_failures'], 1)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                backfill(['--telemetry', str(a), '--state-node', str(root), '--since', '2026-10-09'])
            self.assertEqual(json.loads(output.getvalue())['written'], 0)
