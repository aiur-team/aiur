#!/usr/bin/env python3
"""Reconcile the oversized-file audit partitions with the frozen owner map."""

import argparse
import csv
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYNTHESIS = ROOT / "synthesis"
PARTS = (
    "oversized-file-owner-map-audit-part-1.json",
    "oversized-owner-audit-part-2.json",
    "oversized-file-owner-map-audit-part-3.json",
)


def physical_lines(path):
    return len(path.read_text(encoding="utf-8").splitlines())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--partial", action="store_true")
    args = parser.parse_args()
    with (SYNTHESIS / "oversized-file-owner-map.csv").open(newline="", encoding="utf-8") as stream:
        owner_rows = list(csv.DictReader(stream))
    assert len(owner_rows) == 359
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.candidate).decode().strip() == (
        "7bce08f36aede1f9747d24bb3a5c08145abd081e"
    ), "release candidate changed; refresh audit first"

    reviewed = {}
    for name in PARTS:
        path = SYNTHESIS / name
        if not path.exists():
            assert args.partial, f"missing partition: {path}"
            continue
        rows = json.loads(path.read_text(encoding="utf-8"))["rows"]
        for row in rows:
            index = row.get("row_index", row.get("index"))
            assert index not in reviewed and 0 <= index < len(owner_rows), (name, index)
            original = owner_rows[index]
            assert row["path"] == original["path"], (name, index)
            assert int(row["frozen_lines"]) == int(original["frozen_lines"]), (name, index)
            candidate_lines = row.get("candidate_lines", row.get("release_candidate_lines"))
            candidate_file = args.candidate / row["path"]
            actual = physical_lines(candidate_file) if candidate_file.is_file() else None
            assert candidate_lines == actual, (name, index, candidate_lines, actual)
            if "exists_in_candidate" in row:
                assert row["exists_in_candidate"] == (actual is not None), (name, index)
            reviewed[index] = row

    expected = set(range(359))
    missing = sorted(expected - reviewed.keys())
    assert args.partial or not missing, f"unreviewed owner-map rows: {missing}"
    print(f"owner-map rows reconciled: {len(reviewed)}/359")
    print(f"missing paths: {sum(row.get('candidate_lines', row.get('release_candidate_lines')) is None for row in reviewed.values())}")
    if missing:
        print(f"unreviewed row indexes: {missing[0]}–{missing[-1]} ({len(missing)} rows)")


if __name__ == "__main__":
    main()
