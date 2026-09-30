#!/usr/bin/env python3
"""Compare every review citation with two pinned Git trees, without runtime claims."""

import argparse
import json
import re
import subprocess
from collections import Counter
from pathlib import Path


RANGES = re.compile(r"\s*\d+(?:-\d+)?(?:\s*,\s*\d+(?:-\d+)?)*\s*")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args])


def tree(revision: str) -> dict[str, tuple[str, str]]:
    result = {}
    for item in git("ls-tree", "-r", "-z", revision).split(b"\0"):
        if not item:
            continue
        header, path = item.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        result[path.decode("utf-8", "surrogateescape")] = (mode, oid)
    return result


def lines(oid: str, cache: dict[str, list[bytes]]) -> list[bytes]:
    if oid not in cache:
        content = git("cat-file", "blob", oid)
        cache[oid] = content.split(b"\n") if content else []
        if content.endswith(b"\n"):
            cache[oid].pop()
    return cache[oid]


def spans(spec: str) -> list[tuple[int, int]] | None:
    if not RANGES.fullmatch(spec):
        return None
    result = []
    for item in spec.split(","):
        bounds = [int(value) for value in item.strip().split("-")]
        result.append((bounds[0], bounds[-1]))
    return result


def location_status(location: dict, base: dict, head: dict, cache: dict) -> tuple[str, str]:
    path, spec = location["path"], str(location["lines"])
    if path not in base:
        return "unknown", "not_tracked_at_frozen_revision"
    if path not in head:
        return "stale", "path_absent_at_head"
    base_mode, base_oid = base[path]
    head_mode, head_oid = head[path]
    if base_mode != "100644" and base_mode != "100755":
        return "unknown", "non_regular_frozen_path"
    if head_mode != "100644" and head_mode != "100755":
        return "stale", "no_longer_regular_at_head"
    ranges = spans(spec)
    if ranges is None:
        return "unknown", "freeform_line_reference"
    base_lines = lines(base_oid, cache)
    head_lines = lines(head_oid, cache)
    if any(start < 1 or end < start or end > len(base_lines) for start, end in ranges):
        return "unknown", "frozen_line_range_out_of_bounds"
    if any(end > len(head_lines) for _, end in ranges):
        return "stale", "line_range_absent_at_head"
    if all(base_lines[start - 1 : end] == head_lines[start - 1 : end] for start, end in ranges):
        return "current", "cited_lines_identical"
    return "unknown", "cited_lines_changed_or_moved"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--findings", type=Path, required=True)
    parser.add_argument("--base", required=True, help="full frozen source commit")
    parser.add_argument("--head", required=True, help="full current-main commit")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--corrections", type=Path, help="reviewed anchor corrections, preserving raw citations")
    args = parser.parse_args()
    findings = json.loads(args.findings.read_text())
    if findings["snapshot"] != args.base:
        parser.error("findings snapshot does not match --base")
    base, head, cache = tree(args.base), tree(args.head), {}
    corrections = {}
    if args.corrections:
        correction_file = json.loads(args.corrections.read_text())
        if correction_file["base_revision"] != args.base:
            parser.error("correction ledger does not match --base")
        for correction in correction_file["corrections"]:
            key = (correction["source_id"], correction["original_path"], correction["original_lines"])
            if key in corrections:
                raise SystemExit(f"duplicate correction for {key}")
            corrections[key] = correction
    used_corrections = set()
    rows = []
    location_statuses, location_reasons = Counter(), Counter()
    for finding in findings["findings"]:
        source_rows = []
        for source in finding["source_claims"]:
            locations = []
            for location in source["claim"]["locations"]:
                status, reason = location_status(location, base, head, cache)
                entry = {"path": location["path"], "lines": location["lines"],
                         "status": status, "reason": reason}
                key = (source["claim"]["id"], location["path"], location["lines"])
                if key in corrections:
                    if status != "unknown":
                        raise SystemExit(f"correction does not target an unknown citation: {key}")
                    correction = corrections[key]
                    corrected = {"path": correction["corrected_path"], "lines": correction["corrected_lines"]}
                    checked, _ = location_status(corrected, base, head, cache)
                    if checked != "current":
                        raise SystemExit(f"corrected citation is not current: {key}")
                    ranges = spans(corrected["lines"])
                    oid = head[corrected["path"]][1]
                    cited = b"\n".join(b"\n".join(lines(oid, cache)[start - 1 : end]) for start, end in ranges)
                    if correction["needle"].encode() not in cited:
                        raise SystemExit(f"uncorroborated correction: {key}")
                    entry["corrected_anchor"] = {**corrected, "status": "verified_at_head",
                                                 "needle": correction["needle"], "note": correction["note"]}
                    used_corrections.add(key)
                locations.append(entry)
                location_statuses[status] += 1
                location_reasons[reason] += 1
            statuses = {item["status"] for item in locations}
            source_status = "stale" if "stale" in statuses else "unknown" if "unknown" in statuses else "current"
            source_rows.append({"source_id": source["claim"]["id"],
                                "status": source_status, "location_count": len(locations),
                                "exceptions": [item for item in locations if item["status"] != "current"]})
        statuses = {item["status"] for item in source_rows}
        status = "stale" if "stale" in statuses else "unknown" if "unknown" in statuses else "current"
        rows.append({"finding_id": finding["id"], "reviewed_severity": finding["reviewed_severity"],
                     "source_ids": finding["source_ids"], "source_status": status,
                     "runtime_incidence": "unverified", "source_claims": source_rows})
    source_ids = [source["source_id"] for row in rows for source in row["source_claims"]]
    if len(rows) != findings["counts"]["canonical_findings"] or len(source_ids) != findings["counts"]["raw_source_ids"] or len(source_ids) != len(set(source_ids)):
        raise SystemExit("finding/source-ID coverage mismatch")
    if used_corrections != corrections.keys():
        raise SystemExit("a correction does not match a source citation")
    unknown_findings = [{"finding_id": row["finding_id"], "reviewed_severity": row["reviewed_severity"],
                         "source_ids": row["source_ids"],
                         "citation_defects": [{"source_id": source["source_id"], **exception}
                                              for source in row["source_claims"] for exception in source["exceptions"]]}
                        for row in rows if row["source_status"] == "unknown"]
    summary = {
        "finding_status": dict(Counter(row["source_status"] for row in rows)),
        "source_id_status": dict(Counter(source["status"] for row in rows for source in row["source_claims"])),
        "location_status": dict(location_statuses),
        "location_reasons": dict(location_reasons),
        "finding_by_severity": {severity: dict(Counter(row["source_status"] for row in rows if row["reviewed_severity"] == severity)) for severity in ("P0", "P1", "P2", "P3")},
        "corrected_unknown_locations": len(used_corrections),
        "unknown_locations_needing_anchor": location_statuses["unknown"] - len(used_corrections),
    }
    report = {"method": "Pinned Git blob and cited-line equality only; unchanged source is not runtime reproduction or finding confirmation.",
              "base_revision": args.base, "head_revision": args.head,
              "base_head_same_tree": git("rev-parse", f"{args.base}^{{tree}}").strip() == git("rev-parse", f"{args.head}^{{tree}}").strip(),
              "summary": summary, "unknown_findings": unknown_findings, "findings": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
