#!/usr/bin/env python3
"""List P2/P3 findings with cited paths changed between two public commits."""

import argparse
import csv
import json
import re
import subprocess
from collections import Counter
from pathlib import Path

from audit_p2p3_reconciled import PART2_AND_3


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
FIELDS = (
    "finding_id", "severity", "effective_action", "changed_cited_paths",
    "path_statuses", "has_deleted_cited_path",
)


def load_actions():
    review = ROOT / "review"
    part1 = json.loads((review / "p2p3-triage-part-1.json").read_text())["items"]
    part2 = json.loads((review / "p2p3-triage-part-2.json").read_text())
    part3 = json.loads((review / "p2p3-triage-part-3.json").read_text())["entries"]
    actions = {row["finding_id"]: row["proposed_action"] for row in part1}
    actions.update({row["id"]: row["proposed_disposition"] for row in part2})
    actions.update({row["id"]: row["disposition"] for row in part3})

    part1_overlay = json.loads((ROOT / "synthesis/p2p3-part-1-reconciliation.json").read_text())
    for ident, row in part1_overlay["entries"].items():
        actions[ident] = row["reconciled"]["action"]

    overlay = (ROOT / "synthesis/p2p3-triage-reconciliation-overlay.md").read_text()
    overlay_rows = re.findall(r"^\| `([^`]+)` \| ([^\n]+) \| ([^\n]+) \|$", overlay, re.M)
    assert len(overlay_rows) == 9
    assert {ident for ident, _, _ in overlay_rows} == PART2_AND_3
    for ident, decision, _gate in overlay_rows:
        assert "source-supported / fix" in decision, ident
        actions[ident] = "fix"
    assert len(actions) == 889
    return actions


def changed_paths(base, head):
    raw = subprocess.check_output(
        ["git", "-C", str(REPO), "diff", "--name-status", "--no-renames", "-z", base, head]
    )
    fields = raw.decode().rstrip("\0").split("\0") if raw else []
    assert len(fields) % 2 == 0
    return {fields[i + 1]: fields[i] for i in range(0, len(fields), 2)}


def rows_for(changes, actions):
    findings = json.loads((ROOT / "review/findings.json").read_text())["findings"]
    rows = []
    for finding in findings:
        if finding["reviewed_severity"] not in ("P2", "P3"):
            continue
        paths = {
            location["path"]
            for claim in finding["source_claims"]
            for location in claim["claim"].get("locations", [])
        }
        hit = sorted(path for path in paths if path in changes)
        if hit:
            rows.append({
                "finding_id": finding["id"],
                "severity": finding["reviewed_severity"],
                "effective_action": actions[finding["id"]],
                "changed_cited_paths": ";".join(hit),
                "path_statuses": ";".join(changes[path] for path in hit),
                "has_deleted_cited_path": str(any(changes[path] == "D" for path in hit)).lower(),
            })
    return sorted(rows, key=lambda row: row["finding_id"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    changes = changed_paths(args.base, args.head)
    rows = rows_for(changes, load_actions())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"changed paths: {len(changes)}")
    print(f"affected P2/P3 findings: {len(rows)}")
    print(f"by action: {dict(Counter(row['effective_action'] for row in rows))}")
    print(f"with deleted cited path: {sum(row['has_deleted_cited_path'] == 'true' for row in rows)}")


if __name__ == "__main__":
    main()
