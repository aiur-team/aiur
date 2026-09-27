#!/usr/bin/env python3
"""Audit retained gap measurements without loading the original analysis code.

Inputs are local scratch artifacts and can contain private material. Output is
aggregate counts only: no repository identities, event text, paths or times.
This checks arithmetic and attendance quantization, not source completeness or
causal attribution. It never overwrites inputs.
"""
import argparse
import bisect
from collections import Counter
import csv
import hashlib
import json
import math
from pathlib import Path


def audit(root, csv_input=None, csv_output=None):
    paths = {name: root / name for name in
             ('gap_rows15.jsonl', 'exec_events.tsv', 'analysis_meta.json')}
    rows = [json.loads(line) for line in paths['gap_rows15.jsonl'].read_text().splitlines()]
    meta = json.loads(paths['analysis_meta.json'].read_text())
    activity = set()
    for line in paths['exec_events.tsv'].read_text().splitlines():
        fields = line.split('\t')
        kind = fields[3]
        if kind in ('assistant', 'codex_exec_activity', 'subagent') or kind.startswith('tool:'):
            activity.add(math.floor(float(fields[0]) / 60))
    activity = sorted(activity)

    def attended(minute):
        i = bisect.bisect_left(activity, minute - 60)
        return i < len(activity) and activity[i] <= minute + 60

    results = []
    for row in rows:
        a, b = row['start'], row['end']
        duration = b - a
        bins = range(math.floor(a / 60), math.floor(b / 60))
        old_attended = sum(attended(m) for m in bins)
        reproduced = round(old_attended * 60 / max(60, duration), 3)
        assert reproduced == row['attended_frac'], 'Retained attendance does not reproduce'
        assert len(bins) == sum(row['split'].values()), 'Category bins do not reproduce'
        # Keep the original attendance predicate, but count the actual seconds
        # each minute intersects the gap, including a partial final minute.
        weighted = sum(max(0, min(b, (m + 1) * 60) - max(a, m * 60))
                       for m in range(math.floor(a / 60), math.ceil(b / 60))
                       if attended(m))
        assert 0 <= weighted <= duration + 0.001
        results.append((row, duration, old_attended * 60, weighted))

    if csv_input is not None:
        assert csv_output is not None and csv_input.resolve() != csv_output.resolve()
        def key(repo, minutes, split, fraction):
            return (repo, float(minutes), tuple(int(split.get(k, 0)) for k in 'abcdef'), float(fraction))
        corrected = {}
        for row, duration, _, weighted in results:
            identity = key(row['repo'], row['minutes'], row['split'], row['attended_frac'])
            assert identity not in corrected, 'Ambiguous retained row identity'
            corrected[identity] = round(weighted / duration, 6)
        with csv_input.open(newline='') as source:
            reader = csv.DictReader(source)
            fields = list(reader.fieldnames)
            csv_rows = list(reader)
        new_field = 'duration_weighted_attended_frac'
        assert new_field not in fields
        assert len(csv_rows) == len(corrected)
        seen = set()
        for row in csv_rows:
            repo = row['repo'].removesuffix(' (private)')
            identity = key(repo, row['minutes'], {k: row['min_' + k] for k in 'abcdef'}, row['attended_frac'])
            assert identity in corrected and identity not in seen, 'CSV identity mismatch'
            seen.add(identity)
            row[new_field] = corrected[identity]
        with csv_output.open('w', newline='') as target:
            writer = csv.DictWriter(target, fieldnames=fields + [new_field])
            writer.writeheader()
            writer.writerows(csv_rows)

    thresholds = []
    for minutes in (15, 30, 1440):
        selected = [x for x in results if x[1] >= minutes * 60]
        seconds = sum(x[1] for x in selected)
        thresholds.append({
            'threshold_minutes': minutes,
            'gap_count': len(selected),
            'exact_gap_hours': seconds / 3600,
            'historical_category_bin_hours': sum(sum(x[0]['split'].values()) for x in selected) / 60,
            'historical_attendance_over_one_count': sum(x[0]['attended_frac'] > 1 for x in selected),
            'historical_max_attendance_fraction': max(x[0]['attended_frac'] for x in selected),
            'historical_attended_hours': sum(x[2] for x in selected) / 3600,
            'duration_weighted_attended_hours': sum(x[3] for x in selected) / 3600,
            'duration_weighted_unattended_hours': sum(x[1] - x[3] for x in selected) / 3600,
            'historical_majority_attended_gaps': sum(x[0]['attended_frac'] >= 0.5 for x in selected),
            'duration_weighted_majority_attended_gaps': sum(x[3] / x[1] >= 0.5 for x in selected),
        })
    run_hours = sum(run['hours'] for run in meta['runs'])
    current = [r for r in rows if r['repo'] in ('aiur', 'khala') and r['era'] == 'runlog'
               and r['end'] - r['start'] >= 1800]
    categories = sum((Counter(r['split']) for r in current), Counter())
    reasons = sum((Counter(r['reasons']) for r in current), Counter())
    waiting = sum(n for reason, n in reasons.items() if 'items wait on it' in reason)
    stranded = sum(n for reason, n in reasons.items() if 'stranded' in reason)
    return {
        'scope': 'Retained historical model, not a new source-completeness or causal audit. Private sources contribute aggregate counts only (private).',
        'input_sha256': {name: hashlib.sha256(p.read_bytes()).hexdigest() for name, p in paths.items()},
        'retained_run_count': len(meta['runs']),
        'retained_active_run_hours': run_hours,
        'exact_30_min_gap_share_percent': thresholds[1]['exact_gap_hours'] / run_hours * 100,
        'thresholds': thresholds,
        'current_public_repos_model': {
            'note': 'aiur and khala; category b and c-waiting are classification output, not independently established causes.',
            'category_bin_hours': {k: v / 60 for k, v in sorted(categories.items())},
            'c_waiting_hours': waiting / 60,
            'b_plus_c_waiting_share_percent': (categories['b'] + waiting) / sum(categories.values()) * 100,
            'stranded_reason_hours': stranded / 60,
        },
        'attendance_method': 'Reproduced every original fraction using global assistant/tool/Codex/subagent activity within +/-60 minute indices. Corrected aggregate weights each qualifying minute by its intersection in seconds with the gap, including the final partial minute. Human-message-only presence is not part of this historical attendance metric.',
        'limits': 'Does not repair the minute-level category classifier or infer dispatchability, operator absence, active daemon uptime, consumed wakes or historical causal loss. Exact durations still depend on the inherited progress definition and captured sources.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_gap_scratch', type=Path)
    parser.add_argument('--csv-input', type=Path)
    parser.add_argument('--csv-output', type=Path)
    args = parser.parse_args()
    if bool(args.csv_input) != bool(args.csv_output):
        parser.error('Both CSV options are required together')
    print(json.dumps(audit(args.local_gap_scratch, args.csv_input, args.csv_output), indent=2))
