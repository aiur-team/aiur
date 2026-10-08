---
ticket_id: MP-E5-C3-T03
feature_id: MP-E5
chunk_id: MP-E5-C3
bucket: 2-platform
title: Apply the owner's decision on the legacy auto-submit "interactive voice chat" (E5-OQ2)
status: blocked
blocked_by: [DESIGN-E5, E5-OQ2, MP-E5-C3-T01]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: BROWSER (controller), WEB (voice_channel.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C3-T03 — Legacy interactive voice chat

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C3.
- **User value:** the dashboard stops offering a voice mode that sends speech to an agent
  without review (it violates V5), or keeps it clearly labelled, as the owner decides.
- **Deliverable — one of three, selected by E5-OQ2 (DESIGN-E5 §3):**
  - **(a) remove when MP-E6 ships (recommended):** keep the legacy button under its current
    label until `voice.conversation` is `available`; then render `legacy_conversation:
    false` on every surface and delete the `voice:conversation` topic, its channel clauses
    and the controller's conversation-mode code in a follow-up release.
  - **(b) keep as a third labelled option** next to Dictate and Converse, with the label and
    copy DESIGN-E5 approves.
  - **(c) remove now:** `legacy_conversation: false` everywhere and delete the code paths.
- **Non-goals:** changing what Converse means (MP-E6).

## Dependencies and blockers

- **Owner:** E5-OQ2. No option is pre-selected by this ticket.
- **Predecessors:** MP-E5-C3-T01.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Button | `conversation_drawer.ex:199-212` |
| Auto-submit | `submitConversationTurn` → `form.requestSubmit(this.send)` (`conversation-voice-controller.js:354-366`); reply watch and `speak` (`:375-396`); playback (`:398-440`) |
| Server | topic `voice:conversation` (`voice_socket.ex:18`); `speak` handling (`voice_channel.ex:118-149`); TTS relay (`:169-182`) |
| Tests | `voice_channel_test.exs:204,222,242,251,295`; `units.browser.spec.mjs:545,622,659`; `conversation_drawer_test.exs:191` |
| Docs | `concepts/units.md:39-54` (spoken conversation); `apis/elevenlabs.md:10` ("Text to speech — Dashboard interactive conversation") |

## Chosen design per option

| Option | Code | Tests | Docs |
| --- | --- | --- | --- |
| (a) | `legacy_conversation` computed as `voice.conversation.state not in ["available", "degraded"]`; deletion PR later removes `:118-149,169-182`, `voice:conversation`, controller `:354-440` | add "legacy button disappears when voice.conversation is available"; keep existing tests until the deletion PR, then delete them with the code | `units.md` notes the legacy mode is replaced by the assistant |
| (b) | keep code; change label/copy per DESIGN-E5 | update the label assertions in `conversation_drawer_test.exs:191` and the spec button names | `units.md` documents three options |
| (c) | delete now | delete the listed tests; add "no voice:conversation topic is routed" | remove the spoken-conversation rows from `units.md` and `elevenlabs.md:10` |

`voice.tts` stays meaningful under (a) and (b); under (c) it remains for MP-E6 spoken replies.

## Implementation steps

1. Apply the selected row.
2. Under (a) or (c), the deletion PR also removes `Synthesizer` usage from `VoiceChannel` (MP-R5's
   `Aiur.Voice.Synthesizer` stays for MP-E6).

## Non-happy paths

- An open browser tab still running the old JS after (c): its `voice:conversation` join gets
  `invalid_payload` (topic not routed → Phoenix join error); the controller shows its
  transport-failure copy (`conversation-voice-controller.js:249-250`). Typing still works.

## Compatibility and rollout

(a) is the only option with a two-step rollout. Rollback: revert the relevant PR.

## Verification

```bash
env -C src mise exec -- mix test test/aiur_web/voice_channel_test.exs test/aiur_web/operator_control_center/conversation_drawer_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check (option a).** Hard-code `legacy_conversation: true`: the "disappears when
voice.conversation is available" test fails. (Option c.) Re-add the topic route: "no
voice:conversation topic is routed" fails.

## Completion and handoff

- [ ] The E5-OQ2 answer is recorded in DESIGN-E5 and applied; docs updated in the same PR.
- **Dependents:** MP-E6-C9-T01 (docs mention of the replacement), contract §1 note on
  `voice:conversation`.
