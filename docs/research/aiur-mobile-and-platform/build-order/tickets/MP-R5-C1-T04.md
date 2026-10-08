---
ticket_id: MP-R5-C1-T04
feature_id: MP-R5
chunk_id: MP-R5-C1
bucket: 1-refactor
title: The "voice not installed" state — approved copy on the dashboard and the deck, plus the absent-provider acceptance test
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T02, MP-R5-C1-T03]
prior_units: [U7]
prior_boundaries: ["VOX #36", "SD #35", "WEB #34"]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: n/a (small edits; streamdeck_projection.ex is net-neutral)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C1-T04 — The "voice not installed" state

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C1.
- **User value:** if a build ships without the voice provider, every voice
  surface says so plainly, and typed messages keep working (contract V6). This
  is the only new user-visible state in MP-R5 (DESIGN-R5 §2).
- **Deliverable:**
  1. The approved DESIGN-R5 §2 copy:
     - the dashboard join error;
     - the deck projection reason;
     - the deck `voice_start` reply code `not_installed`;
     - the TTS start error.
  2. `docs/streamdeck-channel.md` § The `voice` snapshot entry names the second
     reason.
  3. The plan § 7.3 acceptance test: absent provider → (a) availability,
     (b) the dashboard join copy, (c) the deck reply, (d) typed
     `AgentChat.send/3` still delivers.
- **Non-goals:**
  - render-time hiding or disabling of the dashboard mic (see blockers);
  - the physical package (C3);
  - Units-page work: the quota row is hidden through C2-T01.

## Dependencies and blockers

- **Blocked by:** DESIGN-R5, which must approve:
  - the §2 copy;
  - **hidden versus disabled-with-reason for the dashboard mic.**

  If the owner picks **"disabled with reason"** (recommended; it matches
  today's no-key flow, where the reason arrives as the join error), this ticket
  is complete as written. If the owner picks **"hidden"**, the mic must check
  availability at render time. That is MP-E5-C2's change (contract §7: "MP-E5-C2
  moves that check to render time"), and this ticket then also waits for
  MP-E5-C2.
- **Predecessors:** T02 and T03.
- **May run concurrently with:** C2-T01 and the C4 tickets.

## Verified starting point (base `45a290e3`)

These references are as of T02/T03. The line numbers are base-SHA values for
the same code.

- **Dashboard:** after T02, `start_stt/1` maps `{:error, :not_installed}` to
  the interim "Speech-to-text could not start…" text. `tts_error/1`
  (`voice_channel.ex:308-314`) catches the rest.
- **Deck:**
  - After T03, `StreamdeckProjection.voice/0` maps `:not_installed` to the
    no-key reason (interim).
  - `voice_start` replies `reason_text(:not_installed)` = `"not_installed"`
    (`streamdeck_channel.ex:201,459`). The machine code is already correct, so
    only the projection's human reason changes.
- **Typed path:** `Aiur.AgentChat.send/3` (`src/lib/aiur/agent_chat.ex:12-49`)
  has no voice dependency (grep at base finds no `ElevenLabs` or `Voice`
  reference in it).
- **Docs:** `docs/streamdeck-channel.md:140-150` describes only the no-key
  reason.

## Chosen design

| Surface | Value (DESIGN-R5 §2 proposal; use the approved text) | Where |
| --- | --- | --- |
| Dashboard dictation join error | "Voice input isn't installed in this Aiur. Typed messages work as usual." | `voice_channel.ex` `start_stt/1` `:not_installed` clause |
| Dashboard spoken reply (`speak`) | Same sentence. `tts_error(:not_installed)` gets an explicit clause. | `voice_channel.ex` `tts_error/1` |
| Deck mic key reason | "Voice isn't installed in this Aiur" | `streamdeck_projection.ex`, new `@voice_not_installed_reason` |
| Deck `voice_start` reply | `not_installed` (machine code, not shown) | unchanged code path |

Copy lives as module attributes beside the existing ones (`streamdeck_projection.ex:8`),
not in a new copy module.

## Implementation steps

1. Add the `:not_installed` clauses and the attribute, with the approved
   strings.
2. Add a "Voice not installed" sentence to `docs/streamdeck-channel.md:146-150`
   naming the second reason string.
3. Add the PROPOSED acceptance test
   `src/test/aiur_web/voice_absent_test.exs` (`async: false`; it sets
   `:voice_provider` to `nil` and restores it `on_exit`):
   - (a) `Aiur.Voice.availability() == %{available: false, reason: :not_installed}`;
   - (b) the dashboard join returns `{:error, %{reason: <approved dashboard copy>}}`,
     using the `voice_channel_test.exs` socket setup helpers;
   - (c) a deck `voice_start` replies `{:error, %{"reason" => "not_installed"}}`,
     and `StreamdeckProjection.voice().reason` equals the approved deck copy;
   - (d) `Aiur.AgentChat.send/3` to a fake running agent returns the same
     `:ok`/receipt as with a provider configured. Reuse the fixture pattern of
     the existing `AgentChat` tests (grep `agent_chat_test.exs`).

## Non-happy paths

- **A key is set but no provider exists:** `:not_installed` wins. The key is
  irrelevant without code to use it, and the copy must not tell the operator to
  add a key that would change nothing.
- **Absent provider plus a mid-session state:** none can exist; no session can
  start.

## Compatibility and rollout

- Unreachable in shipped builds until C3 (the default provider is always
  present). The copy ships early so C3 adds no user-facing change.
- Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/voice_absent_test.exs test/aiur_web/voice_channel_test.exs \
  test/aiur_web/streamdeck_channel_test.exs test/aiur_web/streamdeck_projection_test.exs
```

Mutation checks (plan § 7.3):

- Replace `Aiur.Voice.availability/0`'s nil-provider branch with
  `reason: :unconfigured`. Tests (a) and (c) fail.
- Delete the `:not_installed` clause in `start_stt/1`, so it falls to the
  generic text. Test (b) fails.
- Map `:not_installed` to the no-key reason in the projection. Test (c) fails.

There is no manual device test: the state is unreachable on a shipped build.
The approved copy is reviewed against DESIGN-R5.

## Completion and handoff

- [ ] Approved copy applied verbatim.
- [ ] Tests (a)–(d) are green, and each mutation goes red.
- [ ] `docs/streamdeck-channel.md` is updated. The deck protocol doc is the
  developer-facing page for this channel. No `website/docs-app` change is
  needed until C3 makes the state reachable; C3-T01 carries the operator docs.
- **Dependents:** C3-T01 (makes the state reachable); MP-R1-C3 (the
  `voice.stt` capability reports `not_installed` from the same function).
