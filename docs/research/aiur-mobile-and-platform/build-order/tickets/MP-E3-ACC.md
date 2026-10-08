# MP-E3-ACC — MP-E3 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E3-C4-T04, MP-E3-C5-T01, MP-E3-C6-T02, MP-E3-C6-T03, MP-E3-C7-T01, MP-E3-C7-T02

## Outcome

The Executor proves MP-E3 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E3/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (20)

- MP-E3-C1-T01 — Executor session binding store: one opt-in attached session per instance, with generation and takeover
- MP-E3-C1-T02 — Executor hook ingest: token file, bearer plug, POST /api/v1/executor/hook, payload normalizer
- MP-E3-C1-T03 — CLI: aiur executor-attach / executor-detach / executor-session
- MP-E3-C1-T04 — Hook config generator and installer (Claude project-local settings; Codex printed config)
- MP-E3-C2-T01 — Claude Executor transcript ingest: tail the attached session's JSONL into the Executor conversation
- MP-E3-C2-T02 — Claude transcript format guard: tested-version pin, unknown-record counting, one drift alert
- MP-E3-C3-T01 — Spike (no product code): Codex TUI rollout fixtures at 0.160.x and hook transcript_path check
- MP-E3-C3-T02 — Codex Executor transcript reader: tail the rollout JSONL with a version-pinned extractor
- MP-E3-C3-T03 — Executor read capability record: proven | untested | unsupported per harness and version
- MP-E3-C4-T01 — Executor harness-state machine from hooks, with TTL to unknown and rendered ages
- MP-E3-C4-T02 — Executor background-agent roster from subagent and task hooks; unsupported, never zero
- MP-E3-C4-T03 — Executor blockers: Executor Commands, open asks and fleet blockers, with per-source availability
- MP-E3-C4-T04 — (Optional) aiur-run skill emits executor.progress on its progress-table cadence
- MP-E3-C4-T05 — Executor.Status.snapshot/0 and its CLI/JSON output (aiur status, executor-session --json)
- MP-E3-C5-T01 — Executor send adapter over the listener-mode path, capability-gated composer, shared delivery overlay
- MP-E3-C6-T01 — Executor view: /executor route, entry point, not-attached, read-only and conversation states
- MP-E3-C6-T02 — Executor status header: harness state with age, read capability, wakes and roster
- MP-E3-C6-T03 — Executor blockers and background-agents panels, with browser tests
- MP-E3-C7-T01 — aiur executor-attach --check: distinct diagnosis of every opt-in failure
- MP-E3-C7-T02 — Docs and skills: Executor conversation concepts, privacy statement, aiur-run/aiur-intro opt-in

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
