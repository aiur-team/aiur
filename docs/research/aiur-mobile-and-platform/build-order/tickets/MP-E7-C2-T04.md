---
ticket_id: MP-E7-C2-T04
feature_id: MP-E7
chunk_id: MP-E7-C2
bucket: 2-platform
title: "Recompute effective mode and control flags from the running backend on transport change; broadcast in-process"
status: ready
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C2-T03]
prior_units: [U2, U4]
prior_boundaries: [MSG (16), RUN (18)]
prior_features: [integrations-43]
prior_findings: []
size_owner: LIFECYCLE_DISPATCH (orchestrator/state.ex 1,033 lines: one call added in put_session_execution/4; logic in orchestrator/listener_modes.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C2-T04 — Recompute on transport change; in-process change signal

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C2.
- **User value:** when an agent's transport changes under it (the
  `claude-repl` start fails over to headless `claude`, or Remote Control
  promotion moves it the other way), its effective mode follows the transport
  actually running, and anyone watching learns about it (contract §4 last rule).
- **Deliverable:**
  1. `Aiur.Orchestrator.ListenerModes.on_session_execution/3` (in the C2-T03
     module): recompute the view when `session_execution.backend` is set or
     changes; if `effective` or `effective_reason` changed, record it in the
     running entry under `:listener_effective` and broadcast.
  2. `Aiur.AgentPubSub.subscribe_listen_mode/1` and
     `broadcast_listen_mode/2` on a **new dedicated topic**
     `"listen_mode:" <> identifier` (PROPOSED; topic helper in
     `Aiur.AgentEvents`), payload
     `{:listen_mode_changed, identifier, %{requested, effective, effective_reason, version, actor}}`.
  3. `set_mode` (C2-T03) also broadcasts with the human/executor actor.
  4. **Refresh `running_entry.control` delivery flags from the running
     backend** (owner of MP-R7 finding R7-C1-F1): when
     `session_execution.backend` differs from the dispatched backend, rewrite
     `control.can_interrupt`, `control.safe_checkpoints`,
     `control.immediate_delivery` and `control.application_confirmation` with
     the same `CodingAgent` lookups `default_running_control/2` uses
     (`dispatcher.ex:2660-2672`), keeping `generation`, `version`, `status`.
     This is a bug fix restoring documented behaviour: today, after a failed
     `claude-repl` start falls back to headless `claude`, the stale
     `immediate_delivery: true` makes a TUI `:auto` message normalize to
     `:immediate` (`delivery_policy.ex:14-16`) and then to a hard interrupt.
- **Non-goals:** the exported bus topic `ticket.<id>.agent.listen-mode.changed`
  (moved to MP-E7-C2-T05, wave 4, because MP-R2-C5 registers it and RC-09
  schedules that catalog just before its first consumer); no UI.

## Dependencies and blockers

- DESIGN-E7, MP-E7-C2-T03.
- Concurrent with MP-E7-C3-T01..T03.

## Verified starting point (aiur `45a290e3`)

- The running transport fact arrives as
  `{:session_execution_info, issue_id, %{backend: …}}`
  (`agent_runner/session_lifecycle.ex:33-47`) →
  `orchestrator.ex:135-137` → `State.handle_session_execution_info/3`
  (`orchestrator/state.ex:441-461`) → `put_session_execution/4`
  (`state.ex:487-493`), which already calls `StatusReport.notify_dashboard/1`.
- Fallback start: `SessionLifecycle.start_agent_session/3`
  (`session_lifecycle.ex:939-985`) tags the session with the fallback backend
  (`tag_session/3`, :981); RC promotion is tagged at :661 (per MP-R7-C2-T03).
- `running_entry.control` is set once at dispatch
  (`dispatcher.ex:2549` `control: default_running_control(...)`, :2659-2672)
  from the *requested* backend and is never refreshed after fallback or RC
  promotion (MP-R7 finding R7-C1-F1, pinned by the MP-R7-C1 characterization
  suite as current behaviour). Deliverable 4 fixes it; the R7-C1 pin for that
  row is updated in the same PR and named as an intended change.
- **Do not broadcast on the existing agent topic.**
  `AgentPubSub.subscribe_agent/1` (`agent_pubsub.ex:18-24`) is consumed by the
  OpenCode chat bridge, which streams what it receives into the chat pane
  (`agent_pubsub.ex:26-36` moduledoc on stacked subscriptions); an unexpected
  message there is a rendering risk. A new topic has no subscriber in wave 3.

## Chosen design

- Trigger points: (a) `put_session_execution/4` after the entry update;
  (b) `ListenerModes.set_mode` success; (c) dispatch of a new running entry
  (initial view with `harness_source: :dispatch`, no broadcast unless a
  subscriber exists — broadcasting is cheap, so always broadcast for
  simplicity).
- Actor for (a) and (c) is `:system` (contract non-happy path "Transport
  change … actor: system").
- Idempotent: recompute that yields the same `{effective, effective_reason}`
  broadcasts nothing.
- The stored mode record is **not** written on a transport change; only the
  derived view changes (requested stays the operator's choice).

## Implementation steps

1. Add `on_session_execution/3` to `orchestrator/listener_modes.ex`.
2. In `state.ex` `put_session_execution/4`, pipe the updated state through it (one line + alias).
3. Add the topic helper to `agent_events.ex` and the two functions to `agent_pubsub.ex` with the existing `Process.whereis` guard pattern (moduledoc :1-10).
4. Tests.

## Non-happy paths

- Unknown backend label (`session_lifecycle.ex:1123` `@unknown_backend`):
  `harness_delivery/3` returns `primitives: :unknown`, the view goes to
  `effective: nil, effective_reason: :harness_unknown`, and that is broadcast
  — never a guessed profile.
- PubSub not started (early boot, some tests): broadcast is a no-op, like
  every `AgentPubSub` producer.
- Pending items when effective changes: re-stamping is MP-E7-C3-T02's job;
  this ticket only signals.

## Compatibility and rollout

- New PubSub topic, no subscriber; no snapshot or HTTP change. Rollback: revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/orchestrator/listener_modes_test.exs test/aiur/orchestrator/state_test.exs
```

Tests (`Aiur.Orchestrator.ListenerModesTest`):

- "fallback from claude-repl to claude recomputes effective and broadcasts with actor system": seed a running entry dispatched as `claude-repl`, deliver `{:session_execution_info, id, %{backend: "claude"}}`, assert one `{:listen_mode_changed, id, %{actor: :system}}` and that `requested` is unchanged.
- "same backend reported twice broadcasts once".
- "unknown backend label yields effective nil harness_unknown" (unknown-path rule).
- "set_mode broadcasts with the caller's actor".
- "fallback from claude-repl to claude rewrites control flags": after the fallback report, `issue_control_capabilities/3` shows `immediate_delivery: false`, `accepted_delivery_policies: [:checkpoint, :interrupt]`, and a TUI `:auto` send normalizes to `:checkpoint`.
- "no message is sent on the agent transcript topic" (subscribe to `AgentEvents.agent_topic/1`, `refute_receive`).

Mutation checks: remove the call in `put_session_execution/4` → the fallback
tests fail; remove the control rewrite → the control-flags test fails (and the
R7-C1 F1 pin goes back to its old value); substitute the dispatch profile for `:unknown` → the unknown test
fails.

## Completion and handoff

- [ ] Recompute on transport change; dedicated topic broadcast.
- [ ] Control flags follow the running backend; R7-C1 F1 pin updated in the same PR with the reason.
- Docs: no page documents the stale-flag behaviour; none needed (bug fix restoring documented behaviour).
- Dependents: MP-E7-C2-T05 (bus export), MP-E7-C3-T02 (re-stamp pending items on change), MP-E7-C7-T01 (dashboard pending/confirmed state uses the broadcast).
- Docs: none in wave 3.
