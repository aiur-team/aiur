#!/usr/bin/env python3
"""Audit historical gap-boundary associations; emit aggregates, no private text."""
import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo

CUTOFF = datetime(2026, 9, 26, 15, 40, tzinfo=timezone.utc).timestamp()


def epoch(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def union(intervals):
    out = []
    for a, b in sorted(intervals):
        if b <= a:
            continue
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def audit(scratch, state_root):
    bounds = defaultdict(list)
    activity, sessions = set(), {}
    for line in (scratch / 'exec_events.tsv').read_text().splitlines():
        fields = line.split('\t')
        t, kind = float(fields[0]), fields[3]
        if kind in ('assistant', 'codex_exec_activity') or kind.startswith('tool:'):
            activity.add(int(t // 60))
            span = sessions.setdefault(fields[2], [t, t])
            span[0], span[1] = min(span[0], t), max(span[1], t)
        if kind in ('compact_boundary', 'compact_summary'):
            bounds['compaction_record_union'].append(t)
            bounds[kind].append(t)
    for path in state_root.glob('*/*/executor/handoffs/*Z-*.md'):
        match = re.match(r'(\d{8}T\d{6})Z', path.name)
        if match:
            t = datetime.strptime(match[1], '%Y%m%dT%H%M%S').replace(tzinfo=timezone.utc).timestamp()
            if t <= CUTOFF:
                bounds['handoff'].append(t)
    for first, last in sessions.values():
        bounds['session_start'].append(first)
        bounds['session_end'].append(last)
    minutes = sorted(activity)
    bounds['executor_silence_start'] = [a * 60 for a, b in zip(minutes, minutes[1:]) if b - a >= 30]

    limits = []
    for line in (scratch / 'exec_api_errors.tsv').read_text().splitlines():
        fields = line.split('\t')
        if len(fields) < 4 or fields[2] != 'rate_limit':
            continue
        match = re.search(r'resets (\d{1,2})(?::(\d\d))?(am|pm)', fields[3])
        if not match:
            continue
        start = epoch(fields[1])
        local = datetime.fromtimestamp(start, ZoneInfo('America/Los_Angeles'))
        hour = int(match[1]) % 12 + (12 if match[3] == 'pm' else 0)
        reset = local.replace(hour=hour, minute=int(match[2] or 0), second=0, microsecond=0)
        if reset < local:
            reset += timedelta(days=1)
        repo = 'archon' if fields[0] == 'architecture-docs' else fields[0]
        limits.append([start, reset.timestamp(), {repo}])
    merged = []
    for a, b, repos in sorted(limits, key=lambda x: x[0]):
        if merged and a <= merged[-1][1] + 60:
            merged[-1][1] = max(merged[-1][1], b)
            merged[-1][2].update(repos)
        else:
            merged.append([a, b, set(repos)])
    bounds['exec_session_limit'] = [a for a, _, _ in merged]
    gaps = [json.loads(line) for line in (scratch / 'gap_rows30.jsonl').read_text().splitlines()]
    meta = json.loads((scratch / 'analysis_meta.json').read_text())
    # The persisted active bounds are rounded to minutes. Use them only for
    # a labelled approximate baseline; never present them as exact raw uptime.
    active = [[epoch(a), epoch(b)] for spans in meta['active'].values() for a, b, _ in spans]
    active_seconds = sum(b - a for a, b in active)
    rows = {}
    for kind, timestamps in sorted(bounds.items()):
        tolerant = sum(any(g['start'] - 1800 <= t <= g['start'] + 60 for t in timestamps) for g in gaps)
        strict = sum(any(g['start'] - 1800 <= t <= g['start'] for t in timestamps) for g in gaps)
        covered = sum(sum(y - x for x, y in union([[max(a, t), min(b, t + 1800)] for t in timestamps]))
                      for a, b in active)
        base = covered / active_seconds
        rows[kind] = {'boundary_records': len(timestamps), 'historical_tolerant_gap_hits': tolerant,
                      'strict_preceding_gap_hits': strict, 'gap_count': len(gaps),
                      'approximate_base_rate_from_minute_rounded_active_bounds': base,
                      'approximate_strict_lift': strict / len(gaps) / base if base else None}
    overlap = sum(max(0, min(b, g['end']) - max(a, g['start']))
                  for a, b, repos in merged for g in gaps if g['repo'] in repos)
    return {'scope': 'Retained historical model, aggregates only; private sources contribute counts (private). This is association/sensitivity analysis, not causal inference.',
            'boundary_results': rows,
            'strict_same_repository_session_limit_gap_hits': sum(any(g['repo'] in repos and g['start'] - 1800 <= a <= g['start'] for a, _, repos in merged) for g in gaps),
            'session_limit_window_count': len(merged),
            'session_limit_window_hours': sum(b - a for a, b, _ in merged) / 3600,
            'session_limit_gap_overlap_hours': overlap / 3600,
            'limitations': ['Baseline active bounds are persisted at minute precision; exact raw uptime has not been reconstructed.',
                            'The historical boundary association pools events across repositories and uses a globally pooled activity silence signal.',
                            'Compaction summaries and boundaries are separate record kinds, not independent interventions.',
                            'Executor control calls also count as progress; silence and gap definitions share input evidence.',
                            'No uncertainty interval or independent experiment establishes a causal effect; absence of observed lift does not establish absence of harm.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_gap_scratch', type=Path)
    parser.add_argument('local_repo_state_root', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.local_gap_scratch, args.local_repo_state_root), indent=2))
