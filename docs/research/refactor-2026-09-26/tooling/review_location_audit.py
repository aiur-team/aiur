#!/usr/bin/env python3
"""Check whether raw review findings cite readable spans in the frozen snapshot."""

import argparse
import json
import re
from pathlib import Path


SPAN = re.compile(r"^(\d+)(?:-(\d+))?$")


def check_location(snapshot: Path, location: dict) -> dict:
    name = location.get("path")
    span = location.get("lines")
    result = {"path": name, "lines": span}
    if not isinstance(name, str) or not isinstance(span, str):
        return {**result, "status": "missing_path_or_span"}
    path = snapshot / name
    if not path.is_file():
        return {**result, "status": "missing_file"}
    matches = [SPAN.fullmatch(part.strip()) for part in span.split(",")]
    if not matches or any(match is None for match in matches):
        return {**result, "status": "nonstandard_span"}
    length = len(path.read_bytes().splitlines())
    for match in matches:
        start = int(match.group(1))
        end = int(match.group(2) or match.group(1))
        if start < 1 or end < start or end > length:
            return {**result, "status": "out_of_bounds", "file_lines": length}
    return {**result, "status": "exists"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--corrections", type=Path)
    args = parser.parse_args()

    corrections = {}
    if args.corrections:
        data = json.loads(args.corrections.read_text())
        for item in data["corrections"]:
            key = (item["id"], item["path"], item["old"])
            if key in corrections:
                raise SystemExit(f"duplicate correction: {key}")
            corrections[key] = item["new"]
    used_corrections = set()

    findings = []
    for path in sorted(args.raw.glob("*.json")):
        unit = json.loads(path.read_text())
        for finding in unit.get("findings", []):
            if finding.get("severity") not in {"P0", "P1"}:
                continue
            locations = []
            for item in finding.get("locations", []):
                key = (finding["id"], item.get("path"), item.get("lines"))
                if key in corrections:
                    used_corrections.add(key)
                    item = {**item, "lines": corrections[key], "original_lines": item["lines"]}
                locations.append(check_location(args.snapshot, item))
            findings.append(
                {
                    "id": finding["id"],
                    "severity": finding["severity"],
                    "locations": locations,
                    "all_locations_exist": bool(locations) and all(item["status"] == "exists" for item in locations),
                }
            )
    report = {
        "scope": "P0/P1 location existence only; no semantic or severity verdict",
        "findings": len(findings),
        "all_locations_exist": sum(item["all_locations_exist"] for item in findings),
        "corrections_applied": len(used_corrections),
        "exceptions": [item for item in findings if not item["all_locations_exist"]],
    }
    if used_corrections != corrections.keys():
        raise SystemExit(f"unused corrections: {sorted(corrections.keys() - used_corrections)}")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
