"""Canonical ticket facts, stitched across launches; no metric definitions."""
from __future__ import annotations

from . import ledger_schema, reduce as reducer

ATTEMPT_KEYS = ('backend', 'model', 'effort', 'complexity', 'epic', 'feature', 'tags', 'start_mode', 'blockers', 'retry_attempt')
CONTEXT_KEYS = ('aiur_vsn', 'build_sha', 'package_version', 'config_hash', 'config_section_hashes', 'capture_tags', 'repo')
FACT_KEYS = ('additions', 'deletions', 'files', 'commits', 'merge_commit_sha', 'epic', 'changes_requested_count', 'reviews_count')
FACT_TIMES = {'pr_opened': 'pr_created_at', 'pr_ready': 'pr_ready_at', 'first_review': 'first_review_at',
              'first_approval': 'first_approval_at', 'merged': 'merged_at', 'closed': 'closed_at'}
USAGE_KEYS = ('input_tokens', 'output_tokens', 'cached_tokens', 'cost_amount', 'cost_currency', 'coverage')
EVENT_KEYS = ('ticket', 'event', 'boundary', 'attempt_id', 'operation_id', 'source_id', 'event_key', 'source',
              'from_state', 'to_state', 'outcome', 'blocker', 'segment_continuation') + ATTEMPT_KEYS + FACT_KEYS + tuple(FACT_TIMES.values()) + USAGE_KEYS
LEDGER_EVENTS = ('dispatch', 'implement', 'pr_opened', 'pr_ready', 'pr_merged', 'closed', 'dependency_cleared',
                 'pr_facts', 'ticket_usage', 'ci_result', 'state_change', 'agent_pause', 'agent_resume')
MILESTONES = ('first_dispatch', 'first_work', 'pr_opened', 'pr_ready', 'first_review', 'first_approval',
              'merged', 'closed', 'blockers_cleared')


def project(record: dict) -> dict | None:
    """Drop resource samples and every non-contract attribute before persisting."""
    if record['kind'] not in ('lifecycle', 'run_context'):
        return None
    if not isinstance(record['record_id'], str) or not isinstance(record['boot_id'], str) or type(record['sequence']) is not int:
        raise ValueError('invalid_record_identity')
    attrs = record['attributes']
    if record['kind'] == 'lifecycle' and (not isinstance(attrs.get('ticket'), str) or not isinstance(attrs.get('event'), str)):
        raise ValueError('invalid_lifecycle_identity')
    if record['kind'] == 'lifecycle' and attrs['event'] not in LEDGER_EVENTS:
        return None
    definitions = ledger_schema.SCHEMA['$defs']
    rules = {**definitions['context']['properties'], **definitions['attempt']['properties'],
             **ledger_schema.SCHEMA['properties']['facts']['properties'],
             **ledger_schema.SCHEMA['properties']['usage']['properties']}
    for key, value in attrs.items():
        if key in rules:
            ledger_schema.validate(value, rules[key], key)
        elif key in EVENT_KEYS and not isinstance(value, (str, int, bool, type(None))):
            raise ValueError('invalid_lifecycle_attribute')
    keys = CONTEXT_KEYS if record['kind'] == 'run_context' else EVENT_KEYS
    return {key: value for key, value in record.items() if key != 'attributes'} | {
        'attributes': {key: record['attributes'][key] for key in keys if key in record['attributes']}}


def observed(at: str | None, source: str = 'telemetry') -> dict:
    parsed = reducer._parse_timestamp(at)
    return {'at': parsed.isoformat().replace('+00:00', 'Z') if parsed else None,
            'status': 'observed' if parsed else 'unavailable', 'source': source if parsed else 'missing'}


def build_ticket_record(events: list[dict], run_contexts: list[dict], facts: dict | None = None,
                        timeline: list[dict] | None = None) -> dict:
    events = sorted(events, key=reducer._record_sort_key)
    contexts = sorted(run_contexts, key=reducer._record_sort_key)
    ticket = events[0]['attributes']['ticket']
    milestones = {key: observed(None) for key in MILESTONES}
    aliases = {'dispatch': 'first_dispatch', 'implement': 'first_work', 'pr_opened': 'pr_opened',
               'pr_ready': 'pr_ready', 'pr_merged': 'merged', 'closed': 'closed', 'dependency_cleared': 'blockers_cleared'}
    attempts, fact_values, usage = [], {}, {'coverage': 'unavailable'}
    counts = {'rework_rounds': 0, 'changes_requested': 0, 'ci_failures': 0, 'dispatches': 0, 'retries': 0}
    durations = {'ci_wait_total': 0, 'rework_total': 0, 'paused_total': 0}
    starts = {}
    facts = dict(facts or {})
    for record in events:
        if record['attributes'].get('event') == 'pr_facts':
            facts.update(record['attributes'])
    opened_at = facts.get('pr_created_at') or next((r['timestamp'] for r in events if r['attributes'].get('event') == 'pr_opened'), None)
    for record in events:
        attrs, at = record['attributes'], record['timestamp']
        event = attrs.get('event')
        name = aliases.get(event)
        if name and (event != 'implement' or attrs.get('boundary') == 'start'):
            if milestones[name]['at'] is None or name == 'blockers_cleared':
                milestones[name] = observed(at, 'github' if attrs.get('source') == 'github' else 'telemetry')
        if event == 'dispatch':
            eligible = [c for c in contexts if c['boot_id'] == record['boot_id'] and c['timestamp_ms'] <= record['timestamp_ms']]
            context = eligible[-1]['attributes'] if eligible else {}
            attempts.append({'attempt_id': attrs.get('attempt_id') or record['record_id'],
                             'boot_id': record['boot_id'], 'dispatched_at': at,
                             **{key: attrs.get(key, 'unknown') for key in ATTEMPT_KEYS},
                             'run_context': {key: context.get(key, 'unknown') for key in CONTEXT_KEYS}})
        if event == 'pr_facts':
            facts.update(attrs)
        if event == 'ticket_usage':
            usage = {key: attrs[key] for key in USAGE_KEYS if key in attrs}
            usage.setdefault('coverage', 'unavailable')
        if event == 'ci_result' and attrs.get('outcome') == 'failed':
            counts['ci_failures'] += 1
        if event == 'agent_pause':
            starts.setdefault('paused', record['timestamp_ms'])
        if event == 'agent_resume' and 'paused' in starts:
            durations['paused_total'] += max(0, record['timestamp_ms'] - starts.pop('paused'))
        if event == 'state_change':
            previous, current = attrs.get('from_state'), attrs.get('to_state')
            for state, field in (('ci-wait', 'ci_wait_total'), ('rework', 'rework_total'), ('paused', 'paused_total')):
                if state == previous and state != current and state in starts:
                    durations[field] += max(0, record['timestamp_ms'] - starts.pop(state))
                if state == current and state != previous:
                    starts.setdefault(state, record['timestamp_ms'])
            if current == 'rework' and previous != current and opened_at and reducer._parse_timestamp(at) >= reducer._parse_timestamp(opened_at):
                counts['rework_rounds'] += 1
            if current == 'closed':
                milestones['closed'] = observed(at)
    for name, key in FACT_TIMES.items():
        if facts.get(key):
            candidate = observed(facts[key], 'github')
            if candidate['at']:
                milestones[name] = candidate
    blockers = {blocker for attempt in attempts if isinstance(attempt['blockers'], list) for blocker in attempt['blockers']}
    blocker_times = facts.get('blocker_merges', {})
    if blockers and blockers.issubset(blocker_times) and not milestones['blockers_cleared']['at']:
        latest = max(blocker_times[b] for b in blockers)
        milestones['blockers_cleared'] = {'at': latest, 'status': 'derived', 'source': 'telemetry'}
    fact_values = {key: facts[key] for key in FACT_KEYS if key in facts}
    fact_values['reverted_by'] = next((row.get('sha') or row.get('commit_sha') for row in timeline or []
                                     if row.get('revert_of') and row['revert_of'] == facts.get('merge_commit_sha')), None)
    counts['changes_requested'] = facts.get('changes_requested_count') or 0
    counts['dispatches'] = len(attempts)
    counts['retries'] = sum(isinstance(a['retry_attempt'], int) and a['retry_attempt'] > 0 for a in attempts)
    cohort = {}
    for key in ATTEMPT_KEYS + CONTEXT_KEYS:
        if key in ('blockers', 'retry_attempt'):
            continue
        values = [a.get(key, a['run_context'].get(key, 'unknown')) for a in attempts]
        cohort[key] = values[0] if values and all(v == values[0] for v in values) else 'mixed' if values else 'unknown'
    cohort['mixed'] = [key for key, value in cohort.items() if value == 'mixed']
    partial = not milestones['first_dispatch']['at'] or not milestones['pr_opened']['at']
    return {'schema_version': 1, 'ticket': ticket, 'repo': cohort.get('repo') or 'unknown',
            'generated_at': reducer._now_iso({}), 'last_event_at': events[-1]['timestamp'],
            'sources': [{'record_id': r['record_id'], 'path': r['source_path'], 'line': r['source_line'], 'byte_start': r.get('source_offset'),
                         'byte_end': r.get('source_end'), 'schema_version': r['schema_version']} for r in events],
            'cohort': cohort, 'attempts': attempts, 'milestones': milestones, 'durations_ms': durations,
            'counts': counts, 'facts': fact_values, 'usage': usage,
            'quality': {'capture_partial': partial, 'mixed_cohort': bool(cohort['mixed']),
                        'pre_x1': any(r['schema_version'] < 3 for r in events),
                        'warnings': ['missing_dispatch'] if not milestones['first_dispatch']['at'] else []}}
