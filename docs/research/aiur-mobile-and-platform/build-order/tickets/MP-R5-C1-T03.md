---
ticket_id: MP-R5-C1-T03
feature_id: MP-R5
chunk_id: MP-R5-C1
bucket: 1-refactor
title: Stream Deck voice and voice projection on Aiur.Voice; retire streamdeck_voice_session / streamdeck_voice_available_fun
status: blocked
blocked_by: [DESIGN-R5, DESIGN-R6, MP-R5-C1-T01]
prior_units: [U7, U8]
prior_boundaries: ["VOX #36", "SD #35", "WEB #34"]
prior_features: [ui-08, integrations-51]
prior_findings: []
size_owner: "DECK_WEB (streamdeck_channel.ex 609, streamdeck_projection.ex 540): net-neutral or smaller"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C1-T03 — Stream Deck voice on `Aiur.Voice`

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C1.
- **User value:** none visible. Hold-to-dictate and the mic key's
  unavailable reason behave exactly as today. This ticket also lands MP-R6-C3's
  "voice delegation" item; R6 re-verifies it here instead of in a ticket of its
  own.
- **Deliverable:**
  - `AiurWeb.StreamdeckChannel` opens, pushes, commits and stops sessions
    through `Aiur.Voice`.
  - `AiurWeb.StreamdeckProjection.voice/0` derives from
    `Aiur.Voice.availability/0` and keeps the wire shape `%{available, reason}`.
  - The `:streamdeck_voice_session` and `:streamdeck_voice_available_fun` seams
    are removed.
- **Non-goals:**
  - deck event names or payloads (`docs/streamdeck-channel.md` § Voice input is
    unchanged);
  - `not_installed` copy (T04);
  - renaming deck modules (MP-R6 decides not to).

## Dependencies and blockers

- **Blocked by:**
  - DESIGN-R5;
  - DESIGN-R6, because this changes Stream Deck code and the R6 gate confirms
    "hold-to-dictate preserved";
  - MP-R5-C1-T01.
- **May run concurrently with:** T02 (rebase on the shared
  `fixture_server.exs` only if it is touched) and MP-R6-C1-T01. That ticket
  touches `streamdeck_logs.ex`, not this ticket's files.

## Verified starting point (base `45a290e3`)

`src/lib/aiur_web/streamdeck_channel.ex`:

- `alias Aiur.ElevenLabs.Realtime` (`:7`).
- `voice_start` (`:193-205`) → `open_voice_session/0` (`:362-373`):
  - `module = voice_session_module()` (`:355-360`, seam
    `:streamdeck_voice_session`, defaulting to `Realtime`);
  - `module.start(owner: self())`;
  - the session map is `%{id, pid, ref: Process.monitor(pid), module}`.
- `voice_audio`/`voice_stop` call `module.push`/`module.commit`
  (`:210-230`). The session-id stale-frame guard is in the pattern match.
- Errors reply `{:error, %{"reason" => reason_text(reason)}}` (`:201`), and
  `reason_text/1` (`:459-460`) stringifies atoms. So `:unconfigured` becomes
  `"unconfigured"`.

`src/lib/aiur_web/streamdeck_projection.ex`:

- `voice/0` (`:33-40`) returns `%{available: true, reason: nil}`, or
  `%{available: false, reason: @voice_unconfigured_reason}` (`:8`: "Aiur has
  no ElevenLabs API key - transcription is off").
- It reads `configured_elevenlabs_key?/0` (`:46-58`, seam
  `:streamdeck_voice_available_fun`; rescue → false).

Tests:

- `src/test/aiur_web/streamdeck_channel_test.exs` sets the voice seams at
  `:1067,1090,1106,1135,1159,1178` (session) and `:1201,1211` (available
  fun).
- `"no configured API key is reported as unconfigured rather than as a failure"`
  (`:1089-1096`) uses `UnconfiguredVoiceSession`.
- `src/test/aiur_web/streamdeck_projection_test.exs` covers `voice/0`.

Sidecar: `packages/streamdeck/src/channel.ts:453,500` passes the `reason`
string through opaquely. A new reason text or code needs no sidecar change.

## Chosen design

- `open_voice_session/0` becomes:

  ```elixir
  case Aiur.Voice.start_transcription(owner: self()) do
    {:ok, %{pid: pid, module: module}} -> {:ok, %{id: mint_session_id(), pid: pid, ref: Process.monitor(pid), module: module}}
    {:error, reason} -> {:error, reason}
  end
  ```

  The existing `_other -> {:error, :voice_unavailable}` clause is covered by the
  facade's contract and is deleted. `push`/`commit`/`stop` keep using
  `session.module` (unchanged lines `:212`, `:224`).
- `StreamdeckProjection.voice/0` becomes:

  ```elixir
  case Aiur.Voice.availability() do
    %{available: true} -> %{available: true, reason: nil}
    %{reason: :unconfigured} -> %{available: false, reason: @voice_unconfigured_reason}
    %{reason: :not_installed} -> %{available: false, reason: @voice_unconfigured_reason}  # replaced by approved copy in T04
  end
  ```

  The rescue → unavailable behaviour moves into `Aiur.ElevenLabs.configured?/0`
  (T01).
- Tests: fake provider modules replace `FakeVoiceSession`,
  `UnconfiguredVoiceSession` and the boolean fun. The fake transcribers stay
  the same modules; only the provider wrapper is new.

## Implementation steps

1. Edit `streamdeck_channel.ex`:
   - remove the alias and `voice_session_module/0`;
   - rewrite `open_voice_session/0`;
   - update the comment at `:352-354` to name `:voice_provider`.
2. Edit `streamdeck_projection.ex`:
   - `voice/0` delegates to the facade;
   - delete `configured_elevenlabs_key?/0` and `present?/1` if no other
     caller uses them (grep).
3. Update the eight seam sites in `streamdeck_channel_test.exs` and the
   projection tests to the fake provider.
4. `git grep -n "streamdeck_voice_session\|streamdeck_voice_available_fun" -- src`
   must be empty.

## Non-happy paths

- **Second hold while one is live:** unchanged. `stop_voice_session/1` stops,
  demonitors and drains first (`:379-399`, tags renamed in T01).
- **Session process dies silently:** the `:DOWN` handler (`:324-327`) still
  pushes `voice_closed`.
- **Unauthenticated `voice_start`:** unchanged reply `"unauthorized"`
  (`:205`).
- **No key:** the reply is `"unconfigured"`. The test at `:1089-1096` keeps
  asserting exactly that.

## Compatibility and rollout

No wire change, and both seams are test-only (not in `website/` or `.aiur/`).
Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/streamdeck_channel_test.exs test/aiur_web/streamdeck_projection_test.exs \
  test/aiur_web/streamdeck_control_agreement_test.exs test/aiur_web/live/streamdeck_live_test.exs
env -C <worktree>/packages/streamdeck npm test
```

- Existing assertions are unchanged. That is the oracle.
- New test in `streamdeck_projection_test.exs`: "voice availability follows
  the voice port". With a fake provider whose `configured?` is false, assert
  `voice() == %{available: false, reason: "Aiur has no ElevenLabs API key - transcription is off"}`.
  With true, assert `%{available: true, reason: nil}`.
  - Mutation: hard-code `voice/0` to `%{available: true, reason: nil}`. The
    first case fails.
- **Manual re-proof** (MP-R6 acceptance § 7.5, DESIGN-R6 §2.1). On the owner's
  deck: hold Mic, speak, release, and see the transcript; Send delivers to the
  focused agent. Otherwise use the `/streamdeck` emulator for targeting, plus
  the external latency test with a key:

  ```bash
  AIUR_VOICE_FIXTURE=<16 kHz s16le file> mix test --only external test/aiur_web/streamdeck_voice_latency_test.exs
  ```

  State which one was run in the PR body.

## Completion and handoff

- [ ] No `Aiur.ElevenLabs` reference remains in `streamdeck_channel.ex` or
  `streamdeck_projection.ex`.
- [ ] Both seams are gone.
- [ ] The manual re-proof is recorded.
- [ ] Docs: none. Copy changes, if any, belong to T04.
- **Dependents:** T04, and MP-R6-C3-T01 (which documents the classification).
