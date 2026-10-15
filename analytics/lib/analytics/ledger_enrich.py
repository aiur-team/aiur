"""Backfill missing facts through Aiur's canonical governed query, never a second deriver."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from . import ledger_store
from .parse import _now_iso, _parse_timestamp


def fetch_facts(tickets, repo):
    command = [str(Path(__file__).resolve().parents[2] / 'ledger-facts'), repo, *tickets]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        return {ticket: {'error': 'facts_command_failed'} for ticket in tickets}
    # mix and the build gate may emit informational lines before the JSON result.
    try:
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        if isinstance(payload, dict):
            return payload
    except (ValueError, IndexError):
        pass
    return {ticket: {'error': 'invalid_facts_response'} for ticket in tickets}


def enrich(state, since, repo, fetch=fetch_facts):
    root = state / 'analytics'
    cursor = ledger_store.read_json(root / 'ledger-cursor.json', {'records': {}})
    captured = {row['attributes']['ticket'] for row in cursor['records'].values()
                if row['attributes'].get('event') == 'pr_facts' and row['attributes'].get('coverage') == 'available'}
    path = root / 'backfill-facts.ndjson'
    failures = 0
    missing = []
    for record_path in sorted((root / 'tickets').glob('*.json')):
        record = json.loads(record_path.read_text())
        terminal = record['milestones']['merged']['at'] or record['milestones']['closed']['at']
        if not terminal or _parse_timestamp(terminal) < _parse_timestamp(since) or record['ticket'] in captured:
            continue
        missing.append(record)
    responses = fetch([record['ticket'] for record in missing], repo) if missing else {}
    for record in missing:
        response = responses.get(record['ticket'], {'error': 'missing_facts_response'})
        if not isinstance(response, dict) or not (isinstance(response.get('facts'), dict) or isinstance(response.get('error'), str)):
            response = {'error': 'invalid_facts_response'}
        if 'error' in response:
            print('analytics ledger: facts %s %s' % (record['ticket'], response['error']), file=sys.stderr)
            failures += 1
            continue
        attrs = {**response['facts'], 'ticket': record['ticket'], 'event': 'pr_facts', 'boundary': 'point', 'source': 'github'}
        fingerprint = hashlib.sha256(json.dumps(attrs, sort_keys=True).encode()).hexdigest()
        row = {'schema_version': 3, 'kind': 'lifecycle', 'boot_id': 'ledger-backfill', 'timestamp': _now_iso({}),
               'record_id': 'backfill:' + fingerprint, 'sequence': 0, 'attributes': attrs}
        projected = ledger_store.ledger.project({**row, 'timestamp_ms': 0})
        row['attributes'] = projected['attributes']
        with path.open('a') as handle:
            handle.write(json.dumps(row) + '\n')
    return path, failures
