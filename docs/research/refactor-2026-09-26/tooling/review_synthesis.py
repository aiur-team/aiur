#!/usr/bin/env python3
"""Reconcile reviewed raw findings without discarding any source claim."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

SNAPSHOT = "3339b887196d5e9aefb273117a14bf33391ee41f"
SEVERITY = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}

# Each group is one work item, not an assertion that every sentence is identical.
# The raw claims remain embedded verbatim in findings.json.
MERGES = [
    ("orch-a-14", ["agent-runtime-22", "loose-3-38", "dup-by-concept-02", "dup-by-name-03"],
     "One ticket-topic construction/parsing grammar; the PR adapter is a checked subset. Preserve adapter admission and identifier policy."),
    ("web-occ-01", ["web-rest-05", "loose-2-17", "orch-b-36", "platform-misc-12", "loose-1-26"],
     "One core-to-web dependency inversion; SnapshotStore is an instance of the broader cross-layer dependency."),
    ("github-a-24", ["github-b-29", "loose-1-35"], "Same hard-coded GitHub API base URL population and owner."),
    ("loose-1-16", ["loose-2-11", "loose-3-13"],
     "Same decision text/control-character validation family; retain identity, prose, attention-slug and JWT policies by field."),
    ("agent-backends-oc-31", ["loose-3-28", "dup-by-body-07"],
     "Same AIUR_DEBUG parser copies are a checked subset of the broader environment/config parsing finding."),
    ("loose-1-34", ["dup-by-body-34"], "Same GitHub-cost and units CLI table mechanics; retain caller-specific minimum widths."),
    ("web-rest-14", ["loose-1-28"], "Same synchronous analytics RTK path; retain the separate full-telemetry loading claim."),
    ("github-a-09", ["dup-by-body-19"], "Same CI/comment branch preparation; retain overflow and payload divergence in the broader finding."),
    ("orch-b-24", ["dup-by-body-26"], "Same two PR maintenance workers and review-fetch adapter, including conditional-304 caveat."),
    ("web-rest-10", ["dup-by-body-21"], "Financial access gate and subscription are verified subsets of the broader repeated usage pipeline."),
    ("github-b-05", ["dup-by-body-42", "dup-by-body-49"],
     "Request attribution and cost classification are subsets of the five-owner GitHub request-classification drift."),
    ("telemetry-usage-34", ["dup-by-constant-01"],
     "Ordered five-dimension vocabulary is one checked subset of the inherited usage-helper finding."),
    ("agent-runtime-09", ["dup-by-constant-04"],
     "Two active-turn code matches are one checked subset of the inherited backend-contract leak."),
    ("platform-misc-10", ["orch-a-13", "orch-b-29", "agent-runtime-23", "dup-by-concept-01"],
     "Tracker state and label normalization drift; preserve separate write-authority and UI-state policies."),
    ("build-order-12", ["loose-4-19"],
     "Same event-sourced labelled issue overlays and diverged pagination; retain blocking-I/O and boot-failure subclaims."),
    ("loose-4-05", ["loose-1-30"],
     "Same non-executor wake loss on inbox enqueue failure; the blocking acknowledgement path is one trigger."),
    ("agent-runtime-06", ["loose-1-22"],
     "Same unreachable tmux-event subscription and pane-death path; preserve actual list-panes fallback."),
    ("orch-a-10", ["loose-3-17"],
     "Same unbounded AgentQueueStore history and per-enqueue scan; retain additional internal-API observation."),
    ("tests-5-01", ["agent-runtime-30"],
     "Same fabricated OS PID reaches a real process tree and ownership lease in the containment test."),
    ("tests-5-09", ["tests-2-23", "tests-1c-14", "tests-6-14"],
     "Same hand-rolled System/Application environment restoration helpers and conflicting restore_env meaning."),
    ("web-rest-02", ["web-occ-25"],
     "Same synchronous ControlCenterCache loader and unbounded caller wait; preserve supervisor and exception consequences."),
    ("tests-1c-01", ["tests-6-19"],
     "Same default Linear fixture and immediately polling named Orchestrator; preserve presenter-test cleanup subclaim."),
    ("loose-4-12", ["web-occ-19"],
     "Same inconsistent complexity-label parsing; retain Build Order lane parsing as a related subclaim."),
    ("web-rest-03", ["web-occ-26"],
     "Same partial durable-window percent parser in two renderers; retain source writer's nil-field path."),
    ("tests-6-03", ["tests-1c-22"],
     "Same temporary globally named PubSub test ownership and later unavailability."),
    ("platform-misc-15", ["loose-3-14", "loose-1-17"],
     "Same atom-or-string map lookup copies with present-false versus truthy fallback semantics."),
    ("github-a-20", ["web-rest-13"],
     "Same /github-cache reload of store and budget projections on every resource-change event."),
    ("tests-6-16", ["tests-5-25"],
     "Same TrackerIdentity test-fixture family; preserve additional git-helper subclaim."),
    ("agent-backends-oc-16", ["agent-runtime-10"],
     "Same pause/queue control-message variants across backend and runner receive loops."),
    ("loose-2-12", ["agent-backends-cc-32"],
     "Same private shell-quote implementations despite Aiur.Shell; retain the one malformed quote variant."),
]

# Related work shares a boundary but has a distinct failure mode or policy.
RELATED = [
    ("platform-misc-10", "github-b-12"),
    ("platform-misc-10", "agent-backends-cc-38"),
    ("web-rest-10", "web-rest-11"),
    ("github-b-05", "github-b-12"),
]


def raw_findings(root):
    found = {}
    for path in sorted((root / "review/raw").glob("*.json")):
        data = json.loads(path.read_text())
        if data.get("snapshot") not in (None, SNAPSHOT):
            raise ValueError(f"Unexpected snapshot in {path}")
        for row in data["findings"]:
            key = row["id"]
            if key in found:
                raise ValueError(f"Duplicate source ID {key}")
            found[key] = (path.relative_to(root).as_posix(), row)
    return found


def reviews(root, raw):
    folder = root / "review/verdicts"
    a = {r["id"]: r for r in json.loads((folder / "independent_a.json").read_text())["verdicts"]}
    b = {r["id"]: r for r in json.loads((folder / "independent_b.json").read_text())["verdicts"]}
    decisions = {r["source_id"]: r for r in json.loads((folder / "severity-reconciliation-draft.json").read_text())["disagreements"]}
    high = {i for i, (_, f) in raw.items() if f["severity"] in ("P0", "P1")}
    if set(a) != high or set(b) != high:
        raise ValueError("Independent review source-ID coverage differs from raw high-priority IDs")
    conflicts = {i for i in high if a[i]["reviewed_severity"] != b[i]["severity"]}
    if set(decisions) != conflicts:
        raise ValueError("Severity reconciliation does not cover exactly the disagreements")
    result = {}
    for key in raw:
        if key not in high:
            result[key] = {"status": "raw_provisional_unverified", "severity": raw[key][1]["severity"]}
            continue
        if not b[key]["holds"] or a[key]["verdict"] not in ("supported_static", "qualified_static"):
            raise ValueError(f"Unsupported high-priority claim requires separate disposition: {key}")
        severity = decisions[key]["decision_severity"] if key in decisions else a[key]["reviewed_severity"]
        result[key] = {"status": "two_independent_static_reviews", "severity": severity,
                       "reviewer_a_verdict": a[key]["verdict"], "reviewer_a_severity": a[key]["reviewed_severity"],
                       "reviewer_b_holds": b[key]["holds"], "reviewer_b_severity": b[key]["severity"],
                       "reconciliation_reason": decisions[key]["decision_reason"] if key in decisions else None,
                       "limits": "Frozen-source checks; live incidence and post-snapshot fixes not established."}
    return result


def boundary_for(path, source, rules):
    if path.startswith("packages/streamdeck/"):
        return "SD"
    if path.startswith("analytics/"):
        return "ANL"
    if path.startswith(".claude/") or path.startswith(".codex/"):
        return "SKILL"
    if path.startswith("website/"):
        return "SITE"
    if path.startswith("packaging/") or path.startswith("scripts/"):
        return "CLI"
    if path.startswith(".github/"):
        return "DEV"
    if path.startswith("src/test/support/"):
        return "DEV"
    candidate = source / path
    module = None
    if candidate.is_file() and candidate.suffix in (".ex", ".exs"):
        match = re.search(r"\bdefmodule\s+([A-Za-z0-9_.]+)", candidate.read_text(errors="replace")[:20000])
        if match:
            module = match.group(1)
            if path.startswith("src/test/"):
                module = re.sub(r"Test$", "", module)
    if module:
        for code, pattern in rules:
            if re.search(pattern, module):
                return code
    if path.startswith("src/test/"):
        return "DEV"
    if path.startswith("src/lib/aiur_web/"):
        return "WEB"
    if path.startswith("src/lib/aiur/"):
        return "K"
    if path.startswith("src/"):
        return "DEV"
    return "OTHER"


def synthesize(root, source):
    raw = raw_findings(root)
    verdict = reviews(root, raw)
    boundaries = json.loads((root / "tooling/boundary-map.json").read_text())
    names = dict(boundaries["names"], ANL="Offline analytics tooling", SKILL="Agent skills and prompts", SITE="Website and docs", OTHER="Other tracked source")
    groups = {}
    owner = {}
    for primary, siblings, reason in MERGES:
        ids = [primary, *siblings]
        if any(i not in raw for i in ids):
            raise ValueError(f"Missing merge source: {ids}")
        if any(i in owner for i in ids):
            raise ValueError(f"Source merged twice: {ids}")
        groups[primary] = {"source_ids": ids, "reason": reason}
        owner.update({i: primary for i in ids})
    for key in raw:
        if key not in owner:
            owner[key] = key
            groups[key] = {"source_ids": [key], "reason": None}
    related = defaultdict(set)
    for left, right in RELATED:
        if left not in owner or right not in owner:
            raise ValueError("Unknown related ID")
        if owner[left] != owner[right]:
            related[owner[left]].add(owner[right])
            related[owner[right]].add(owner[left])
    findings = []
    for primary, group in groups.items():
        ids = group["source_ids"]
        source_claims = []
        boundary_codes = []
        for key in ids:
            source_file, claim = raw[key]
            source_claims.append({"source_file": source_file, "claim": claim, "verification": verdict[key]})
            for location in claim["locations"]:
                code = boundary_for(location["path"], source, boundaries["rules"])
                if code not in boundary_codes:
                    boundary_codes.append(code)
        primary_claim = raw[primary][1]
        reviewed = min((verdict[i]["severity"] for i in ids), key=SEVERITY.__getitem__)
        findings.append({"id": primary, "source_ids": ids, "reviewed_severity": reviewed,
                         "category": primary_claim["category"], "title": primary_claim["title"],
                         "description": primary_claim["description"], "recommendation": primary_claim["recommendation"],
                         "boundary_codes": boundary_codes, "primary_boundary": boundary_codes[0] if boundary_codes else "OTHER",
                         "related_finding_ids": sorted(related[primary]), "merge_reason": group["reason"],
                         "source_claims": source_claims})
    findings.sort(key=lambda f: (SEVERITY[f["reviewed_severity"]], f["id"]))
    if set(owner) != set(raw) or sum(len(f["source_ids"]) for f in findings) != len(raw):
        raise ValueError("Source-ID coverage is incomplete")
    by_boundary = defaultdict(list)
    for finding in findings:
        for code in finding["boundary_codes"]:
            by_boundary[code].append(finding["id"])
    return {
        "snapshot": SNAPSHOT,
        "status": "static_research_synthesis_pending_critic_and_runtime_validation",
        "method": "Manual semantic merges in tooling/review_synthesis.py. All raw claims are embedded unchanged; source-ID coverage is exact. Unmerged claims are separate work items, not proof of semantic uniqueness. Boundary assignment uses source module names and a checked rule map; multi-boundary counts are nonadditive.",
        "counts": {"raw_source_ids": len(raw), "canonical_findings": len(findings),
                   "merged_groups": sum(len(f["source_ids"]) > 1 for f in findings),
                   "source_ids_in_merged_groups": sum(len(f["source_ids"]) for f in findings if len(f["source_ids"]) > 1),
                   "reviewed_severity": dict(sorted(Counter(f["reviewed_severity"] for f in findings).items())),
                   "source_verification": dict(sorted(Counter(v["status"] for v in verdict.values()).items()))},
        "boundary_names": names,
        "boundary_finding_ids": dict(sorted(by_boundary.items())),
        "source_id_to_finding": dict(sorted(owner.items())),
        "merge_decisions": [{"canonical_id": p, **g} for p, g in groups.items() if len(g["source_ids"]) > 1],
        "findings": findings,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    print(json.dumps(synthesize(args.root, args.snapshot), separators=(",", ":"), ensure_ascii=False))
