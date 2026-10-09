"""Incremental, locked ledger materialization; sanitized evidence survives retention."""
from __future__ import annotations

import fcntl
import hashlib
import json
import sys
from pathlib import Path

from . import ledger, ledger_schema, reduce as reducer, sources


def read_json(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding='utf-8'))


def _warn(warning):
    print('analytics ledger: ' + json.dumps(warning), file=sys.stderr)


def _ingest(files, cache):
    touched = set()
    for path in files:
        path = Path(path)
        key = str(path.resolve())
        try:
            stat = path.stat()
            with path.open('rb') as handle:
                prefix = hashlib.sha256(handle.read(min(256, stat.st_size))).hexdigest()
                previous = cache['files'].get(key, {})
                offset = previous.get('offset', 0)
                # Append-only streams may grow from fewer than 256 bytes.
                same = previous.get('inode') == stat.st_ino and previous.get('prefix') == prefix
                if not same or stat.st_size < offset:
                    offset = 0
                handle.seek(offset)
                line = previous.get('line', 0) if offset else 0
                while raw := handle.readline():
                    if not raw.endswith(b'\n'):
                        _warn({'type': 'truncated_line', 'path': key, 'offset': handle.tell() - len(raw)})
                        break
                    line += 1
                    try:
                        record, warning = reducer.parse_line(raw.decode('utf-8'), key, line)
                    except UnicodeDecodeError:
                        record, warning = None, {'type': 'invalid_encoding', 'path': key, 'line': line}
                    if warning:
                        _warn(warning)
                        if key not in cache['partial_files']:
                            cache['partial_files'].append(key)
                    try:
                        projected = ledger.project(record) if record else None
                    except ValueError as error:
                        _warn({'type': 'invalid_ledger_input', 'path': key, 'line': line, 'reason': str(error)})
                        projected = None
                    if projected:
                        projected['source_offset'] = offset
                        projected['source_end'] = handle.tell()
                        record_id = projected['record_id']
                        if record_id not in cache['records']:
                            cache['records'][record_id] = projected
                            ticket = projected['attributes'].get('ticket')
                            if ticket:
                                touched.add(ticket)
                            elif projected['kind'] == 'run_context':
                                touched.update(r['attributes'].get('ticket') for r in cache['records'].values()
                                               if r['boot_id'] == projected['boot_id'] and r['attributes'].get('ticket'))
                    offset = handle.tell()
                cache['files'][key] = {'inode': stat.st_ino, 'prefix': prefix, 'offset': offset, 'line': line}
        except OSError as error:
            _warn({'type': 'file_read_error', 'path': key, 'reason': str(error)})
    return touched


def _dedupe(records):
    kept, ids, keys = [], set(), set()
    for record in sorted(records, key=reducer._record_sort_key):
        attrs = record['attributes']
        event_key = attrs.get('event_key')
        # Segment continuation preserves event time and attempt identity.
        if attrs.get('event') in ('dispatch', 'pr_opened', 'pr_merged'):
            event_key = (attrs.get('ticket'), attrs.get('event'), attrs.get('attempt_id'), record['timestamp'])
        if record['record_id'] in ids or event_key and event_key in keys:
            continue
        ids.add(record['record_id'])
        if event_key:
            keys.add(event_key)
        kept.append(record)
    return kept


def materialize(files, state_node: Path, since: str | None = None, repo: str | None = None):
    root = sources.analytics_root(state_node)
    root.mkdir(parents=True, exist_ok=True)
    with (root / '.ledger.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _materialize(files, root, since, repo)


def _materialize(files, root, since, repo):
    cursor_path = root / 'ledger-cursor.json'
    cache = read_json(cursor_path, {'files': {}, 'records': {}, 'timeline_hash': None, 'partial_files': []})
    previous_cache = json.dumps(cache, sort_keys=True)
    cache.setdefault('partial_files', [])
    touched = _ingest(files, cache)
    records = _dedupe(list(cache['records'].values()))
    contexts = [r for r in records if r['kind'] == 'run_context']
    tickets = {}
    for record in records:
        ticket = record['attributes'].get('ticket')
        if ticket and record['kind'] == 'lifecycle':
            tickets.setdefault(ticket, []).append(record)
    timeline_path = root / 'repo-timeline.ndjson'
    timeline = []
    if timeline_path.exists():
        for line in timeline_path.read_text(encoding='utf-8').splitlines():
            try:
                row = json.loads(line)
                if isinstance(row, dict):
                    timeline.append(row)
            except ValueError:
                _warn({'type': 'malformed_timeline_line'})
    timeline_hash = hashlib.sha256(json.dumps(timeline, sort_keys=True).encode()).hexdigest()
    if cache['timeline_hash'] != timeline_hash or since:
        touched.update(tickets)
    cache['timeline_hash'] = timeline_hash
    blocker_merges = {}
    for ticket, events in tickets.items():
        for row in events:
            attrs = row['attributes']
            merged_at = row['timestamp'] if attrs.get('event') == 'pr_merged' else attrs.get('merged_at')
            if merged_at:
                blocker_merges[ticket] = merged_at
    # A newly merged blocker can change an otherwise untouched dependent.
    touched.update(ticket for ticket, events in tickets.items() if any(
        isinstance(row['attributes'].get('blockers'), list) and
        set(row['attributes']['blockers']) & touched for row in events))
    target_dir = root / 'tickets'
    target_dir.mkdir(exist_ok=True)
    written = []
    cutoff = reducer._parse_timestamp(since) if since else None
    for ticket in sorted(touched):
        events = tickets.get(ticket, [])
        if not events or cutoff and reducer._parse_timestamp(events[-1]['timestamp']) < cutoff:
            continue
        if sources._safe_segment(ticket) != ticket or ticket in ('.', '..'):
            _warn({'type': 'invalid_ticket_identifier'})
            continue
        record = ledger.build_ticket_record(events, contexts, facts={'blocker_merges': blocker_merges}, timeline=timeline)
        if repo:
            record['repo'] = repo
        if any(row['source_path'] in cache['partial_files'] for row in events):
            record['quality']['capture_partial'] = True
            record['quality']['warnings'].append('input_partial')
        try:
            ledger_schema.validate(record)
        except ValueError as error:
            _warn({'type': 'invalid_ticket_record', 'ticket': ticket, 'reason': str(error)})
            continue
        path = target_dir / (ticket + '.json')
        old = read_json(path, None)
        if old and {k: v for k, v in old.items() if k != 'generated_at'} == {k: v for k, v in record.items() if k != 'generated_at'}:
            continue
        if old and (old['milestones']['merged']['at'] or old['milestones']['closed']['at']):
            history = target_dir / '.history'
            history.mkdir(exist_ok=True)
            version = history / (ticket + '.' + sources._safe_segment(old['generated_at']) + '.json')
            reducer._atomic_write(version, json.dumps(old, indent=2) + '\n')
            for stale in sorted(history.glob(ticket + '.*.json'))[:-5]:
                stale.unlink()
        reducer._atomic_write(path, json.dumps(record, indent=2) + '\n')
        written.append(str(path))
    if previous_cache != json.dumps(cache, sort_keys=True):
        reducer._atomic_write(cursor_path, json.dumps(cache, sort_keys=True) + '\n')
    return written
