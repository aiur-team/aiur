---
ticket_id: MP-E5-C4-T01
feature_id: MP-E5
chunk_id: MP-E5-C4
bucket: 2-platform
title: Dictate a Command custom response on the answer form (card and detail)
status: blocked
blocked_by: [DESIGN-E5, E5-OQ3, DESIGN-E2, MP-E5-C1-T03, MP-E5-C3-T01, MP-E5-C2-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB, DEC]
prior_features: [ui-07]
prior_findings: []
size_owner: WEB (decision_action.ex is 198 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C4-T01 — Dictated Command answers

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C4 dictated Command responses.
- **User value:** the operator answers a blocker by speaking a custom response, reviews the
  text and records it with the existing button. This is the dashboard half of "respond to a
  blocker by voice" that the phone and watch reuse.
- **Deliverable:** `<.voice_input>` on the Command answer form in
  `DecisionAction.decision_action/1`, bound to the `answer[custom_response]` textarea, for
  both the card (`decision_card.ex:92`) and the detail page (`decision_detail.ex:28`).
  Submission is unchanged: the existing `answer-decision` event (V7).
- **Non-goals:** picking an option by voice ("option two") — that is intent parsing and
  belongs to MP-E6 `propose_command_answer`; Converse on Commands (DESIGN-E6); the revision
  form (C4-T02).

## Dependencies and blockers

- **Owner:** DESIGN-E5 (mic placement on the form), **E5-OQ3** (auto-select "Custom response"
  when dictation starts; append or replace), DESIGN-E2 §4 (Command presentation that hosts it).
- **Predecessors:** MP-E5-C1-T03 (standalone hook), MP-E5-C3-T01 (choice), MP-E5-C2-T01
  (`command` target validation).
- **May run concurrently with:** MP-E5-C4-T02, MP-E5-C5-T01.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Form | `decision_action.ex:54-60`: `id="decision-answer-form-<decision_id>"`, `phx-change="decision-action-change"`, `phx-submit="answer-decision"` |
| Custom field rendered only when chosen | `:97-106` `<label :if={@choice == "custom"}>` with `textarea name="answer[custom_response]" maxlength="4000" required` and server-echoed value `Map.get(@form, "custom_response", "")` |
| "Custom response" radio | `:86-92` (`value="custom"`); with no options a hidden `answer[choice]=custom` (`:95`) |
| Server form state | `DecisionCommands.change/3` → `put_form/4` keeps `choice`, `custom_response` (`decision_commands.ex:15-21,142-144,286-294`) |
| Submit | `record_answer/4` → `answer_content/1` (`:148-162`) → `DecisionStore.answer/5` with `idempotency_key` from `ensure_action_key/2` (one key per decision per LiveView, `:273-284`) and `expected_version: decision.version` (`:93`) |
| Conflicts | `put_error/3` deletes the idempotency key (`:296-302`); texts `:347-382` (`stale_version`, `already_decided`, `idempotency_conflict`, `resolved`, `too_long`) |
| Server length cap | `DecisionAnswer` `@response_max 4_000` (`decision_answer.ex:15`), `{field, :too_long}` (`:251`) |

**Finding:** setting a textarea's `value` from script bypasses `maxlength`, so dictation can
exceed 4,000 characters; the server then refuses with "too long" (`decision_commands.ex:363`).

## Chosen design

- Wrap: the form gets `phx-hook="VoiceInput"` (its stable `id` already exists, `:56`).
- **E5-OQ3 = auto-select (recommended):** the component is rendered **outside** the
  `:if={@choice == "custom"}` label (so it exists before the textarea does) with
  `data-voice-select-custom="answer[choice]"`. On Dictate:
  1. the controller checks the `custom` radio and dispatches a bubbling `change` event
     (→ `decision-action-change` → server re-renders with the textarea);
  2. it waits for `[data-voice-input]` to appear inside the hook element (resolved in the
     hook's `updated()` callback; timeout 2 s → status "The response field did not open."
     — **copy for DESIGN-E5** — and no capture);
  3. only then calls `getUserMedia` (so no partial is lost before the field exists).
  With **append** (recommended), `baseText` is the field's current text
  (`conversation-voice-controller.js:167`, unchanged). With **replace**, the controller
  clears the field at start and keeps the old text for Cancel to restore (C6-T02).
- **E5-OQ3 = no auto-select:** the component renders inside the custom label only; the mic
  is visible only after the operator picks "Custom response".
- The textarea gains `data-voice-input`; the submit button gains `data-voice-send`.
- **Length cap:** when the field's length reaches `maxlength` (read from the attribute,
  4,000), the controller calls `stop()` and shows the DESIGN-E5 "limit reached" copy; text is
  never truncated by the client (the operator edits).
- Join payload: `surface: "command_response"`, `target: {kind: "command", decision_id,
  expected_version}` from `data-voice-target` rendered with the decision's current
  `version`.
- Idempotency: unchanged (one key per decision per LiveView, regenerated after an error);
  dictation never creates its own key.

## Implementation steps

1. `decision_action.ex`: `phx-hook`, component placement per E5-OQ3, `data-voice-*`
   attributes, `data-voice-target` JSON.
2. Controller: `data-voice-select-custom` flow and the `maxlength` stop.
3. Docs: `website/docs-app/concepts/commands.md` (answering a Command: dictation of a custom
   response, review before Record) and `apis/elevenlabs.md` "What voice does" table.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Command resolved elsewhere before dictation | join refused `target_stale` (C2-T01); no capture; status shows why |
| Command version moves while dictating | Record → `{:conflict, {:stale_version, …}}` → existing error text; dictated text stays in the field because the server form state holds it (`put_form/4` keeps `custom_response`; `put_error/3` keeps `:form`) |
| Answered on the phone/deck meanwhile | `already_decided` conflict; text kept to copy |
| Double click on Record | existing idempotency key → `:duplicate` notice (`decision_commands.ex:323-324`) |
| Voice unavailable | Dictate disabled with reason (C6-T01); typing works (V6) |
| Read-only dashboard | form not rendered (`:55` `@writable`) |

## Compatibility and rollout

No change to the answer payload or the store. Behind DESIGN-E5 approval. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| LiveView "dictated custom text is recorded with the existing answer-decision payload" | simulate the controller's `input` → `decision-action-change` then submit → `DecisionStore` fake receives `%{"custom_response" => text, "expected_version" => v, "idempotency_key" => "ui_…"}` |
| LiveView "a stale version keeps the dictated text in the field" | store returns `{:conflict, {:stale_version, 4, 5}}` → error shown and the re-rendered textarea still contains the text |
| LiveView "double Record records once" | second submit with the same key → `:duplicate` notice, store answer count 1 |
| browser "Dictate selects Custom response and waits for the field before capture" | `getUserMedia` called only after `[data-voice-input]` exists; the custom radio is checked |
| browser "dictation stops at the 4,000-character limit" | fake transcript of 4,100 chars → `stop` pushed, field keeps all text, status shows the limit copy |
| browser "no microphone on opening /commands/:id" | spy 0 |

```bash
env -C src mise exec -- mix test test/aiur_web/operator_control_center/decision_action_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

(`decision_action_test.exs` is PROPOSED if it does not exist; the decision LiveView tests live
under `src/test/aiur_web/`.) Run Elixir tests in an implementation worktree with
`GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check `~/.aiur/github-budget/agent-token` before and
after.

**Mutation checks.** Call `getUserMedia` before the field exists (remove the wait): the
"waits for the field" test fails. Remove the `maxlength` stop: the 4,000 test fails.

Manual: wrapper-tmux recipe with `--test` to get an open Command; answer it by voice from a
real browser on `/commands/<id>`; confirm the agent receives the custom response.

## Completion and handoff

- [ ] Mic on card and detail answer forms per DESIGN-E5/E5-OQ3; tests green; docs in PR.
- **Dependents:** MP-E5-C6-T03 (delivery state), MP-N6-C4-T02 (same flow on the phone).
