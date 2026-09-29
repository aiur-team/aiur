#!/usr/bin/env python3
"""Audit effective P2/P3 decisions without rewriting independent partitions."""

import collections
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REVIEW = ROOT / "review"
SYNTHESIS = ROOT / "synthesis"
PART2_AND_3 = {
    "skills-prompts-cont-07",
    "skills-prompts-cont-37",
    "skills-prompts-cont-20",
    "skills-prompts-cont-21",
    "skills-prompts-cont-46",
    "skills-prompts-cont-47",
    "skills-prompts-cont-19",
    "nonelixir-web-08",
    "loose-1-10",
}


def read(name):
    return json.loads((ROOT / name).read_text(encoding="utf-8"))


def partition_rows():
    part1 = read("review/p2p3-triage-part-1.json")["items"]
    part2 = read("review/p2p3-triage-part-2.json")
    part3 = read("review/p2p3-triage-part-3.json")["entries"]
    for part, rows in enumerate((part1, part2, part3), start=1):
        for row in rows:
            yield (
                row["finding_id"] if part == 1 else row["id"],
                row["verdict"] if part != 2 else row["assessment"],
                row["proposed_action"] if part == 1 else
                row["proposed_disposition"] if part == 2 else row["disposition"],
            )


def main():
    base = {fid: (verdict, action) for fid, verdict, action in partition_rows()}
    assert len(base) == 889, len(base)

    part1 = read("synthesis/p2p3-part-1-reconciliation.json")["entries"]
    assert len(part1) == 8, len(part1)
    effective = dict(base)
    for fid, row in part1.items():
        assert fid in effective, fid
        assert row["original"] == dict(zip(("verdict", "action"), base[fid])), fid
        assert row["owner"] and row["citations"] and row["behavior_test_gate"], fid
        assert all(row["behavior_test_gate"].get(k) for k in
                   ("setup", "action", "expected", "decision")), fid
        assert row["runtime_incidence"] == "unknown", fid
        revised = row["reconciled"]
        effective[fid] = (revised["verdict"], revised["action"])

    overlay = (SYNTHESIS / "p2p3-triage-reconciliation-overlay.md").read_text(
        encoding="utf-8"
    )
    rows = re.findall(r"^\| `([^`]+)` \| ([^\n]+) \| ([^\n]+) \|$", overlay, re.M)
    seen = {fid for fid, _, _ in rows}
    assert len(rows) == len(seen) == 9, (len(rows), seen)
    assert seen == PART2_AND_3, (seen ^ PART2_AND_3)
    for fid, decision, gate in rows:
        assert fid in effective, fid
        assert "source-supported / fix" in decision, fid
        assert "**" in gate and len(gate) > 40, fid
        effective[fid] = ("source-supported", "fix")

    before = collections.Counter(base.values())
    after = collections.Counter(effective.values())
    changed = sorted(fid for fid in effective if effective[fid] != base[fid])
    assert len(changed) == 9, changed
    assert sum(v for (verdict, action), v in after.items() if action == "fix") == 244
    assert sum(v for (verdict, action), v in after.items() if action == "defer") == 645
    assert sum(v for (verdict, action), v in after.items() if verdict == "source-supported") == 696
    assert sum(v for (verdict, action), v in after.items() if verdict == "unknown") == 192
    assert after[("unsupported", "defer")] == 1
    print("canonical P2/P3 coverage: 889/889")
    print("reconciliation decisions: 17; changed verdict/action: 9")
    print("original:", dict(sorted(before.items())))
    print("effective:", dict(sorted(after.items())))
    print("changed IDs:", ", ".join(changed))


if __name__ == "__main__":
    main()
