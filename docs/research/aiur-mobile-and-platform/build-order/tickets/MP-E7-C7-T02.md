---
ticket_id: MP-E7-C7-T02
feature_id: MP-E7
chunk_id: MP-E7-C7
bucket: 2-platform
title: "TUI AgentList: listener-mode indicator and optional key (per DESIGN-E7 §1.6)"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C7-T03, MP-E7-C2-T03, MP-E7-C5-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U9]
prior_boundaries: [TUI]
prior_features: []
prior_findings: []
size_owner: TUI (agent_list/*)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C7-T02 — TUI listener-mode indicator

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C7.
- **User value:** in the terminal board the operator can tell how a message
  to an agent will land, and (if DESIGN-E7 wants) change it.
- **Deliverable:** exactly what DESIGN-E7 §1.6 decides: (a) an AgentList cell
  showing effective mode (and requested if different) and unread count, and/or
  (b) a key that cycles or sets the mode. If DESIGN-E7 says "no TUI change",
  this ticket closes as not needed.
- **Non-goals:** chat pane (`0.1`) changes unless DESIGN-E7 asks.

## Dependencies and blockers

- **DESIGN-E7 §1.6** (whether the TUI shows a mode; whether a key changes it,
  and which key).
- **MP-E7-C7-T03** (write path), **MP-E7-C2-T03**, **MP-E7-C5-T02** (data).
- **May run concurrently with** C7-T01.

## Verified starting point (at `45a290e3`)

- Key dispatch: `agent_list/input.ex:102-117` binds Enter/LF, space, `k`,
  `j`, `a`, `r`, `v`, `?`, `q`, `O`. Any new key must avoid these.
- Rendering: `agent_list/renderer.ex`, cells in `agent_list/renderer/cells.ex`
  (exists; references shared instructions at `:81`).
- Tests: `src/test/aiur/agent_list/input_test.exs` and renderer tests under
  `src/test/aiur/agent_list/`.
- Docs: `website/docs-app/guide/tui.md` key table (`:62` row for Ctrl+C).

## Chosen design

- Cell content comes from the same `listener` map as the dashboard; unknown
  renders the explicit unavailable glyph/text DESIGN-E7 defines.
- A key, if approved, calls the C7-T03 control function with
  `expected_version`; a conflict shows a transient status line.

## Implementation steps

1. Renderer cell. 2. Optional `dispatch/3` clause. 3. Help overlay entry.
4. Tests. 5. `guide/tui.md` row.

## Non-happy paths

- Narrow terminal: cell drops before identifier (follow existing column
  priority in the renderer).
- Control RPC failure: status line error; no local state change.

## Compatibility and rollout

Hidden under `:legacy` routing (same rule as C7-T01).

## Verification

- `renderer` test: `"row shows effective mode and requested when different"`;
  `"unknown listener renders unavailable"` — mutation: render `sync` for
  unknown → fails.
- `input_test.exs` (only if a key is approved): `"<key> requests the next
  mode with expected_version"`.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur/agent_list`.
- Manual (AGENTS.md wrapper-tmux recipe): capture pane `0.0` and check the
  cell; press the key if approved and capture again.

## Completion and handoff

- [ ] DESIGN-E7 §1.6 answer cited.
- [ ] `website/docs-app/guide/tui.md` updated (AGENTS.md: TUI view change).
