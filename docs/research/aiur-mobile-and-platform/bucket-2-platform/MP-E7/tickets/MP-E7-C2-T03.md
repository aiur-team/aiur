---
ticket_id: MP-E7-C2-T03
feature_id: MP-E7
chunk_id: MP-E7-C2
bucket: 2-platform
title: "Internal listener control API (get/set mode through the Orchestrator); no HTTP, CLI or snapshot field"
status: ready
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C2-T01, MP-E7-C2-T02]
prior_units: [U2, U6]
prior_boundaries: [MSG (16), CTL]
prior_features: [integrations-43]
prior_findings: []
size_owner: LIFECYCLE_DISPATCH (orchestrator.ex 1,003 lines: +6 lines of delegating handle_call clauses only; logic in a new module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C2-T03 — Internal listener control API

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C2.
- **User value (wave 3):** none visible. It gives MP-E3-C5, MP-E4-C6 and the
  later surfaces (MP-E7-C7) one serialized, conflict-safe way to read and set
  an agent's mode.
- **Deliverable:**
  - `Aiur.Listener` facade (PROPOSED `src/lib/aiur/listener.ex`):
    `get_mode(target)` and `set_mode(target, mode, opts)` with
    `opts[:expected_version]` (required), `opts[:actor]` (`:human | :executor | :system`),
    `opts[:idempotency_key]`. Both return the `Effective` view (MP-E7-C2-T02).
  - `Aiur.Orchestrator.ListenerModes` (PROPOSED
    `src/lib/aiur/orchestrator/listener_modes.ex`): the GenServer-side
    handlers; reads `ModeStore`, calls `Capabilities.harness_delivery/3`
    (MP-R7-C2-T03) and `Effective.compute/2`.
  - Two `handle_call` clauses in `src/lib/aiur/orchestrator.ex` that delegate
    (`{:listener_get_mode, id}`, `{:listener_set_mode, id, mode, opts}`).
  - **Edge direction (RC-36, Phase D).** `Aiur.Listener` is required core
    (component `listener-modes`) and must not reference `Aiur.Orchestrator`.
    This ticket creates the behaviour `Aiur.Listener.DeliveryTarget`
    (PROPOSED `src/lib/aiur/listener/delivery_target.ex`) with callbacks
    `get_mode/1` and `set_mode/3`; `Aiur.Orchestrator.ListenerDeliveryTarget`
    implements them by issuing the two `handle_call`s, and is registered at
    the composition root (`config :aiur, :listener_delivery_target`). The
    facade calls the registered module. MP-E7-C3-T03 adds `enqueue/3`.
- **Non-goals (moved to MP-E7-C7, fork D):** the CLI command, `POST
  /api/v1/:id/listen-mode`, and the `listener` field in
  `issue_control_capabilities` — their names and placement come from
  DESIGN-E7 §1.5/§1.1. No authorization policy for `:executor` (E7-D3); the
  actor is recorded, and the surface tickets enforce who may call.

## Dependencies and blockers

- DESIGN-E7; MP-E7-C2-T01 (store); MP-E7-C2-T02 (effective).
- Successors: MP-E7-C2-T04, MP-E7-C3-T02 (reads the view at enqueue),
  MP-E7-C7 surfaces, MP-E3-C5-T01, MP-E4-C6-T03.
- Concurrent with MP-E7-C3-T01.

## Verified starting point (aiur `45a290e3`)

- **Why no field in the control map in wave 3:** `issue_control_capabilities/3`
  (`orchestrator/operator_messages/capabilities.ex:42-64`) is stored as
  `control:` in every running snapshot (`orchestrator/status_report.ex:471,516,1026,1058`)
  and serialized verbatim as `capabilities` in the HTTP JSON
  (`aiur_web/presenter.ex:286,323,452`), served by `GET /api/v1/state` and
  `GET /api/v1/:id` (`aiur_web/controllers/observability_api_controller.ex:18,28`).
  Adding a key there is a public API change, so it belongs to MP-E7-C7 with
  DESIGN-E7 approval. The dashboard reads the same map through
  `AgentChat.capabilities/1` (`aiur_web/live/dashboard_live.ex:2807`).
- Control-call pattern to copy: `OperatorMessages.control_api_call/3`
  (`orchestrator/operator_messages.ex:1088-1097`) maps a dead server to
  `{:error, :unavailable}` and a timeout to `{:error, :timeout}`;
  `orchestrator.ex:726-734` shows delegating `handle_call` clauses.
- Ambiguous identity handling: `State.find_unique_running_by_identity/2`
  (`operator_messages.ex:321-326`) for `%TrackerIdentity{}` targets.

## Chosen design

- **Target:** a ticket identifier string or `%TrackerIdentity{}` (same as
  `AgentChat.send/3`, `agent_chat.ex:16-20`). A mode can be read and set for a
  ticket with **no running agent** (DESIGN-E7 §3 "Agent not running: mode kept
  for the ticket"): the view then has `effective: nil, effective_reason: :not_running`.
- **Timeouts:** `set_mode` uses the operator-message timeout
  (`operator_message_call_timeout_ms/0`, `operator_messages.ex:110-112`). A
  timeout returns `{:error, {:outcome_unknown, %{idempotency_key: k}}}`, never
  a failure (#2717 pattern, `agent_chat.ex:51-55`); a retry with the same key
  is safe because `ModeStore.put/5` is idempotent by key.
- **Returns:** `{:ok, view}`, `{:error, {:mode_conflict, view}}` (current
  record, for the 409 that C7 renders), `{:error, :invalid_mode}`,
  `{:error, :unavailable | {:outcome_unknown, map()}}`.
- **Audit:** every successful set logs one `Logger.info` line
  `listener_mode_set issue=… requested=… effective=… version=… actor=…`
  (no message text; contract §12).
- The handler returns `{:reply, reply, state}` and does **not** touch
  `state.queue_store`; re-stamping pending items on a mode change is
  MP-E7-C3-T01/T02.

## Implementation steps

1. Add `listener.ex` (facade, ~60 lines) and `orchestrator/listener_modes.ex` (~90 lines).
2. Add two delegating clauses to `orchestrator.ex` next to `:control_capabilities` (:732-734).
3. Tests: `src/test/aiur/listener_test.exs` against a test Orchestrator (pattern in `src/test/aiur/orchestrator/operator_messages/message_status_test.exs`).

## Non-happy paths

- Orchestrator down → `{:error, :unavailable}`.
- Concurrent writers (two dashboards, later two phones) → one wins, the other
  gets `{:error, {:mode_conflict, view}}` with the winner.
- Ambiguous `%TrackerIdentity{}` → `{:error, reason}` from the unique lookup.
- Store write failure → `{:error, {:write_failed, _}}`; record unchanged.

## Compatibility and rollout

- Internal API only; no route, CLI or rendered string changes, so
  `scripts/check-config-docs.py` and the docs table in AGENTS.md "Docs ship
  with the change" are not triggered. Rollback: revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener_test.exs test/aiur/orchestrator/operator_messages/capabilities_test.exs
env -C src mise exec -- make lint
```

Tests (`Aiur.ListenerTest`):

- "get_mode for a running codex agent returns requested sync, effective sync, version 0".
- "set_mode with the current version persists and bumps the version".
- "set_mode with a stale version returns mode_conflict with the winning record".
- "set_mode for a ticket with no running agent persists and reports effective nil not_running".
- "set_mode retry with the same idempotency key does not bump the version".
- Guard (already passes; regression guard, named as such): "control capabilities map has no listener key" — asserts the exact key set of `issue_control_capabilities/3` is unchanged (`capabilities_test.exs:11-21` style).

Mutation checks: bypass `ModeStore.put/5` CAS in the handler (always write) →
the stale-version test fails; make the handler return `effective: :sync` when
not running → the not-running test fails.

## Completion and handoff

- [ ] Facade, handler module and two delegating clauses merged.
- [ ] No change to `/api/v1/state` JSON (guard test green).
- Dependents: MP-E7-C2-T04, MP-E7-C3-T02, MP-E7-C7 (CLI, HTTP, snapshot field), MP-E3-C5-T01, MP-E4-C6-T03.
- Docs: none in wave 3.
