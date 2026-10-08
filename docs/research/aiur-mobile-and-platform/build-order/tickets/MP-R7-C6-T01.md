---
ticket_id: MP-R7-C6-T01
feature_id: MP-R7
chunk_id: MP-R7-C6
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Contributor documentation — how to add a harness adapter
status: ready
blocked_by: [DESIGN-R7, MP-R7-C3-T05, MP-R7-C4-T01, MP-R7-C2-T01, MP-R7-C2-T02]
prior_units: [U8]
prior_boundaries: [CA (20)]
prior_features: []
prior_findings: []
size_owner: n/a (CONTRIBUTING.md is 293 lines at base; stays < 500)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C6-T01 — Contributor docs: adding a harness adapter

## Identity and outcome

- Bucket 1, MP-R7, chunk C6. **Documentation only — no production code.**
- **User value:** a contributor (or an agent) adds a harness without
  re-discovering the registry rules or adding a new upward leak.
- **Deliverable:** a new `## Adding a harness adapter` section in
  `CONTRIBUTING.md` (after `## Reuse before invention`), ≤ 60 lines, covering:
  adapter module implementing `Aiur.CodingAgent.Backend` (required callbacks,
  optional `interrupt/1` and the reserved `steer/3`,
  `reply_native_question/3`, `release_native_question/3` from MP-R7-C2-T02);
  the provider registry entry and its capability keys (including
  `:launch_telemetry`, `:display_tailer`, `:children` from C3-T03/C4-T01);
  derived `delivery_primitives` (C2-T01); the agent tool surface
  `Aiur.AgentTools` (C3-T01); the boundary rule and how to add the namespace
  to `private_namespaces` (C3-T05); the C1 characterization and contract tests
  to extend; the C5 sibling protocol fixture for app-server harnesses.
- **Non-goals:** user-facing docs. AGENTS.md "Docs ship with the change" table
  has no row for contributor internals and R7 changes no config key, CLI
  command, env var or surface, so `website/docs-app/` is untouched.

## Dependencies and blockers

- DESIGN-R7 and the tickets whose mechanisms it documents (C2-T01, C2-T02,
  C3-T05, C4-T01). If C4-T03..T05 later run, add the package path then (one
  paragraph; part of C4-T05's handoff).
- Why `CONTRIBUTING.md` and not `src/README.md`: `CONTRIBUTING.md` already holds
  engineering norms (AGENTS.md "Engineering norms … live in CONTRIBUTING.md");
  `src/README.md` is operator setup.

## Verified starting point (base `45a290e3`)

- `CONTRIBUTING.md` (293 lines): `## Code structure` :36, `## Reuse before
  invention` :54, `## Testing` :66, `## Enforcement` :257.
- `coding_agent/backend.ex:5-15` moduledoc already states the rule "a new
  backend needs only an adapter module and a registry entry"; the doc links to
  it rather than restating the typedoc.
- No existing contributor page describes harnesses
  (`git grep -n -i "harness\|adapter module" 45a290e3 -- CONTRIBUTING.md src/README.md`
  returns only unrelated hits: `src/README.md:424` "isolated harness" and the
  browser-test harness at :807-841).

## Chosen design

Short section with a numbered checklist and links to the source of truth
(`backend.ex`, `providers/*.ex`, the MP-R1 manifest entry). It does not copy
the capability table (a second copy goes stale; AGENTS.md GitHub-docs rule
applies by analogy).

## Implementation steps

1. Write the section; link files by repo-relative path.
2. Cross-link from `coding_agent/backend.ex` moduledoc ("See CONTRIBUTING.md
   § Adding a harness adapter") — a doc-string change only.

## Non-happy paths

n/a — documentation; the only risk is staleness, mitigated by linking instead
of copying.

## Compatibility and rollout

n/a — no runtime effect.

## Verification

Test expectation: none — documentation only. Review check: every symbol named
in the section exists at the merge head
(`mise exec -- rg -n '<symbol>' src/lib` for each), and markdown renders.

## Completion and handoff

- [ ] Section merged; every named symbol verified at merge head.
- Dependents: none. Update again if C4-T03..T05 run.
