#!/usr/bin/env python3
"""Bound the effect of an omitted public GitHub source on retained gap spans.

Does not execute the original classifier, fetch data or emit raw source text.
The result is sensitivity evidence, not a replacement uptime/causality model.
"""
import argparse
import hashlib
import json
from collections import Counter
from datetime import datetime
from pathlib import Path

EXCLUDED = set("mentioned subscribed unsubscribed head_ref_deleted base_ref_changed comment_deleted connected disconnected pinned unpinned locked unlocked transferred user_blocked".split())

def audit(root):
    hashes = {}
    def read(relative):
        path = root / relative
        hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        return [json.loads(line) for line in path.read_text().splitlines() if line]
    def timestamp(value):
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    events = []
    def add(value, kind):
        if value:
            events.append((timestamp(value), kind))
    prefix = "gh/aiur-team_architecture-docs."
    for row in read(prefix + "issue_events.jsonl"):
        if row["event"] in EXCLUDED:
            continue
        if row["event"] in ("labeled", "unlabeled") and row.get("label") == "agent:ci-wait" and row["actor"] == "aiur-daemon[bot]":
            continue
        add(row["created_at"], "issue_event")
    for row in read(prefix + "pulls2.jsonl"):
        add(row.get("created_at"), "pr_open")
        add(row.get("merged_at"), "pr_merge")
    for row in read(prefix + "reviews.jsonl"):
        add(row.get("submitted_at"), "review")
    for row in read(prefix + "issue_comments.jsonl"):
        if row["user"] != "netlify[bot]":
            add(row["created_at"], "comment")
    gaps = read("gap_rows30.jsonl")
    affected = []
    counts = Counter()
    original = sum(row["end"] - row["start"] for row in gaps)
    split_total = 0
    for row in gaps:
        contained = [(t, kind) for t, kind in events
                     if row["repo"] == "archon" and row["start"] < t < row["end"]]
        points = sorted({t for t, _ in contained})
        boundaries = [row["start"], *points, row["end"]]
        retained = sum(b-a for a,b in zip(boundaries, boundaries[1:]) if b-a >= 1800)
        split_total += retained
        if points:
            affected.append({"distinct_progress_timestamps": len(points),
                             "original_hours": (row["end"]-row["start"])/3600,
                             "remaining_30_min_gap_hours": retained/3600})
            counts.update(kind for _, kind in contained)
    return {
        "claim": "gaps-01",
        "method": "Apply the original progress inclusion rules to the separately "
                  "fetched architecture-docs cache; intersect strictly inside retained "
                  "archon-alias >=30-minute gaps, then split them at distinct timestamps.",
        "input_sha256": hashes,
        "qualifying_source_records_by_kind": dict(sorted(Counter(k for _, k in events).items())),
        "records_inside_retained_gaps_by_kind": dict(sorted(counts.items())),
        "affected_gap_count": len(affected),
        "affected_gaps_aggregate_only": affected,
        "original_total_gap_hours": original / 3600,
        "split_total_gap_hours": split_total / 3600,
        "reduction_hours_within_fixed_spans": (original-split_total) / 3600,
        "limits": [
            "The original analyzer maps architecture-docs wakes and runtime to archon, "
            "but GHREPO maps archon only to its own GitHub cache.",
            "This is additive source coverage sensitivity, not a corrected final ratio. "
            "The original active spans and other missing or misclassified events remain unaudited.",
            "Progress events may be bookkeeping, unsuccessful control attempts or unrelated "
            "to runnable work; their absence does not prove no productive activity.",
            "No category reclassification, historical uptime proof, runtime testing or saving claim.",
            "Private rows contribute only to aggregate retained-gap totals; no private "
            "event text, identities, paths or timestamps are emitted."
        ]
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = audit(args.root)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in (
        "affected_gap_count", "original_total_gap_hours", "split_total_gap_hours",
        "reduction_hours_within_fixed_spans")}))
