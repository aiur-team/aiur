---
title: "feat: aiur init wizard — second pass (model tags, copy, remote routing)"
type: feat
status: active
date: 2026-06-15
---

# feat: aiur init wizard — second pass

## Overview

A second pass over the `aiur init` wizard from tire-kicking feedback. Nine items split
across the wizard surface (`Aiur.Init`, `Aiur.Init.Prompt`, `Aiur.GitHub.Labels`) and a
runtime slice (`Aiur.CodingAgent`, `Aiur.Config.Schema`, `Aiur.AgentRunner`) so that a
complexity tag can default to a model **and** remote mode, and so the remote concept stops
leaking the internal `claude-repl` backend into the operator-facing surface.

The load-bearing decision is how "complexity:1 = claude:haiku + remote" is encoded and
dispatched — locked in Key Technical Decisions below.

---

## Problem Frame

The wizard's first pass shipped, but live use surfaced nine gaps:

1. `claude-repl` shows up as a selectable agent (it is an internal transport, not a user choice).
2. The model-tag UX conflates `claude-repl` (transport) with remote mode. The operator should
   pick **one** model tag (e.g. `claude:haiku`) and **optionally** add remote (`claude:remote`);
   `model:claude-repl*` tags should not exist; a bare `model:claude-haiku` is missing.
3. Codex only offers `gpt-5.5` — no cheaper variants.
4. Routing copy is unclear.
5. Hint text is inline/above the question instead of faint+indented beneath it.
6. Pre-warm helper copy is vague.
7. Polling copy is verbose.
8. A `claude-repl` CLI auth warning fires (no command configured) on fresh run and resume.
9. Token-scope instructions are too terse to follow.

The current runtime conflation (from `Aiur.CodingAgent`): `@backend_aliases %{"claude-remote" => "claude-repl"}`
makes `model:claude-remote` do double duty — it both *selects* the `claude-repl` backend and
*forces* remote control (`remote_control_forced?/1`). And remote dispatch only works because
the resolved backend is already `claude-repl` (`Aiur.AgentRunner` `run_codex_turns/5` →
`start_agent_session/3`; the headless `claude` adapter has no remote path). Routing
(`agent.routing`) can pick backend+model but cannot force remote at all.

---

## Requirements Trace

- R1. Agent multiselect offers only `claude` and `codex`; never `claude-repl`.
- R2. `model:claude-remote` is a pure remote **flag**; the model comes from a separate
  `model:<backend>[-variant]` tag. No `model:claude-repl*` tags are ever created. A bare
  `model:claude-haiku` exists.
- R3. A routed complexity can carry an optional remote flag, and a complexity tag actually
  dispatches that model in remote mode (e.g. `complexity:1 → claude:haiku + remote` runs
  haiku via the remote transport).
- R4. Codex exposes cheaper model variants (`gpt-5.4`, `gpt-5.5-mini`, `gpt-5.4-mini`)
  alongside `gpt-5.5`.
- R5. Routing walkthrough uses the new intro/closing copy and asks model + optional-remote
  per complexity.
- R6. Every hint renders faint, indented, on its own line beneath the question.
- R7. Pre-warm, polling, and token-scope copy match the requested wording.
- R8. No `claude-repl` CLI auth warning on fresh run or resume.
- R9. `Config.settings!()` parses a wizard-written config whose `complexity:1` routes to
  haiku+remote.

---

## Scope Boundaries

- Not changing the raw-key terminal stack, the resume/summary flow, the token-gate flow, or
  label idempotency/fallback behavior beyond the copy/label-set edits named here.
- Not adding new backends. `claude-repl` stays in the registry as the internal remote
  transport — it is only removed from the **wizard surface** (selection, tags, auth check).
- Not changing how the AgentList `r` key toggles `model:claude-remote` at runtime.

### Deferred to Follow-Up Work

- aiur / aiurdev launcher unification — remains the next effort after this pass (tracked in
  the prior plan's Deferred section and memory `project-aiur-aiurdev-parity`).

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/init.ex` — wizard: `prompt_agents/1`, `prompt_routing/2`, `routing_options/1`,
  `check_agent_clis/3`, `token_setup_instructions/1`, `hint/2`, `runtime_io/0`.
- `src/lib/aiur/init/prompt.ex` — `select/4`, `multiselect/4`, `input/3`; redraw math moves up
  by option-line count only, so a label/hint above the options is safe; `input/3` redraws a
  single line with `\r\e[2K` (a multi-line label would break it — hint must be a separate
  pre-printed line, not folded into the label).
- `src/lib/aiur/coding_agent.ex` — `backends/0` registry (`:models` per backend),
  `override_labels/1`, `alias_labels/0`, `@backend_aliases`, `override/1` + `match_override/2`
  (backend/model resolution), `remote_control_forced?/1`, `routing_backend/1`, `routing_model/1`.
- `src/lib/aiur/config/schema.ex` — `split_routing_value/1`, `normalize_agent_routing/1`,
  `validate_agent_routing/2`.
- `src/lib/aiur/agent_runner.ex` — `run_codex_turns/5` (lines ~417-432): computes `backend`,
  `model`, `rc?`, builds `session_opts`; `should_display_tail?/3` and `maybe_put_rc_name/3` key
  on `backend == "claude-repl"`; `start_agent_session/3` already falls back claude-repl→claude.
- `src/lib/aiur/github/labels.ex` — `label_set/2`, `model_labels/1`, `alias_labels/1`, `describe/1`.

### Institutional Learnings

- `model:claude-remote` is the durable RC source of truth toggled by the AgentList `r` key
  (`remote_control_alias_label/0`) — keep `remote_control_forced?/1` recognizing it.
- RC physically runs on the `claude-repl`/ReplAgent transport (persistent pane); the headless
  `claude` adapter has no remote path (memory: RC cloud-mediated / no_transcript root).

---

## Key Technical Decisions

- **`model:claude-remote` becomes a pure flag.** `override/1` (backend/model resolution) skips
  any label whose spec is exactly an alias key (`claude-remote`), so it no longer selects the
  `claude-repl` backend. `remote_control_forced?/1` still detects it (independent code path).
  The model is taken from the companion `model:<backend>[-variant]` tag; with no companion tag,
  backend falls through to routing/global default. Rationale: matches the operator's two-tag
  mental model and stops `claude-repl` leaking into backend selection.

- **Remote dispatch swaps transport, not model.** In `run_codex_turns/5`, after computing
  `backend` + `rc?`, the session backend becomes `claude-repl` when `rc?` and the resolved
  family backend is `claude` (model unchanged). `claude-repl` is the internal remote transport;
  it is never a tag or a selectable agent. Existing `should_display_tail?/3`, `maybe_put_rc_name/3`,
  and the claude-repl→claude start fallback then work unchanged.

- **Routing-value grammar gains a `+remote` suffix.** A routing value is
  `"<backend>[:<model>][+remote]"` — e.g. `"claude:haiku+remote"`, `"claude+remote"`,
  `"codex:gpt-5.4"`. `+` is safe (model label charset is `[A-Za-z0-9.\-]`, config routing
  values are not labels). `Schema.split_routing_value/1` strips and reports the flag; validation
  checks the base backend. `CodingAgent.routing_remote?/1` returns the flag for the issue's
  routed complexity, and `rc?` becomes
  `(remote_control_forced?(issue) or routing_remote?(issue) or Config.agent_remote_control?()) and remote_control?(backend)`.
  Rationale: one-line-per-level config stays human-readable and round-trips through the existing
  normalize/validate path; avoids a parallel remote map.

- **Codex models:** add `gpt-5.4`, `gpt-5.5-mini`, `gpt-5.4-mini` to the codex registry
  `:models` (confirmed with user). Claude registry adds bare `haiku`.

- **Hints:** add an optional `:hint` to `Prompt.select/4`, `multiselect/4`, `input/3`, rendered
  faint+indented beneath the question. Thread it through the `io` seam so test doubles stay
  injectable.

---

## Open Questions

### Resolved During Planning

- Cheaper codex model ids: `gpt-5.4`, `gpt-5.5-mini`, `gpt-5.4-mini` (user-confirmed).
- How "complexity:1 = haiku + remote" dispatches: routing `+remote` flag → `rc?` → transport
  swap to `claude-repl` (see Key Technical Decisions).

### Deferred to Implementation

- Whether `ReplAgent.start_session` honors the `:model` opt for a swapped claude-repl session
  (haiku) — verify during U5; if not, pass the model through the same way the alias-variant path
  did. (`claude-repl` already lists the same `:models`, so it should.)
- Exact faint/indent escape used for hint lines — reuse `IO.ANSI.format([:faint, "  " <> text])`
  from `Init.hint/2`.

---

## Implementation Units

- [ ] U1. **Drop claude-repl from the wizard surface**

**Goal:** Agent multiselect offers only `claude`/`codex`; the CLI auth check never warns about
`claude-repl` on fresh run or resume.

**Requirements:** R1, R8

**Files:**
- Modify: `src/lib/aiur/init.ex` (`agent_kind_choices/0`, `check_agent_clis/3`)
- Test: `src/test/aiur/init_test.exs`

**Approach:**
- `agent_kind_choices/0` returns only backends with a real CLI surface — filter `claude-repl`
  out (it has no `agent_executable/1`). Keep ordering (`@routing_order` first).
- `check_agent_clis/3` checks only kinds whose `agent_executable/1` is non-nil, so a
  `claude-repl` derived from a resumed routing table never produces
  `⚠ claude-repl agent: no command configured`.

**Test scenarios:**
- Happy path: multiselect choices are exactly `["claude", "codex"]` (no `claude-repl`).
- Edge case: resume from a config whose routing includes a remote/claude-repl-derived backend →
  auth check runs claude + codex only, emits no claude-repl warning.
- Happy path: a missing real CLI (claude) still warns + offers retry (unchanged behavior).

**Verification:** No `claude-repl` in the agent list; no claude-repl auth warning in fresh or
resume runs.

---

- [ ] U2. **Backend registry: add claude haiku + cheaper codex models**

**Goal:** Seed bare `model:claude-haiku` and codex `gpt-5.4` / `gpt-5.5-mini` / `gpt-5.4-mini`.

**Requirements:** R2 (haiku), R4

**Files:**
- Modify: `src/lib/aiur/coding_agent.ex` (`backends/0` `:models`)
- Test: `src/test/aiur/coding_agent_test.exs`

**Approach:**
- claude `:models` → add `"haiku"` (keep existing). codex `:models` →
  `["gpt-5.5", "gpt-5.4", "gpt-5.5-mini", "gpt-5.4-mini"]`.
- This flows automatically into `override_labels/1` (label set) and `routing_options/1`
  (wizard) and `codex_command/1` (`--config model="..."`).

**Test scenarios:**
- Happy path: `override_labels(["claude"])` includes `model:claude-haiku`.
- Happy path: `override_labels(["codex"])` includes `model:codex-gpt-5.4`,
  `model:codex-gpt-5.5-mini`, `model:codex-gpt-5.4-mini`.
- Edge case: `model_for(issue(["model:codex-gpt-5.4-mini"]))` resolves to `"gpt-5.4-mini"`
  (hyphenated variant not mis-split).

**Verification:** New labels derive from the registry; codex command splices the chosen variant.

---

- [ ] U3. **Routing-value `+remote` grammar in Schema**

**Goal:** Parse/normalize/validate an optional trailing `+remote` on routing values.

**Requirements:** R3

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (`split_routing_value/1`, `normalize_agent_routing/1`,
  `validate_agent_routing/2`)
- Test: `src/test/aiur/config/schema_test.exs` (or wherever routing parsing is tested)

**Approach:**
- `split_routing_value/1` strips a trailing `+remote` before splitting backend/model; expose the
  remote flag (e.g. add `split_routing_value/1` → `{backend, model}` unchanged and a sibling
  `routing_remote_flag?/1`, or return a 3-tuple via a new function and keep the 2-tuple for
  callers). Keep `split_routing_value/1`'s existing contract for `CodingAgent` callers.
- Validation: strip `+remote`, then validate the base backend is known and `+remote` only
  attaches to a claude-family value (reject `codex:...+remote`).

**Test scenarios:**
- Happy path: `"claude:haiku+remote"` → backend `claude`, model `haiku`, remote true.
- Happy path: `"claude+remote"` → backend `claude`, model nil, remote true.
- Happy path: `"codex:gpt-5.4"` → backend `codex`, model `gpt-5.4`, remote false.
- Error path: `"codex:gpt-5.4+remote"` rejected by `validate_agent_routing`.
- Edge case: a config map round-trips `+remote` through `normalize_agent_routing/1`.

**Verification:** `Config.settings!()` accepts `complexity:1 = claude:haiku+remote`.

---

- [ ] U4. **CodingAgent: flag-only `model:claude-remote` + `routing_remote?/1`**

**Goal:** Stop `model:claude-remote` selecting a backend; expose routed-remote.

**Requirements:** R2, R3

**Dependencies:** U3

**Files:**
- Modify: `src/lib/aiur/coding_agent.ex` (`override/1`/`match_override/2`, add `routing_remote?/1`)
- Test: `src/test/aiur/coding_agent_test.exs`

**Approach:**
- `match_override/2` returns nil when the spec is exactly an alias key (`claude-remote`) — it is
  a flag, not a backend selector. `remote_control_forced?/1` is unchanged (still fires).
- Add `routing_remote?(issue)`: reads the routed value for the issue's highest complexity and
  returns its `+remote` flag (via the Schema helper from U3).

**Test scenarios:**
- Happy path: `backend_for(issue(["model:claude-haiku", "model:claude-remote"]))` → `claude`,
  `model_for` → `haiku`, `remote_control_forced?` → true.
- Edge case: `model:claude-remote` alone → backend falls through to routing/global default;
  `remote_control_forced?` true.
- Happy path: `routing_remote?` true for an issue whose complexity routes to `claude:haiku+remote`.
- Edge case: `routing_remote?` false when no complexity label / no `+remote`.

**Verification:** Two-tag issue resolves claude+haiku with forced remote; alias never selects
`claude-repl` as a backend.

---

- [ ] U5. **Dispatch: remote transport swap + routed-remote in `rc?`**

**Goal:** A forced/routed remote claude issue dispatches the `claude-repl` transport carrying the
resolved model.

**Requirements:** R3

**Dependencies:** U4

**Files:**
- Modify: `src/lib/aiur/agent_runner.ex` (`run_codex_turns/5`)
- Test: `src/test/aiur/agent_runner_test.exs` (or the dispatch/backend-resolution test file)

**Approach:**
- `rc?` gains `routing_remote?(issue)` as a third OR term.
- When `rc?` and resolved `backend == "claude"`, set the session backend to `"claude-repl"`
  (model unchanged) before building `session_opts`; `should_display_tail?/3`, `maybe_put_rc_name/3`,
  and the start fallback then behave as today.
- Verify `ReplAgent.start_session` honors the `:model` opt (deferred check); if not, pass model
  the way the alias-variant path did.

**Test scenarios:**
- Happy path: issue `model:claude-haiku` + `model:claude-remote` → session_opts backend
  `claude-repl`, model `haiku`, remote_control true.
- Happy path: complexity routed to `claude:haiku+remote` (no labels) → same dispatch.
- Edge case: codex issue (no remote) → backend `codex`, no swap, rc? false.
- Edge case: claude issue, remote off → backend `claude` (headless), no swap.
- Integration: claude-repl start failure still falls back to headless `claude` (existing path).

**Verification:** Logged `backend=claude-repl model=haiku remote_control=true` for the haiku+remote
case; non-remote paths unchanged.

---

- [ ] U6. **Label set: flag-only remote, no claude-repl tags**

**Goal:** The created label set has `model:claude-remote` (flag) + per-selected-backend model
tags, and never `model:claude-repl*`.

**Requirements:** R2

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur/github/labels.ex` (`alias_labels/1`, `describe/1` as needed)
- Test: `src/test/aiur/github/labels_test.exs`

**Approach:**
- `alias_labels/1` appends `model:claude-remote` when `claude` is among selected backends
  (drop the `claude-repl` trigger). Since the wizard never selects `claude-repl` (U1),
  `model_labels/1` already excludes `model:claude-repl*`.
- Confirm `describe/1` covers `model:claude-haiku`, the new codex variants, and `model:claude-remote`.

**Test scenarios:**
- Happy path: `label_set("agent", ["claude"])` includes `model:claude-haiku` + `model:claude-remote`,
  excludes any `model:claude-repl*`.
- Happy path: `label_set("agent", ["codex"])` includes the new codex variants, no `model:claude-remote`.
- Happy path: every label in the set has a non-empty `describe/1`.

**Verification:** Label set matches the operator-facing model; no claude-repl tags.

---

- [ ] U7. **Routing walkthrough rework (copy + model + optional remote)**

**Goal:** New intro/closing copy; per complexity pick one model, then optionally remote (claude
only); write `+remote` into the routing value.

**Requirements:** R3, R5

**Dependencies:** U2, U3, U6

**Files:**
- Modify: `src/lib/aiur/init.ex` (`prompt_routing/2`, `routing_options/1`)
- Test: `src/test/aiur/init_test.exs`

**Approach:**
- Intro line: "Aiur supports story point complexity tags to optimize effort per ticket. Select
  default models for each:". Walk all five levels (primary preselected, Enter accepts).
- After choosing a claude model for a level, ask an optional remote toggle (Yes/No, default No);
  append `+remote` to that level's routing value. Codex selections skip the toggle.
- Closing line: "Aiur will default to use these models if you include complexity tags on your
  tickets. You can also override these by tagging specific models on the ticket."

**Test scenarios:**
- Happy path: selecting `claude:haiku` + remote=Yes for level 1 writes `1: claude:haiku+remote`.
- Happy path: codex selection writes `codex:gpt-5.4` with no remote prompt.
- Edge case: declining the walkthrough routes all levels to the primary (no `+remote`).
- Happy path: intro + closing copy printed.

**Verification:** Written `agent.routing` round-trips through `Config.settings!()`; level 1 = haiku+remote.

---

- [ ] U8. **Hints beneath the question + copy fixes**

**Goal:** All hints render faint, indented, on their own line under the question; pre-warm and
polling copy updated.

**Requirements:** R6, R7

**Files:**
- Modify: `src/lib/aiur/init/prompt.ex` (`:hint` opt on `select/4`, `multiselect/4`, `input/3`)
- Modify: `src/lib/aiur/init.ex` (thread `:hint` through `io` seam; reword max-turns, max-duration,
  pre-warm, polling)
- Test: `src/test/aiur/init/prompt_test.exs`, `src/test/aiur/init_test.exs`

**Approach:**
- `Prompt` renders an optional hint line beneath the label (faint+indent); redraw math unaffected
  for `select`/`multiselect` (moves over option lines only) and `input` (hint pre-printed once
  above the single redrawn input line).
- Move existing inline/above hints under the question: max-turns ("none = unlimited"), max-duration
  ("fallback for stuck agents; none = never auto-kill"), pre-warm
  ("Set this to how many opencode panes you expect to open at once."), polling.
- Polling question → "How often should aiur check the tracker for new work? (seconds):".

**Test scenarios:**
- Happy path: a prompt with `:hint` writes the question line, then a faint indented hint line,
  then options/input.
- Happy path: pre-warm and polling questions render the exact requested copy with the hint beneath.
- Edge case: `:hint` absent → output unchanged from today.
- Edge case (degrade/non-TTY): hint path does not break the default-return degrade.

**Verification:** Manual run shows greyed indented hints beneath each question.

---

- [ ] U9. **Explicit token-scope click-paths**

**Goal:** Step 1 of `token_setup_instructions/1` gives followable click-paths for classic and
fine-grained tokens.

**Requirements:** R7

**Files:**
- Modify: `src/lib/aiur/init.ex` (`token_setup_instructions/1`)
- Test: `src/test/aiur/init_test.exs`

**Approach:**
- Classic: Generate new token (classic) → check the `repo` scope (full control of private
  repositories).
- Fine-grained: Repository access → Only select repositories → this repo → Permissions →
  Repository permissions → Issues, Contents, Pull requests each = Read & write.

**Test scenarios:**
- Happy path: instructions include the classic `repo` step and the three fine-grained
  permissions with Read & write.

**Verification:** Token instructions are followable without leaving the terminal.

---

- [ ] U10. **Manual end-to-end verification**

**Goal:** Drive the wizard in a fresh repo and confirm all nine items.

**Requirements:** R1–R9

**Dependencies:** U1–U9

**Files:** none (manual)

**Approach:** Build the release; run `aiurdev init` in a scratch repo. Confirm: agent list has no
claude-repl; routing shows new copy + model + optional-remote; hints greyed beneath each question;
pre-warm/polling/token copy correct; written `.aiurconfig` routes `complexity:1` to haiku+remote and
`Config.settings!()` parses it; with a token, the label set includes `model:claude-haiku` +
`model:claude-remote` and no `model:claude-repl*`; resume run shows no claude-repl warning.

**Test expectation:** none — manual verification gate.

**Verification:** All nine confirmed live; then flag the user to test.

---

## System-Wide Impact

- **Interaction graph:** `model:claude-remote` semantics change touches `CodingAgent.override/1`,
  `remote_control_forced?/1`, the AgentList `r` toggle (`remote_control_alias_label/0`), and
  `AgentRunner` dispatch. The `r` toggle still adds/removes `model:claude-remote`; with override
  ignoring it, toggling RC no longer accidentally changes the resolved backend.
- **Error propagation:** claude-repl start failure still falls back to headless `claude`
  (`start_agent_session/3`) — unchanged.
- **API surface parity:** routing `+remote` grammar must be honored everywhere a routing value is
  parsed (`Schema.split_routing_value/1` is the single chokepoint; `CodingAgent.routing_backend/1`
  / `routing_model/1` consume it).
- **Unchanged invariants:** existing `model:<backend>[-variant]` labels, the resume/summary flow,
  token-gate flow, label idempotency + gh fallback, and the `claude-repl` registry entry all stay
  as-is.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `+remote` grammar leaks into a label or shell splice | Routing values are config-only, never labels; `+` excluded from the `model:` label charset. Validation rejects malformed values. |
| Transport swap breaks a non-remote claude path | Swap is guarded by `rc? and backend == "claude"`; non-remote claude stays headless. Covered by U5 edge tests. |
| ReplAgent ignores `:model` on a swapped session | Verify in U5; claude-repl lists the same `:models`, alias-variant path already passed a model. |
| Hint line desyncs `input/3` single-line redraw | Hint pre-printed once above the input line; redraw still targets only the input line. |

---

## Sources & References

- Prior plan: `docs/plans/2026-06-15-002-feat-init-wizard-rework-plan.md`
- Memory: `project-aiur-aiurdev-parity`, RC cloud-mediated / no_transcript root
- Related: PR #333 (branch `init-setup`)
