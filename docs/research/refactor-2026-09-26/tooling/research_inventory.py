#!/usr/bin/env python3
"""Count research artifacts by identity, without treating presence as validation."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

REPORTS = ("census", "meta", "gaps", "fixes", "agents", "codebase")
UNITS = (
    "orch-a orch-b github-a github-b build-order web-occ web-rest "
    "agent-backends-oc events-webhooks-executor agent-backends-cc agent-runtime "
    "telemetry-usage platform-misc loose-1 loose-2 loose-3 loose-4 "
    "tests-1a tests-1b tests-1c tests-2 tests-3 tests-4 tests-5 tests-6 "
    "nonelixir-web nonelixir-shell skills-prompts "
    "dup-by-name dup-by-body dup-by-concept dup-by-constant"
).split()


def rows(directory, key):
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text())
        for row in data if isinstance(data, list) else data[key]:
            yield path.name, row


def inventory(root):
    expected = {f"{report}-{n:02}" for report in REPORTS for n in range(1, 11)}
    coverage = defaultdict(set)
    verdict_count = 0
    for name, verdict in rows(root / "synthesis/verdicts", "verdicts"):
        claim = verdict["id"]
        if claim not in expected:
            raise ValueError(f"Unexpected claim {claim} in {name}")
        verdict_count += 1
        if verdict.get("lens") in ("reproduce", "interpret"):
            lenses = {verdict["lens"]}
        elif all(isinstance(verdict.get(k), bool) for k in ("reproduce_holds", "interpret_holds")):
            lenses = {"reproduce", "interpret"}
        else:
            raise ValueError(f"Unknown lens for {claim} in {name}")
        if coverage[claim] & lenses:
            raise ValueError(f"Duplicate lens for {claim}; reconcile supersession explicitly")
        coverage[claim].update(lenses)
    missing = [{"id": claim, "missing_lenses": sorted({"reproduce", "interpret"} - coverage[claim])}
               for claim in sorted(expected) if len(coverage[claim]) != 2]
    findings = [row for _, row in rows(root / "review/raw", "findings")]
    features = [row for _, row in rows(root / "features/raw", "features")]
    challenges = [row for _, row in rows(root / "features/challenges", "verdicts")]
    for label, values in (("finding", findings), ("feature", features), ("challenge", challenges)):
        if len(values) != len({r["id"] for r in values}):
            raise ValueError(f"Duplicate {label} IDs")
    feature_ids = {x["id"] for x in features}
    if {x["id"] for x in challenges} - feature_ids:
        raise ValueError("Challenge without a feature")
    candidates = {x["id"] for x in features if x["recommendation"] in ("cut", "merge", "externalize")}
    challenged = {x["id"] for x in challenges}
    present = {p.stem for p in (root / "review/raw").glob("*.json")}
    high = {x["id"] for x in findings if x["severity"] in ("P0", "P1")}
    reviewer_checks = defaultdict(set)
    for path in sorted((root / "review/verdicts").glob("*.json")):
        data = json.loads(path.read_text())
        reviewer = data.get("reviewer", path.stem)
        for row in data["verdicts"]:
            if row.get("verdict") == "pending":
                continue
            if row["id"] in reviewer_checks[reviewer]:
                raise ValueError(f"Duplicate review of {row['id']} by {reviewer}")
            reviewer_checks[reviewer].add(row["id"])
    checked_twice = {finding for finding in high if sum(finding in ids for ids in reviewer_checks.values()) >= 2}
    return {
        "note": "Artifact coverage only. Verdict presence does not prove correctness or research completion.",
        "claims": {"expected": len(expected), "verdict_records": verdict_count,
                   "both_lenses_present": len(expected) - len(missing), "remaining": missing},
        "review": {"expected_units": len(UNITS), "present_units": sorted(present),
                   "missing_units": sorted(set(UNITS) - present), "findings": len(findings),
                   "original_severity_counts": dict(sorted(Counter(x["severity"] for x in findings).items())),
                   "independent_reviewer_counts": {name: len(ids & high) for name, ids in sorted(reviewer_checks.items())},
                   "high_priority_verdicts_missing": sorted(high - checked_twice)},
        "features": {"count": len(features), "by_surface": dict(sorted(Counter(x["id"].rsplit("-", 1)[0] for x in features).items())),
                     "cut_merge_externalize": len(candidates), "challenges_present": len(challenges),
                     "remaining_challenges": sorted(candidates - challenged)},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(inventory(args.root), indent=2))
