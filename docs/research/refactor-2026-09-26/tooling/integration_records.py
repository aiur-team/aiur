#!/usr/bin/env python3
"""Verify a bounded set of public integration receipts against local Git objects.

Read-only: does not fetch, checkout, merge, inspect author identities or execute
recorded commands. Paths in output are relative to the public evidence root.
"""
import argparse
import hashlib
import json
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SNAPSHOT = "3339b887196d5e9aefb273117a14bf33391ee41f"

def census(evidence, repo):
    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()
    files = sorted((evidence / "main3eb-integrations").glob("*-result.json"))
    files += sorted((evidence / "main116-integrations").glob("*-result.json"))
    files += [evidence / directory / "results.json" for directory in (
        "20260916-main-a36-integrations", "20260917-main-33fa-integrations",
        "20260917-2666-main-33fa")]
    mainline = set(git("rev-list", "--first-parent", SNAPSHOT).splitlines())
    records = []
    for path in files:
        data = json.loads(path.read_text())
        for value in data if isinstance(data, list) else [data]:
            head = value["head"]
            fields = git("show", "-s", "--format=%H%n%P%n%cI", head).splitlines()
            parents = fields[1].split()
            if len(parents) != 2:
                raise ValueError("Receipt is not a two-parent merge: " + head)
            old = value.get("old", value.get("prior_head"))
            git("merge-base", "--is-ancestor", old, head)
            if parents[1] not in mainline:
                raise ValueError("Second parent is not on frozen mainline: " + head)
            if value.get("main") and value["main"] != parents[1]:
                raise ValueError("Receipt base disagrees with Git: " + head)
            footprint = value.get("original_files", value.get("footprint"))
            if footprint is None:
                footprint = list(value.get("unchanged", {}))
            changed = [name for name in footprint
                       if git("diff", "--name-only", old, head, "--", name)]
            records.append({
                "pr": int(value["pr"]), "head": head,
                "reported_prior_head": old, "git_parents": parents,
                "prior_equals_first_parent": old == parents[0],
                "committed_at": fields[2],
                "source": str(path.relative_to(evidence)),
                "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "reported_footprint_files": len(footprint),
                "changed_within_reported_footprint": changed,
                "reported_test_result": value.get("summary", value.get(
                    "passing_tests", value.get("test"))),
                "reported_unchanged_disagreements": [
                    name for name, same in value.get("unchanged", {}).items()
                    if same != (name not in changed)
                ]
            })
    keys = [(r["pr"], r["head"]) for r in records]
    if len(set(keys)) != len(keys):
        raise ValueError("Duplicate integration receipt")
    terminal_heads = {}
    for record in records:
        pr = record["pr"]
        if pr in terminal_heads:
            git("merge-base", "--is-ancestor", terminal_heads[pr], record["head"])
        terminal_heads[pr] = record["head"]
    start = datetime.fromisoformat("2026-09-16T00:00:00+00:00")
    end = datetime.fromisoformat("2026-09-18T00:00:00+00:00")
    ancestry = {}
    for pr, head in sorted(terminal_heads.items()):
        # Do not use --since: timestamp-based traversal pruning could omit
        # older ancestry whose descendants have non-monotonic commit dates.
        for line in git("log", "--first-parent", "--merges",
                        "--format=%H %P %cI", head).splitlines():
            fields = line.split()
            if len(fields) != 4 or fields[2] not in mainline:
                continue
            stamp = datetime.fromisoformat(fields[3])
            if not start <= stamp < end:
                continue
            commit = fields[0]
            event = ancestry.setdefault(commit, {
                "head": commit, "git_parents": fields[1:3],
                "committed_at": stamp.astimezone(timezone.utc).isoformat(),
                "reachable_from_pr_receipts": []
            })
            event["reachable_from_pr_receipts"].append(pr)
    events = sorted(ancestry.values(), key=lambda item: (item["committed_at"], item["head"]))
    return {
        "ancestry_sample": {
            "selection_start_inclusive": start.isoformat(),
            "selection_end_exclusive": end.isoformat(),
            "terminal_receipt_heads": {str(pr): head for pr, head in terminal_heads.items()},
            "unique_merge_commits": len(events),
            "earliest_committed_at": events[0]["committed_at"] if events else None,
            "latest_committed_at": events[-1]["committed_at"] if events else None,
            "method": "First-parent two-parent merges in selected receipt ancestry "
                      "whose second parent is on frozen mainline; distinct commit IDs.",
            "limits": "Not all open PRs or later integrations. Reachability from a "
                      "PR receipt is not independent proof of the PR associated with "
                      "every historical commit; commit times are not measured work time.",
            "events": events
        },
        "claim": "meta-10", "status": "bounded_verified_sample",
        "snapshot": SNAPSHOT,
        "method": "Explicit receipt sets, deduplicated by PR and resulting commit; "
                  "Git parent, prior ancestry and frozen-mainline membership checks.",
        "record_count": len(records),
        "unique_prs": sorted({r["pr"] for r in records}),
        "by_base": dict(sorted(Counter(r["git_parents"][1] for r in records).items())),
        "prior_parent_mismatches": sum(not r["prior_equals_first_parent"] for r in records),
        "records": records,
        "limits": [
            "Selected receipt sets are not a complete census of the claimed 27-hour window.",
            "Git confirms merge structure, not operator identity, conflict incidence, "
            "necessity of each integration, elapsed effort or causality of the merge gap.",
            "Test results are historical receipt claims, not rerun or independently "
            "verified by this tool; test counts are not fresh mutation-proof counts.",
            "Footprint lists are receipt-supplied; checking them does not establish "
            "completeness of each PR footprint or behavioral equivalence.",
            "No inference from missing receipts to missing events; no claimed savings."
        ]
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = census(args.evidence, args.repo)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in (
        "record_count", "unique_prs", "by_base", "prior_parent_mismatches")}))
