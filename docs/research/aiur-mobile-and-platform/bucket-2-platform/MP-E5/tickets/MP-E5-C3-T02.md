---
ticket_id: MP-E5-C3-T02
feature_id: MP-E5
chunk_id: MP-E5-C3
bucket: 2-platform
title: Converse hand-off from the mic choice to the MP-E6 conversation panel
status: blocked
blocked_by: [DESIGN-E5, DESIGN-E6, MP-E5-C3-T01, MP-E6-C7-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: WEB
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C3-T02 — Converse opens the assistant panel for the same target

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C3.
- **User value:** choosing Converse on any voice surface opens the voice assistant already
  pointed at the right ticket or the Executor, so the operator never re-selects a target.
- **Deliverable:** the Converse control emits a LiveView event
  `"open-voice-conversation"` with `%{"surface" => s, "target" => t}` (the same target the
  component carries for Dictate). The host LiveView handles it by opening the MP-E6 panel
  component (MP-E6-C7-T02) with that target. **The click does not start capture**; the
  panel's own Start/consent step does (DESIGN-E6).
- **Non-goals:** the panel itself, sessions, consent copy (MP-E6); Command-answer Converse
  (DESIGN-E6 decides whether Converse appears on Command surfaces; until then the
  Command-response component passes `converse: false`).

## Dependencies and blockers

- **Owner:** DESIGN-E5 (choice) and DESIGN-E6 (panel placement: drawer-embedded or separate).
- **Predecessors:** MP-E5-C3-T01; MP-E6-C7-T02 (panel component and its `open/2` contract).
- Until MP-E6-C7-T02 lands, Converse is rendered unavailable (`voice.conversation`
  `not_installed`), so this ticket is the only place the event is wired.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Event routing in DashboardLive | `handle_event/3` clauses such as `"send-operator-message"` (`dashboard_live.ex:640-661`) and decision events via `DecisionEvents.events/0` (`decision_events.ex:9-23`) |
| Size | `dashboard_live.ex` 2,903 lines (U8 `WEB` owner): the handler must delegate to a new module, net-neutral in that file |

## Chosen design

- Component: `phx-click="open-voice-conversation"` with `phx-value-surface` and
  `phx-value-target` (JSON-encoded target, validated server-side).
- Handler: `AiurWeb.VoiceConversationEvents.open/2` (PROPOSED) parses and validates the target
  with `AiurWeb.VoiceTargets.validate/2` (MP-E5-C2-T01) **before** opening the panel, and
  assigns `:voice_conversation_panel` = `%{target, surface}`. On refusal it sets an inline
  error with the `reason_code` copy from DESIGN-E5.
- `DashboardLive` gets one clause delegating to that module (net-neutral by moving an
  existing small clause out if needed, per U8).

## Implementation steps

1. Component event wiring (Converse control only).
2. `voice_conversation_events.ex` with `open/2`, `close/1`.
3. One `handle_event` clause in `DashboardLive`; the Executor LiveView (MP-E3-C6) adds the
   same clause.
4. Docs: `concepts/units.md` voice section names the Converse option and links the
   assistant concepts page (MP-E6-C9).

## Non-happy paths

- Target gone between render and click → refusal from `VoiceTargets` (`target_not_found`),
  no panel.
- Forged `phx-value-target` → `invalid_payload`; no panel.
- `voice.conversation` turned off between render and click → handler re-checks the capability
  (client-capability-model rule 5) and refuses with its reason.

## Compatibility and rollout

Additive; inert until E6 reports `voice.conversation` available. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| LiveView "Converse opens the panel for the drawer's worker" | render drawer, click Converse → assigns panel with `%{kind: "worker", ticket: "1110"}` |
| LiveView "Converse on a stopped agent shows target_not_found and no panel" | panel assign stays nil |
| LiveView "a forged target is refused" | `phx-value-target` `{"kind":"root"}` → `invalid_payload` |
| browser "clicking Converse requests no microphone" | `getUserMedia` spy 0 |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_conversation_events_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Remove the `VoiceTargets.validate/2` call from `open/2`: the "stopped
agent" and "forged target" tests fail.

## Completion and handoff

- [ ] Converse opens the panel for the same target; no capture on click.
- [ ] Docs updated in the same PR.
- **Dependents:** MP-E6-C7-T02 (consumes the event), MP-E5-C5-T02 (Executor surface).
