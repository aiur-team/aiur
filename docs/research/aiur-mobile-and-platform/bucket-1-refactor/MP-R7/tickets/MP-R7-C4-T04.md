---
ticket_id: MP-R7-C4-T04
feature_id: MP-R7
chunk_id: MP-R7-C4
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Move the Codex, Claude, Muse, OpenAI-compat (and, if merged, Gemini) adapters into aiur_harness
status: blocked
blocked_by: [DESIGN-R7, MP-R7-C4-T03, U8 CLAUDE splits (claude/remote_control.ex, claude/telemetry.ex, claude/coding_agent.ex), U8 CODEX split (codex/event_humanizer.ex), MP-R1-C5-T2]
prior_units: [U4, U7, U8]
prior_boundaries: [CDX (21), CLD (22), OAI (23), TUI (33)]
prior_features: [integrations-09]
prior_findings: []
size_owner: CLAUDE (remote_control.ex 726, telemetry.ex 666, coding_agent.ex 534); CODEX (event_humanizer.ex 510)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C4-T04 — Move the adapters into `aiur_harness`

## Identity and outcome

- Bucket 1, MP-R7, chunk C4. **Conditional** on MP-R7-C4-T02 = go (via T03).
- **Deliverable:** `src/lib/aiur/{codex,claude,muse,open_ai_compat}/**` and
  `coding_agent/providers/**` move into the package created by T03, one PR per
  harness family in this order: OpenAI-compat (fan-in 1, cleanest per prior
  §23), Muse, Codex, Claude (headless + REPL). Each PR is one bounded outcome;
  this ticket file covers the series because the steps are identical.
- **Gemini/ACP (RC-22):** if aiur-team/aiur#2870 (draft, head `c1fc6f84`) has
  merged before this ticket starts, add a fifth PR moving
  `src/lib/aiur/gemini/**`, `coding_agent/providers/gemini.ex` and
  `usage/headless/gemini/turn_usage.ex` (the last stays with accounting if
  MP-R1 places usage adapters there). If #2870 has not merged, record Gemini as
  a future adapter that lands **directly in the package**; no step here.
- **Non-goals:** module renames; behaviour changes; the Claude Remote Control
  cut decision (prior U7 `integrations-09`).

## Dependencies and blockers

- MP-R7-C4-T03 merged.
- Four moved files exceed 500 lines (U8 owners above); the U8 transitional
  gate rejects a new >500 path, so their splits land first. RC-23: re-check
  owners against the then-current U8 ledger.
- `claude/remote_control.ex` process helpers must already live in the kernel
  (MP-R1-C5-T2), or the package would export them back to sandbox/workspace
  callers (C3-T05 allowlist class 5) — an upward edge from L2 domain peers into
  the harness package.
- Claude REPL depends on the tmux transport (`Repl.* → Tmux`, prior §22
  "move the tmux transport down first (33)"). The package declares tmux as an
  optional dependency; if MP-R1 has not moved `Aiur.Tmux` below the harness
  layer, the Claude PR is blocked on that move (name it in the PR).

## Verified starting point (base `45a290e3`)

- Adapter trees: `codex/` (incl. `dynamic_tool/` until C3-T01),
  `claude/` (33 files per prior §22), `muse/`, `open_ai_compat/` (20 files per
  prior §23); providers in `coding_agent/providers/{codex,claude,muse,fake}.ex`
  and `open_ai_compat/registry.ex`.
- Oversized: `claude/remote_control.ex` 726, `claude/telemetry.ex` 666,
  `claude/coding_agent.ex` 534, `codex/event_humanizer.ex` 510 (line counts at
  base; owners from `docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv`).
- Cross-adapter edges inside the component (not violations, but they decide PR
  order): `coding_agent/providers/fake.ex` uses `Aiur.Codex.CodingAgent`;
  in #2870, `gemini/transport.ex:4` aliases `Aiur.Muse.Transport` (so Gemini
  moves after Muse).
- `Aiur.Claude.Telemetry` child is registry-declared after MP-R7-C4-T01.

## Chosen design

- Per-family PR: `git mv` the tree, move its tests, update the package's file
  list; no code edits beyond paths. Registry entries already name modules, so
  no dispatch change.
- Order chosen for least risk: OpenAI-compat → Muse → (Gemini, if merged) →
  Codex → Claude.

## Implementation steps

1. For each family: `git mv` lib and test trees into the package; run the
   package and main suites; run the MP-R1 checker.
2. Claude PR: declare the tmux dependency optional in the package `mix.exs`
   (exact mechanism per CR-R7-1).
3. Gemini PR (only if #2870 merged): move after Muse.

## Non-happy paths

- A family's tests require the main app's processes (criterion 3 failing for
  that family): stop; record in the T02 record; do not move that family.
- Fallback (`claude-repl` → `claude`) and RC promotion cross two entries of
  the same family; both move in the same PR.

## Compatibility and rollout

No config, CLI or behaviour change; `agent.routing` values and labels are
untouched (DESIGN-R7 §1). Rollback: revert the family's PR.

## Verification

- Per PR: MP-R7-C1 suite unchanged; package and main suites green;
  `python3 scripts/check-components.py` green.
- Manual (DESIGN-R7 decision 1; AGENTS.md "Manual testing"): after the Codex and
  Claude PRs, run `scripts/aiurdev --test` in the wrapper-tmux recipe, open a
  Codex agent's and a Claude agent's chat pane (`Enter` on a running row), type
  a message in pane `0.1`, and capture with
  `tmux -L "$AIUR_SOCKET" capture-pane -t "$AIUR_SESSION:0.1" -p -S -200`;
  the message is delivered and rendered as before.
- Mutation: none (pure moves); state so in each PR body.

## Completion and handoff

- [ ] All families moved, or the unmoved ones recorded with reasons.
- [ ] Gemini handled per RC-22 (moved, or recorded as future in-package adapter).
- [ ] Foreground manual run captured for Codex and Claude.
- Docs: C6-T01 updated with adapter locations.
- Dependents: MP-R7-C4-T05.
