# PSO-015 — Mid-run move of an agent to and from Paseo (`p` key) (optional)

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — a second instance of the existing Remote Control promote/demote flow, plus one dashboard route

**Risk:** medium

**Phase hint:** 5

**Depends on:** PSO-003, PSO-012

**Serializes with:** PSO-003 — both touch `src/lib/aiur/orchestrator/status_report.ex` and the agent-list summaries; rebase onto PSO-003

**External gates:** none

**Requirements:** R5, R10, R12

**Decisions:** DEC-005, DEC-012, DEC-015

**Design evidence:** 00-design.md sections 5, 8; 01-spike-report.md sections 4, 9

**Researched at:** aiur `8199f5373`, paseo `726067b4`, aiur-claude 1.1.0

**Suggested labels:** `complexity:3`, `model:claude`, `phase:5`, `build-lane:paseo-integration`; never `agent:todo`

## Outcome

Pressing `p` on a running local Claude or Codex agent moves it onto the Paseo pipeline: the issue gains the `model:paseo-<family>` label, the current session is torn down with the workspace kept, and the re-dispatched agent is Paseo-owned and visible on the phone with 📱 Paseo. Pressing `p` again moves it back: the label swaps to the plain family, the Paseo agent is archived, and the plain backend resumes by cwd (Claude) or thread id (Codex). Because Paseo-owned agents have no handoff, the TUI, dashboard, and phone all keep working after either move. The dashboard exposes the same toggle when writable.

## Context and evidence

The Remote Control toggle is the template. `Aiur.AgentList.Input` dispatches `"r"` to `App.toggle_remote_control/1` (`src/lib/aiur/agent_list/input.ex` line 108). `Aiur.AgentList.Controls.toggle_remote_control/1` (`controls.ex` lines 23-70) reads the selected summary, computes `desired = not Summaries.remote_control_on?(summary)`, and calls `Orchestrator.set_remote_control(orchestrator, identifier, desired)`; a non-running row gets `rc_hint/2`. `Aiur.Orchestrator.RemoteControlMode.set_remote_control_reply/4` (`remote_control_mode.ex` lines 55-66) finds the running entry and calls `promote_to_remote/3` or `demote_from_remote/3`. Promotion adds the durable label, then `teardown_for_redispatch/3` (lines 245-270) kills the REPL session, closes chat streams, demonitors, terminates the task, and keeps the entry in `state.running` with `pid`/`ref` cleared so the workspace and claim survive; the next dispatch resolves the new backend. `add_issue_label/2` and its sibling remove helper live in the same module. `remote_control_summary/1` (lines 319-330) is how the 📱 state reaches `status_report.ex` (`remote_control:` at line 938) and `rc_pane_borders.ex`.

Backend selection reads `model:<backend>` labels through `Aiur.CodingAgent.backend_for/1` (`coding_agent.ex` line 713) against `dispatchable_backends/1` (line 340); a `paseo-*` twin is only selectable when `agent.backend_configs.paseo-<family>.enabled` is true (DEC-002). The sidecar re-attaches by `aiur_issue` label and cwd (DEC-005, PSO-011), so a second promote after a demote finds the archived agent gone and creates a new one.

Dashboard write routes for pause and resume are `post("/api/v1/:issue_identifier/pause")` and `.../resume` under `pipe_through([:dashboard_auth, :api_write, :require_writable])` (`src/lib/aiur_web/router.ex` lines 156-166), handled by `AiurWeb.ObservabilityApiController`.

## Scope

- `Aiur.AgentList.Input`: `dispatch("p", target, _)` → `App.toggle_paseo(target)`.
- `Aiur.AgentList.Controls.toggle_paseo/1`: selected running summary → `desired = not Summaries.paseo_on?(summary)` (from PSO-003's `surface.kind == "paseo"`) → `Orchestrator.set_paseo(orchestrator, identifier, desired)`; non-running or RC-on rows get a hint ("Paseo move needs a running local agent"; "Leave Remote Control first").
- `Aiur.Orchestrator.PaseoMode` (new, `src/lib/aiur/orchestrator/paseo_mode.ex`): `set_paseo/3` control call, `set_paseo_call/3`, `set_paseo_reply/4`, `promote/3`, `demote/3`, `paseo_twin/1` (`"claude" → "paseo-claude"`, `"codex" → "paseo-codex"`, `"claude-repl" → "paseo-claude"`), and the guard `movable?/2`.
- `promote/3`: guard (`worker_host` nil; twin in `dispatchable_backends(Config.agent_backend_configs())`; not RC-on); swap labels: remove any `model:<family>` and `model:<family>-<variant>` override, add `model:paseo-<family>`, keep `complexity:*`, effort, and other labels; write the label to the tracker through the same helper RC uses; `teardown_for_redispatch(state, entry, :paseo_move)`; the entry's `issue` is updated with the new labels so re-dispatch resolves the twin. Reply `{:ok, :on}`.
- `demote/3`: swap `model:paseo-<family>` back to `model:<family>` (or remove it when the issue had no override before the promote; record the prior override on the running entry as `paseo_prior_override`), call `CodingAgent.stop_session/1` on the current session so the sidecar archives the Paseo agent (DEC-008 `close`), `teardown_for_redispatch(state, entry, :paseo_move)`. Reply `{:ok, :off}`.
- Status report: no new field; PSO-003's `surface:` already reflects the Paseo state after re-dispatch. Add `Summaries.paseo_on?/1`.
- Dashboard: `post("/api/v1/:issue_identifier/paseo")` with body `{"on": true|false}` in the writable scope, handler `ObservabilityApiController.set_paseo/2` calling `Orchestrator.set_paseo/3`, plus `match(:*, ...)` method-not-allowed like the siblings. A toggle button on the agent row in `dashboard_live.ex` when `observability.dashboard_writable`.
- Help overlay (`?`) and `website/docs-app/guide/tui.md` key table gain `p`; `reference/cli.md` and `apis/` page gain the route.

## Non-goals

- Moving remote-worker agents (`worker_host` set) or RC-on agents.
- Preserving in-flight turn state across the move; the re-dispatched agent starts a new turn with the resume prompt, as RC does.
- A global "move everything" command.

## Existing owner and reuse target

`Aiur.Orchestrator.RemoteControlMode` is the pattern and its `teardown_for_redispatch/3`, `add_issue_label/2`, and label-removal helpers are reused. `Aiur.AgentList.Controls` and `Input` gain one key. `AiurWeb.ObservabilityApiController` gains one action mirroring `pause/2`.

## Contract and invariants

- A move never cleans the workspace or releases the claim.
- After a promote, exactly one `model:*` backend override label remains on the issue and it names the Paseo twin; after a demote, the labels equal the pre-promote set.
- `p` on a Paseo-owned agent whose twin was disabled since dispatch still demotes (demote never needs the twin).
- The 📱 indicator is derived from the live session's `surface`, never from the label.

### Requirements

- PSO-015-R1. `p` promotes a running local agent to its Paseo twin with the workspace kept.
- PSO-015-R2. `p` on a Paseo-owned agent demotes it to the plain family backend, archiving the Paseo agent.
- PSO-015-R3. The guard refuses remote workers, RC-on agents, and disabled twins with a TUI hint and an `{:error, reason}` reply.
- PSO-015-R4. The dashboard route performs the same toggle under the writable gate.
- PSO-015-R5. Labels are swapped durably on the tracker and restored on demote.

## Refreshable implementation notes

- Reuse `RemoteControlMode.teardown_for_redispatch/3` with reason `:paseo_move` so chat-stream close broadcasts carry the true cause.
- Look at how `RemoteControlMode.promote_to_remote/3` writes the label to GitHub (the tracker label call and its failure handling) and copy the ordering: label first, teardown second, so a label failure leaves the agent running.
- Store `paseo_prior_override` on the running entry map; `State.find_running_by_identifier/2` returns the map to update.
- Codex demote resumes by thread id from `SessionHandle` only if the handle still names the `codex` backend; after a Paseo stint the handle names `paseo-codex`, so demote clears it and the plain backend cold-starts. Document this in the docs page; it matches the RC behaviour.

### Key technical decisions

- Label-driven re-dispatch instead of an in-place transport swap: it reuses every existing lifecycle path and makes the move durable across an aiur restart.
- Demote archives rather than kills the Paseo agent so the conversation stays readable in the app.

## Acceptance and verification

### Agent gate

- `test/aiur/agent_list/controls_test.exs`: `p` on a running plain agent calls `set_paseo(.., true)`; on a Paseo agent calls `set_paseo(.., false)`; on RC-on or non-running rows shows the hint and makes no call.
- `test/aiur/orchestrator/paseo_mode_test.exs`: promote swaps `model:claude-opus` to `model:paseo-claude` keeping `complexity:3`; demote restores `model:claude-opus`; promote with no prior override then demote leaves no `model:*`; guard cases (worker_host, RC-on, twin disabled) return `{:error, reason}` and leave state untouched; teardown keeps `state.running[issue_id]` with `pid: nil`; `stop_session` is invoked on demote.
- `test/aiur_web/controllers/observability_api_controller_test.exs`: route requires auth and writable mode; `{"on": true}` calls the orchestrator; wrong method is 405.
- Status report test: after promote and re-dispatch with a fake sidecar, `surface.kind == "paseo"` and `Summaries.paseo_on?/1` is true.
- `make all`, `mix specs.check`, docs check.

### At-merge gate

- CI green on the exact head; docs updated in the same PR.

### Human/manual evidence

- `scripts/aiurdev --test --force --allow-remote` with the real daemon: press `p` on a running Claude agent; 📱 Paseo appears within one dispatch cycle and the agent shows in the Paseo app; send a phone message and see it in the pane; press `p` again; 📱 clears, the plain agent continues, and the Paseo app shows the agent archived. Repeat from the dashboard button. Attach a short screen recording or screenshots to the PR.

## Failure, security, migration, and accessibility cases

- If the tracker label write fails, reply `{:error, {:label_write_failed, reason}}` and do not tear down.
- If re-dispatch of the twin fails to start (daemon down), the existing `fallback_backend` path returns the agent to the plain backend; the label is left as `model:paseo-<family>` and an attention names it, matching RC's degrade behaviour.
- The dashboard button is keyboard reachable and labelled "Move to Paseo" / "Move back from Paseo".

## Surfaces

- Reads: running entry, issue labels, `dispatchable_backends`, session `surface`.
- Writes: tracker labels, `state.running`, `POST /api/v1/:issue_identifier/paseo`, TUI help, docs.
- Contracts: `Orchestrator.set_paseo/3` reply `{:ok, :on | :off} | {:error, term()}`.

## Sibling boundaries and open gates

PSO-003 owns the surface indicator this key reads. PSO-011 owns the sidecar's re-attach that makes repeated promotes safe. PSO-012's proof is the base. Optional: the build order completes without it.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
