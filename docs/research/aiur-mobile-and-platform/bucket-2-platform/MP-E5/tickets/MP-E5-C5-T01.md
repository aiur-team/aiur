---
ticket_id: MP-E5-C5-T01
feature_id: MP-E5
chunk_id: MP-E5-C5
bucket: 2-platform
title: Voice input on the agent log modal composer
status: blocked
blocked_by: [DESIGN-E5, MP-E5-C1-T03, MP-E5-C3-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: WEB (agent_log_modal.ex is 181 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C5-T01 — Agent log modal voice

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C5.
- **User value:** the same mic choice on the second place the dashboard lets the operator
  message a worker, so voice does not depend on which view is open.
- **Deliverable:** `<.voice_input>` (D16 choice, C3-T01) in the agent log modal composer,
  with `phx-hook="VoiceInput"` on its form, `surface: "agent_composer"` and `target: {kind:
  "worker", ticket: @modal.issue_identifier}`. Submit stays `send-operator-message`.
- **Non-goals:** any change to the modal's log panel or Pause button.

## Dependencies and blockers

- **Owner:** DESIGN-E5 (one design may cover the drawer and the modal, DESIGN-E5 §6).
- **Predecessors:** MP-E5-C1-T03, MP-E5-C3-T01.
- **May run concurrently with:** MP-E5-C4-*, MP-E5-C5-T02.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Composer without voice | `agent_log_modal.ex:43-57`: `form` with `phx-change="composer-change"`, `phx-submit="send-operator-message"`, `textarea name="message"` value `@drafts[@modal.target_key]`, Send button |
| Writable gate | `:16` `composer_writable = writable and writable_target?(modal)`; `:59-62` read-only notices |
| Send handler | `dashboard_live.ex:640-661` (requires `writable_target?`) |
| Modal has no stable form id | the form element has no `id` (`:43`); the log panel has `id="agent-log-panel-<target_key>"` (`:36`) |

## Chosen design

- Give the form `id={"agent-log-composer-#{@modal.target_key}"}` (hooks need a stable id)
  and `phx-hook="VoiceInput"`.
- Add `data-voice-input` to the textarea and `data-voice-send` to Send.
- Render `<.voice_input id=… layout={@d16_layout} capabilities={@voice_capabilities}
  surface="agent_composer" target={%{kind: "worker", ticket: to_string(@modal.issue_identifier)}}
  legacy_conversation={…} />` between the textarea and the actions, as in the drawer.
- `legacy_conversation` follows the C3-T03 decision; under option (a) the modal does **not**
  gain the legacy button (it never had one), so pass `false`.
- New attr on `agent_log_modal/1`: `voice_capabilities` (map, default `%{}`), passed from
  `DashboardLive` (assign from MP-E5-C2-T03).

## Implementation steps

1. Component changes in `agent_log_modal.ex`.
2. Pass `voice_capabilities` from the `DashboardLive` render call site.
3. Docs: `concepts/units.md` voice section says the modal composer has the same controls.

## Non-happy paths

- `target_key` is `"unavailable"` (no running entry, `agent_log_modal.ex:91`): the form is not
  rendered (`writable_target?: false`), so no voice.
- Modal closed while recording: the hook's `destroyed()` disposes capture (C1-T03; precedent
  test `units.browser.spec.mjs:354`).
- Drawer and modal open for the same agent: two independent sessions; limiter allows two.

## Compatibility and rollout

Additive UI. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| `agent_log_modal_test.exs` "renders the voice choice in a writable modal composer" | `data-voice-mode` controls and `phx-hook="VoiceInput"` present; `data-voice-target` encodes the issue identifier |
| `agent_log_modal_test.exs` "no voice controls on a read-only or non-unique modal" | absent in both cases |
| browser "modal dictation fills the message box and waits for Send" | fixture modal; transcript lands; no submit |

```bash
env -C src mise exec -- mix test test/aiur_web/operator_control_center/agent_log_modal_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Render the component outside the `:if={@composer_writable}` form: the
read-only test fails.

## Completion and handoff

- [ ] Modal voice per DESIGN-E5; docs in PR.
- **Dependents:** MP-E5-C6-* (states apply here too).
