#!/usr/bin/env python3
"""Build and validate the canonical P0/P1 planning disposition at release main."""

import argparse
import json
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE = "fc8270bb6d30cf44a860b142b365ad10e5c906a1"

# A disposition is a proposed next action, not an observed production defect.
# Keep means preserve an intentional contract. Defer means do not approve a
# code change until the named behavior, incidence, or owner decision is known.
KEEP = {
    "build-order-02": "Keep the explicit 16 KiB fail-closed ticket-detail contract; decide with the Build Order owner whether an explicitly incomplete preview is useful. Never silently truncate instructions.",
}
DEFER = {
    "agent-backends-cc-01": "Measure process-spawn count and notification latency on a representative Codex session before changing metadata discovery.",
    "agent-backends-cc-04": "Name divergent behavior and a shared contract before extracting Claude/Codex JSON-RPC plumbing; verify both backends independently.",
    "agent-backends-oc-10": "Measure ledger population, fsync latency and retained replay needs before choosing a bound or batching policy.",
    "github-b-04": "Measure request latency and actual filesystem work before splitting Quota's serialized path; preserve governor ordering.",
    "loose-2-05": "Measure journal size and lookup latency; choose a durable dedupe horizon before compaction.",
    "loose-3-02": "Measure time near the alert-ledger cap and append latency before adding compaction hysteresis.",
    "nonelixir-shell-08": "Decide the canonical project-root/config search contract, then reproduce from a subdirectory before changing either implementation.",
    "orch-a-10": "Count retained queue items and enqueue time; define replay/tombstone authority before eviction.",
    "platform-misc-04": "Measure host sync duration and lease-transition frequency before changing durability ordering.",
    "platform-misc-05": "Measure lock wait and hook duration; define cross-node ownership before replacing the global lock.",
    "web-occ-06": "Audit each rescue/catch branch against an injected failure and expected user outcome; the aggregate lexical count is not a fix contract.",
    "web-rest-08": "The GitHub-cache page was removed, but surviving handlers still need branch-by-branch failure and logging review.",
}
ADDRESSED = {
    "agent-backends-oc-01": ("#2827", "Bearer authorization moved ahead of marker/replay/nudge/operator dispatch; re-run merged-main unauthorized coalesced-message regression and mutation proof."),
    "agent-backends-oc-02": ("#2845", "OpenAI-compatible command sandbox no longer inherits raw GitHub token names; re-run synthetic-token argv/environment regression and mutation proof."),
    "nonelixir-shell-01": ("#2846", "Stop selects only the current instance agent pidfile; re-run two-instance signal-free selection regression and real instance isolation."),
    "nonelixir-shell-03": ("#2858", "Packaged tmux pane-control helper and binding repair replace the diverged shipped config; verify installed package keypress and pane preservation."),
}
SPECIFIC_GATES = {
    "agent-runtime-01": "Confirm all three pause paths, including both between-turn receives, before treating containment as complete.",
    "agent-runtime-02": "Inject failing queue RPCs into each :ok match and assert a bounded, visible recovery.",
    "agent-runtime-04": "Reject restore/mark-failed after a claimed message and verify the failed delivery cannot be consumed as delivered.",
    "agent-runtime-07": "Confirm the global q UX contract in the real foreground TUI; align help text with that behavior.",
    "agent-runtime-08": "Refuse enqueue and fail one provider; verify incomplete context is visible and replay is deduplicated.",
    "build-order-04": "Reconcile a root with over 100 sub-issues and verify existing edges survive pagination.",
    "events-webhooks-executor-05": "Publish a webhook review comment with a nontrivial decision; verify the rework gate matches polling.",
    "github-a-01": "Fail team resolution and inspect the resulting trust snapshot and dispatch decision; decide a safe fail-closed alert policy.",
    "github-a-02": "Timeout CodeOwners during active work and verify no incorrect untrusted transition or silent starvation.",
    "github-a-04": "Supply over 100 comments and verify the newest review conversation reaches the agent.",
    "github-b-03": "Inject ambiguous reply mutation outcome and prove one remote reply after retry.",
    "loose-2-02": "Delay a status provider and measure the real launcher command; choose a total deadline with explicit unavailable fields.",
    "loose-3-05": "Prove macOS agent-reap identity with a published darwin-arm64 binary before changing process selection.",
    "loose-4-04": "Test corrupt complete and torn trailing wake records separately; decide journal authority before repair.",
    "orch-b-01": "Compare live and projected status with non-default values for each omitted State field.",
    "orch-b-02": "Force a parked fallback without Task pid through terminate/deactivate and assert no Orchestrator crash or accounting loss.",
    "orch-b-14": "Drive an alerted human wait through unavailable count; assert no false resolved alert.",
    "platform-misc-01": "Parse YAML values 0, default and positive through Schema.Agent and assert the resolved TurnLoop cap.",
    "platform-misc-08": "Pressure a temp shared log root with two live daemon identities; preserve both sessions and reclaim stale ones.",
    "web-rest-02": "Block and crash a cache loader; observe caller and rest_for_one child restart scope while preserving coalescing.",
    "web-rest-03": "Persist reset-only and zero-limit buckets; both presenter paths must render an explicit unavailable state.",
}


def load(relative):
    return json.loads((ROOT / relative).read_text())


def build(triage):
    findings = load("review/findings.json")
    assert triage["head_revision"] == RELEASE
    assert findings["snapshot"] == triage["base_revision"]
    source = {row["finding_id"]: row for row in triage["findings"]}
    reviews = {
        letter: {row["id"]: row for row in load(f"review/verdicts/independent_{letter}.json")["verdicts"]}
        for letter in ("a", "b")
    }
    high = [row for row in findings["findings"] if row["reviewed_severity"] in ("P0", "P1")]
    high_ids = {row["id"] for row in high}
    assert len(high) == len(high_ids) == 97
    assert not ((KEEP.keys() | DEFER.keys() | ADDRESSED.keys() | SPECIFIC_GATES.keys()) - high_ids)
    rows = []
    for finding in high:
        ident, ids = finding["id"], finding["source_ids"]
        a, b = [reviews[letter][ident] for letter in ("a", "b")]
        # Some merged aliases were lower-severity raw claims and therefore
        # were not among the 182 high-priority raw reviews. The canonical ID
        # itself has both independent reviews.
        assert ident in reviews["a"] and ident in reviews["b"]
        assert b["holds"] is True and a["verdict"] in ("supported_static", "qualified_static")
        if ident in KEEP:
            action, state, gate = "keep", "intentional_contract", KEEP[ident]
        elif ident in DEFER:
            action, state, gate = "defer", "evidence_before_change", DEFER[ident]
        elif ident in ADDRESSED:
            action, state, gate = "fix", "addressed_in_release", ADDRESSED[ident][1]
        else:
            action, state = "fix", "proposed_unimplemented"
            gate = SPECIFIC_GATES.get(ident, "Reproduce the cited path on the implementation head; add a behavior test that fails without the production change.")
        rows.append({
            "id": ident,
            "severity": finding["reviewed_severity"],
            "title": finding["title"],
            "owner": findings["boundary_names"][finding["primary_boundary"]],
            "owner_code": finding["primary_boundary"],
            "action": action,
            "implementation_state": state,
            "release_pr": ADDRESSED[ident][0] if ident in ADDRESSED else None,
            "source_status_at_release": source[ident]["source_status"],
            "source_ids": ids,
            "skeptic_a": {"verdict": a["verdict"], "severity": a["reviewed_severity"], "limit": a.get("limits")},
            "skeptic_b": {"holds": b["holds"], "severity": b["severity"], "limit": b.get("limitations")},
            "severity_disagreement": len({finding["reviewed_severity"], a["reviewed_severity"], b["severity"]}) > 1,
            "behavior_or_decision_gate": gate,
            "incidence": "unmeasured",
        })
    assert {row["id"] for row in rows} == high_ids
    assert len({id for row in rows for id in row["source_ids"]}) == 103
    summary = {
        "canonical_high_priority": len(rows),
        "by_action": {action: sum(row["action"] == action for row in rows) for action in ("fix", "keep", "defer", "invalid")},
        "by_state": dict(sorted(Counter(row["implementation_state"] for row in rows).items())),
        "by_severity": dict(sorted(Counter(row["severity"] for row in rows).items())),
        "by_citation": dict(sorted(Counter(row["source_status_at_release"] for row in rows).items())),
        "severity_disagreements": sum(row["severity_disagreement"] for row in rows),
    }
    return {"release_commit": RELEASE, "frozen_review_commit": findings["snapshot"],
            "method": "Proposed actions synthesized from both frozen skeptic verdicts and released-main source rechecks; no live incidence inferred.",
            "summary": summary, "findings": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--triage", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build(json.loads(args.triage.read_text()))
    header = {key: value for key, value in result.items() if key != "findings"}
    header_text = json.dumps(header, ensure_ascii=False, sort_keys=True)
    lines = [header_text[:-1] + ', "findings": [']
    for index, row in enumerate(result["findings"]):
        suffix = "," if index + 1 < len(result["findings"]) else ""
        lines.append(json.dumps(row, ensure_ascii=False, sort_keys=True) + suffix)
    lines.append("]}")
    args.output.write_text("\n".join(lines) + "\n")
    print(json.dumps(result["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
