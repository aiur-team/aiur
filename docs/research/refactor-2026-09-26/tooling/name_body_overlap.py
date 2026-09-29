#!/usr/bin/env python3
"""Link name-screen candidates to body findings by source-span overlap only."""

import json
import re
import sys
from pathlib import Path


def span(text):
    values = [int(value) for value in re.findall(r"\d+", text)]
    return min(values), max(values)


def build(root: Path) -> dict:
    progress = root / "review/in-progress"
    name_families = []
    for suffix in ("a", "b"):
        data = json.loads((progress / f"duplication-name-tail-{suffix}.json").read_text())
        name_families += [
            family for family in data["families"]
            if family["semantic_disposition"] in
            ("shared_policy_candidate", "plausible_shared_policy")
        ]
    body = json.loads((root / "review/raw/dup-by-body.json").read_text())
    rows = []
    for family in name_families:
        sites = family.get("sites") or [
            {"path": item["path"], "line": item["line"], "end_line": item["line"]}
            for item in family["evidence"]
        ]
        overlaps = set()
        for finding in body["findings"]:
            for location in finding["locations"]:
                low, high = span(location["lines"])
                if any(site["path"] == location["path"] and site["line"] <= high
                       and site.get("end_line", site["line"]) >= low for site in sites):
                    overlaps.add(finding["id"])
        rows.append({"index": family["index"], "name": family["name"],
                     "body_overlap_ids": sorted(overlaps)})
    return {
        "status": "span-index-only",
        "snapshot": "3339b887196d5e9aefb273117a14bf33391ee41f",
        "candidate_families": len(rows),
        "families_with_body_overlap": sum(bool(row["body_overlap_ids"]) for row in rows),
        "rows": rows,
        "limits": "Closed line-span overlap is navigation evidence. It does not prove semantic duplication, validate either finding, or cover different-name concepts. Broad raw finding ranges can overmatch and omitted locations can undermatch.",
    }


if __name__ == "__main__":
    data = build(Path(sys.argv[1]))
    rows = data.pop("rows")
    print("{")
    for key, value in data.items():
        print(f"  {json.dumps(key)}: {json.dumps(value)},")
    print('  "rows": [')
    for index, row in enumerate(rows):
        suffix = "," if index < len(rows) - 1 else ""
        print("    " + json.dumps(row, separators=(",", ":")) + suffix)
    print("  ]\n}")
