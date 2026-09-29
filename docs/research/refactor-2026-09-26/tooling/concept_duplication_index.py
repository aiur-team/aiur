#!/usr/bin/env python3
"""Inventory inherited duplication findings by review unit without verdicts."""

import json
import sys
from pathlib import Path


def build(root: Path) -> dict:
    units = []
    ids = set()
    for path in sorted((root / "review/raw").glob("*.json")):
        data = json.loads(path.read_text())
        findings = [finding for finding in data.get("findings", []) if finding.get("category") == "duplication"]
        unit_ids = []
        for finding in findings:
            fid = finding["id"]
            if fid in ids:
                raise ValueError(f"duplicate finding ID: {fid}")
            ids.add(fid)
            unit_ids.append(fid)
        units.append({"unit_id": data.get("unit_id", path.stem), "finding_ids": unit_ids})
    return {
        "status": "index-only",
        "raw_units": len(units),
        "duplication_findings": len(ids),
        "units": units,
        "limits": "Counts only findings explicitly categorized duplication in raw review files. It does not detect additional concepts, verify source assertions, deduplicate overlapping IDs, assess severity, or imply removable LOC.",
    }


if __name__ == "__main__":
    print(json.dumps(build(Path(sys.argv[1])), indent=2))
