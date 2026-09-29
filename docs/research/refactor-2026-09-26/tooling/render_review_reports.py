#!/usr/bin/env python3
"""Render concise review maps from the lossless findings index."""
from collections import Counter
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
data = json.loads((root / "review/findings.json").read_text())
findings = data["findings"]
counts = data["counts"]
severity = ["P0", "P1", "P2", "P3"]


def link(f):
    first = f["source_claims"][0]["source_file"].removeprefix("review/")
    return f"[{f['id']}]({first})"


def row(f):
    return f"| {f['reviewed_severity']} | {link(f)} | {f['title']} |"


highlights = [
    "agent-runtime-01", "events-webhooks-executor-01", "events-webhooks-executor-02",
    "orch-a-01", "orch-b-02", "orch-b-08", "orch-b-14", "build-order-03",
    "loose-1-02", "loose-3-01", "platform-misc-03", "telemetry-usage-04",
    "github-a-04", "web-rest-02", "nonelixir-shell-08",
]
by_id = {f["id"]: f for f in findings}
if not set(highlights) <= set(by_id):
    raise ValueError("Missing highlighted finding")
categories = Counter(f["category"] for f in findings)
top_categories = categories.most_common(12)
other_categories = sum(categories.values()) - sum(n for _, n in top_categories)
code_review = [
    "# Code review synthesis",
    "",
    f"Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`. This is a source-review research result, not a live-run validation or an implementation status report. The [lossless findings index](findings.json) is the detailed list; it preserves every raw source claim, citation, recommendation and reviewer disposition under its original ID.",
    "",
    "## Coverage and reconciliation",
    "",
    f"All 32 planned raw units are present. Their {counts['raw_source_ids']:,} source IDs map exactly once to {counts['canonical_findings']:,} canonical work items. {counts['merged_groups']} source-supported semantic merges combine {counts['source_ids_in_merged_groups']} source IDs, reducing the work-item count by {counts['raw_source_ids'] - counts['canonical_findings']}. The [merge decisions](findings.json) retain the reason and every original claim. A shared file, broad module finding, or textual resemblance was not enough to merge separate failure modes. Unmerged entries are separate for planning; their independence is not proven by this pass.",
    "",
    "The [reconciliation audit](in-progress/cross-unit-reconciliation.md) records the overlap screen and five strong lexical pairs retained separately. The screen is a way to find candidates, not proof that every remaining pair is independent.",
    "",
    "| Severity after source review | Canonical work items |",
    "| --- | ---: |",
    *[f"| {s} | {counts['reviewed_severity'][s]:,} |" for s in severity],
    "",
    f"Both independent skeptics reviewed every one of the {counts['source_verification']['two_independent_static_reviews']} inherited P0/P1 source IDs. Their 25 severity disagreements have a source-cited reconciliation in `verdicts/severity-reconciliation-draft.json`. The other {counts['source_verification']['raw_provisional_unverified']} P2/P3 source IDs remain provisional and have not received those independent checks. Final severity is a triage judgment on the frozen source, not an incident frequency or a claim that the bug survives later changes. Five originally high-priority citations required corrected line overlays; `location-audit.md` retains the correction trail.",
    "",
    "## Highest-priority source findings",
    "",
    f"The {counts['reviewed_severity']['P0']} retained P0 items are concrete authorization, credential and instance-isolation paths. Each still needs a release-specific exposure check before a fix is scoped:",
    "",
    "| Severity | Source ID | Finding |",
    "| --- | --- | --- |",
    *[row(f) for f in findings if f["reviewed_severity"] == "P0"],
    "",
    f"The following P1 items directly touch the progress gaps, state truth, event delivery and operational boundaries measured elsewhere in this research. This is a navigation set, not an exhaustive P1 list; all {counts['reviewed_severity']['P1']} retained P1 items are in `findings.json`:",
    "",
    "| Severity | Source ID | Finding |",
    "| --- | --- | --- |",
    *[row(by_id[i]) for i in highlights],
    "",
    "## Shape of the backlog",
    "",
    "| Category | Canonical work items |",
    "| --- | ---: |",
    *[f"| {category} | {count:,} |" for category, count in top_categories],
    f"| Other categories combined | {other_categories:,} |",
    "",
    "Duplication is the largest category, but the number of repeated literals, source spans or duplicated helper bodies is not a measured LOC saving. The topic grammar, core-to-web dependency, GitHub request classification and state-label families were merged only where the raw claims describe the same work item. Specific failures inside a large module remain independent because splitting the module does not itself repair those failures.",
    "",
    "## Verification limits and next decision",
    "",
    "The review uses frozen source, selective isolated probes and static skeptic checks. It did not boot the complete Aiur release, run the full suite, measure production incidence, or assess fixes after the snapshot. Raw P2/P3 claims can be false or overstated. The bounded name, concept and constant sweeps state their lexical and dynamic-code limits in their raw coverage notes. Before turning a finding into a rewrite ticket, confirm current-head reachability, source-specific failure conditions, boundary ownership, and a test that fails without the fix. The [boundary map](by-boundary.md) is a planning index with nonadditive cross-boundary membership.",
    "",
]
(root / "review/code-review.md").write_text("\n".join(code_review))

by_primary = Counter(f["primary_boundary"] for f in findings)
by_code = {code: [by_id[i] for i in ids] for code, ids in data["boundary_finding_ids"].items()}
boundary = [
    "# Review findings by boundary",
    "",
    "This is a navigation view over [findings.json](findings.json) for frozen `3339b887`. The first cited source location chooses a primary boundary; every cited location adds an affected boundary. A finding can therefore appear in more than one boundary, and the affected counts below must not be summed. Module-name rules are in `tooling/boundary-map.json`; non-Elixir analytics, Stream Deck, website and skills have explicit path rules in `tooling/review_synthesis.py`.",
    "",
    "| Boundary | Primary items | Affected items | P0/P1 affected | Selected high-priority IDs |",
    "| --- | ---: | ---: | ---: | --- |",
]
for code, items in sorted(by_code.items(), key=lambda x: (-len(x[1]), x[0])):
    high = [f for f in items if f["reviewed_severity"] in ("P0", "P1")]
    examples = ", ".join(link(f) for f in high[:4]) or "—"
    boundary.append(f"| {data['boundary_names'][code]} (`{code}`) | {by_primary[code]} | {len(items)} | {len(high)} | {examples} |")
boundary += [
    "",
    f"`primary items` sum to the {counts['canonical_findings']:,} canonical findings. `Affected items` include cross-boundary findings and are nonadditive. Test findings are assigned to their tested module where the module name resolves; shared test support and unknown test modules remain in the dev/test boundary. These are candidate package boundaries, not proof that a finding belongs exclusively to that package. The full IDs and source locations are in `findings.json` under `boundary_finding_ids` and each claim.",
    "",
    "## Cross-boundary work to keep together",
    "",
    "- [Core-to-web dependency](raw/web-occ.json): projection and presentation code currently points from domain and CLIs into `AiurWeb`; move the shared data contract with callers, not just files.",
    "- [Ticket-topic grammar](raw/orch-a.json): event producers and parsers span orchestration, agent runtime, wake and ingestion. Keep identifier and replay rules explicit.",
    "- [GitHub request classification](raw/github-b.json): quota, logging, cache and credential selection disagree on mutation detection; the owner belongs below those consumers.",
    "- [Usage dimension vocabulary](raw/telemetry-usage.json): one ordered five-token subset is shared; six raw fields and provider policies remain separate.",
    "",
]
(root / "review/by-boundary.md").write_text("\n".join(boundary))
