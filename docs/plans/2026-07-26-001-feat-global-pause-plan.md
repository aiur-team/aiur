---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
target_branch: develop
---

# feat: Global aiur pause switch - Plan

**Product Contract preservation:** unchanged — planning enriched the HOW only.

---

## Goal Capsule

- **Objective:** Give an operator one master switch that pauses an entire aiur run — halting all agents and preventing new agent provisioning — as a state distinct from, and non-destructive to, per-agent pause.
- **Product authority:** Issue [#1332](https://github.com/its-everdred/aiur/issues/1332); requirements settled by the issue author (away — synthesized, no open product questions).
- **Open blockers:** None. Target branch: `develop`.

---

## Product Contract

### Problem
Pause is per-agent only today (`control.status == :paused` on each running entry, via `Aiur.Orchestrator.PauseResume`). There is no single control to hold an entire run — stop everything now, and stop new work from starting — without hand-pausing each agent and without cleanly restoring the prior state afterward. Operators also cannot cold-start a run held so they can inspect a backlog before any agent touches it.

### Primary actor
The human operator (Executor) driving a run via the CLI and/or the dashboard.

### Core outcome
A single **global pause** state, owned by the orchestrator and separate from per-agent pause, that behaves as one switch: ON overrides and pauses everything; OFF defers entirely to each agent's own pause setting.

### In scope
- **Global pause state** — a dedicated daemon-level flag, distinct from per-agent `control.status`, single source of truth in the orchestrator, exposed and controllable from every interface below.
- **Pause (ON):** pause all currently running agents; stop provisioning — no new agent starts even when `agent:todo` tickets are ready.
- **Unpause (OFF):** resume exactly the agents that global pause halted (those not individually paused); provisioning resumes.
- **Non-override guarantee:** global pause never mutates per-agent pause state. An agent individually paused — before or during global pause — stays paused through a pause→unpause cycle. Global unpause only lifts the hold global pause itself applied.
- **CLI `--pause` launch flag:** cold-start globally paused; agents are **never spun up** even with `agent:todo` tickets, until unpaused.
- **CLI live control:** pause/unpause a running daemon.
- **TUI toggle:** a global-pause toggle in the dashboard nav; writable-gated.
- **Visibility:** paused state legible in nav, per-agent waiting reason, and daemon status.

### Out of scope
- Persisting global pause across a full daemon restart (`--pause` is the cold-start control; restart without it starts unpaused).
- Scheduling / auto-pause. Pausing anything beyond agent dispatch + running agents (dashboard/polling/telemetry keep running). Changing `max-agents`.

### Key decisions
- **Separate override layer**, not a bulk write over per-agent `control.status`. On pause, record which running agents *it* halted (only those not already individually paused); on unpause, resume exactly that set minus any individually paused meanwhile.
- **Dispatch gate:** while paused, provisioning short-circuits regardless of `max-agents` / ready tickets.
- **Single source of truth:** orchestrator owns the flag; CLI + TUI are control surfaces + projections, using the existing control-API pattern.
- **Idempotent switch:** pause-when-paused / unpause-when-unpaused is a no-op.
- **(session-settled: agent-decided, user away) Individual-resume-while-globally-paused → global-hold-wins.** Resuming one agent while globally paused does not start it; the resume takes effect on global unpause. Keeps "one switch holds everything" honest.
- **(session-settled: agent-decided, user away) CLI verb = `aiur pause` / `aiur resume` with no positional target = global**; `aiur pause <id>` remains the existing per-agent path. Matches issue wording and the existing command style.

### Success criteria (each verified end-to-end)
1. `--pause` cold start with pending `agent:todo` → zero agents provisioned; status shows globally paused.
2. Live pause with N running agents (none individually paused) → all N halted; no new dispatch.
3. Live unpause → all N resume; dispatch resumes.
4. Non-override: individually pause one, then global pause+unpause → that one stays paused; the rest resume.
5. Individually-paused-during-hold: pause an agent while globally paused → stays paused after unpause.
6. Distinctness: global and per-agent pause are independently observable.
7. All three interfaces drive the same single state consistently.

### Edge cases
- Toggle spam / concurrent pause+unpause: idempotent, last-writer-wins.
- Agent finishing while paused: completes/teardowns normally, not replaced until unpause.
- Read-only dashboard: toggle hidden/disabled; state still visible.

---

## Planning Contract

### Architecture (HOW)
Global pause is one boolean on `Orchestrator.State` plus a bookkeeping set of "agents this switch is holding." The **dispatch gate** and the **run-agent hold** both consult the boolean; the bookkeeping set makes unpause restore exactly what pause took, so per-agent pause is never touched.

```
                      ┌─────────────────────────── Aiur.Orchestrator (GenServer) ──────────────┐
CLI --pause ─────────▶│ init: State.globally_paused? ⟵ Config (start_paused)                   │
aiur pause/resume ───▶│ handle_call {:set_global_pause, bool} ─▶ GlobalPause.apply/2           │
TUI nav toggle ──────▶│   • ON:  hold every running agent whose control.status ≠ :paused,      │
(control_api_call)    │         record ids in State.globally_held                              │
                      │   • OFF: resume exactly globally_held ∖ {now individually paused}      │
                      │   • notify_dashboard(state)                                            │
                      │ Dispatcher.dispatch_or_hold / Slots.available_slots ── returns 0 slots │
                      │   when globally_paused  ⇒ no provisioning even with agent:todo         │
                      └────────────────────────────────────────────────────────────────────────┘
```

### Files & patterns to mirror
- `lib/aiur/orchestrator/state.ex` — add fields; mirror existing `defstruct` + `@type t`.
- `lib/aiur/orchestrator/slots.ex` — mirror `set_max_concurrent_agents` / `apply_session_max_concurrent_agents` / `control_api_call` for the new control API + `notify_dashboard`.
- `lib/aiur/orchestrator/dispatcher.ex` — `dispatch_or_hold/2`, and `Slots.available_slots/1` (dispatcher.ex:608) as the gate.
- `lib/aiur/orchestrator/pause_resume.ex` — reuse its running-agent hold/interrupt path; do not overload per-agent `control.status` for the global hold.
- `lib/aiur/cli.ex` — `@switches` (line 17) + `maybe_set_max_agents`/`maybe_set_headless` appliers (line 153); add `pause: :boolean` + `maybe_set_pause`.
- `lib/aiur/agent_control_cli.ex` — `pause/1`,`resume/1` (targeted, line 359); add no-target global variants + `status/0` surfacing.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` — subcommand dispatch for `pause`/`resume`.
- `lib/aiur_web/live/dashboard_live.ex` — writable-gated `handle_event` (`toggle-nav` at 267, `request-unit-control` at 344, `dashboard_writable?` at 788) as the toggle pattern.
- `lib/aiur_web/components/operator_control_center/dashboard_shell.ex` — nav; place the toggle near the theme/nav toggles in `.brand-row`.
- `lib/aiur/orchestrator/waiting_reason.ex` — add a `:run_paused` reason.

---

## Implementation Units

### U1. Global pause state on the orchestrator
- **Goal:** Add the single source of truth: a `globally_paused` boolean and a `globally_held` set on `State`, initialized from config so `--pause` cold-starts paused.
- **Requirements:** In-scope "Global pause state"; success #1.
- **Dependencies:** none.
- **Files:** `lib/aiur/orchestrator/state.ex`, `lib/aiur/orchestrator.ex` (init reads config), `lib/aiur/config/*` (a `start_paused`/global-pause setting or `Application` env), `src/test/aiur/orchestrator/state_test.exs`.
- **Approach:** Add `globally_paused: false` and `globally_held: MapSet.new()` to `defstruct` + `@type t`. On orchestrator init, seed `globally_paused` from the config/env the CLI sets (U4). Keep it out of any per-agent structures.
- **Test scenarios:** default state is unpaused with empty held-set; init with the paused config → `globally_paused: true`; struct round-trips the new fields.

### U2. Gate provisioning on global pause
- **Goal:** While globally paused, never provision new agents — even with ready `agent:todo` tickets.
- **Requirements:** In-scope "stop provisioning"; success #1, #2.
- **Dependencies:** U1.
- **Files:** `lib/aiur/orchestrator/dispatcher.ex`, `lib/aiur/orchestrator/slots.ex`, `src/test/aiur/orchestrator/dispatcher_test.exs`.
- **Approach:** Short-circuit `dispatch_or_hold/2` (or make `Slots.available_slots/1` return 0) when `state.globally_paused`, independent of `max-agents`. Todo tickets remain queued/observed; none are dispatched. `max-agents` value is untouched.
- **Test scenarios:** paused + N ready todo tickets → zero dispatches, tickets still tracked; unpaused → dispatch resumes up to slots; global pause does not mutate `session_max_concurrent_agents`. Covers AE1.

### U3. Pause/resume-all with the non-override guarantee
- **Goal:** The control handler that flips the switch: on pause, hold all running agents not individually paused (record ids); on unpause, resume exactly those, minus any individually paused meanwhile.
- **Requirements:** In-scope pause/unpause + non-override; success #2–#5.
- **Dependencies:** U1, U2.
- **Files:** `lib/aiur/orchestrator/global_pause.ex` (new; mirrors `slots.ex` control shape), `lib/aiur/orchestrator.ex` (`handle_call({:set_global_pause, bool}, …)` + public `set_global_pause/1,2`), `lib/aiur/orchestrator/pause_resume.ex` (reuse hold path), `src/test/aiur/orchestrator/global_pause_test.exs`.
- **Approach:** `apply(state, true)`: for each running entry whose `control.status != :paused`, hold it via the existing pause/interrupt path and add its id to `globally_held`; set `globally_paused: true`; `notify_dashboard`. `apply(state, false)`: resume each id in `globally_held` that is not now individually paused; clear the set; set `globally_paused: false`; `notify_dashboard`. Idempotent for repeat calls. **Global-hold-wins:** while paused, an individual `resume` records intent but does not start the agent (the agent stays held until global unpause).
- **Execution note:** implement the non-override + global-hold-wins behavior test-first — these are the load-bearing invariants.
- **Test scenarios:** pause holds all non-paused agents and records them; unpause resumes exactly the held set; an individually-paused agent is neither held nor resumed (stays paused) — covers success #4; pausing an agent individually while globally paused keeps it paused after unpause — covers success #5; idempotent double-pause / double-unpause is a no-op; individual resume while globally paused does not start the agent. Covers AE2, AE3.

### U4. CLI `--pause` launch flag
- **Goal:** `aiur --pause` cold-starts the daemon globally paused so no agent is provisioned until unpaused.
- **Requirements:** In-scope `--pause`; success #1.
- **Dependencies:** U1.
- **Files:** `lib/aiur/cli.ex`, `src/test/aiur/cli_test.exs`, update usage string.
- **Approach:** Add `pause: :boolean` to `@switches`; add `maybe_set_pause(opts)` alongside `maybe_set_max_agents` that writes the config/env U1 reads at init. Add `--pause` to the usage line.
- **Test scenarios:** `--pause` parses and sets the paused config; absent flag leaves default unpaused; usage string lists `--pause`. Covers AE1.

### U5. CLI live pause/resume (global)
- **Goal:** `aiur pause` / `aiur resume` (no positional target) flip the global switch on a running daemon.
- **Requirements:** In-scope CLI live control; success #2, #3, #7.
- **Dependencies:** U3.
- **Files:** `lib/aiur/agent_control_cli.ex`, `packaging/npm/aiur-cli/libexec/aiur-engine.sh`, `src/test/aiur/agent_control_cli_test.exs`.
- **Approach:** When `pause`/`resume` are invoked with no target, call `Orchestrator.set_global_pause(true/false)`; with a target, keep the existing per-agent path. Surface global-paused in `status`. Ensure the engine dispatches `pause`/`resume` as control commands (they already reach `agent_control_cli`).
- **Test scenarios:** no-target `pause` flips global on and reports; no-target `resume` flips off; targeted `pause <id>` still pauses one agent (unchanged); `status` shows global-paused; unavailable daemon returns a clean error. Covers AE2, AE3.

### U6. Dashboard nav toggle (TUI)
- **Goal:** A writable-gated global-pause toggle in the dashboard nav reflecting and flipping the state.
- **Requirements:** In-scope TUI toggle; success #6, #7.
- **Dependencies:** U3.
- **Files:** `lib/aiur_web/components/operator_control_center/dashboard_shell.ex`, `lib/aiur_web/live/dashboard_live.ex`, `lib/aiur_web/operator_control_center/*presenter*` (surface `globally_paused` into the payload), `src/priv/static/dashboard.css`, `src/test/aiur_web/live/dashboard_live_test.exs`.
- **Approach:** Add the paused flag to the dashboard payload/projection. Render a toggle in `.brand-row` (near theme/nav toggles); `aria-pressed` reflects state. Add `handle_event("toggle-global-pause", …)` gated by `dashboard_writable?()` that calls the U3 control API and reloads. In read-only, hide/disable the control but keep the state visible (a banner/badge).
- **Test scenarios:** writable dashboard renders the toggle reflecting current state; clicking flips global pause and re-renders; read-only hides the control but shows paused state; the toggle is independent of per-agent pause chips (success #6). Covers AE2.

### U7. Visibility: status + waiting reason
- **Goal:** Make the paused state legible — daemon status and a distinct per-agent waiting reason for agents the global switch is holding.
- **Requirements:** In-scope visibility; success #6.
- **Dependencies:** U3.
- **Files:** `lib/aiur/orchestrator/waiting_reason.ex`, the status/fleet projection surfacing waiting reasons, `src/test/aiur/orchestrator/waiting_reason_test.exs`.
- **Approach:** Add a `:run_paused` (or similarly named) waiting reason distinct from individual pause; agents held by the global switch report it; status/fleet render it. Individually-paused agents keep their own reason.
- **Test scenarios:** a globally-held agent reports the run-paused reason; an individually-paused agent keeps its own reason; status reflects global-paused. Covers success #6.

---

## Verification Contract
- `cd src && mise exec -- mix test` green (new unit tests for U1–U7).
- `mix compile --warnings-as-errors` clean; `mix credo --strict` clean on changed files.
- Manual/e2e per Success Criteria: `--pause` cold-start no-provision; live pause/resume via CLI and TUI; the non-override + global-hold-wins invariants (success #4, #5).

## Acceptance Examples
- **AE1:** Launch `aiur --pause` with an `agent:todo` ticket present → after a poll cycle, zero agents running; status = globally paused.
- **AE2:** Two agents running (none paused) → `aiur pause` (or TUI toggle) → both held, no new dispatch; individually pause a third-party agent A first, then global pause → A still shows individual pause, others show run-paused.
- **AE3:** From AE2's global-paused state → `aiur resume` → the globally-held agents resume; A (individually paused) stays paused.

## Definition of Done
- U1–U7 implemented with their test scenarios passing; all three interfaces drive one shared state.
- Non-override and global-hold-wins invariants covered by tests.
- Verification Contract gates green.
- PR opened against **develop**.
