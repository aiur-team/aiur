---
ticket_id: MP-R5-C1-T02
feature_id: MP-R5
chunk_id: MP-R5-C1
bucket: 1-refactor
title: Dashboard voice channel on Aiur.Voice; retire the voice_stt_start_fun / voice_tts_start_fun seams
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T01]
prior_units: [U7, U8]
prior_boundaries: ["VOX #36", "WEB #34"]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: n/a (voice_channel.ex is under 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C1-T02 — Dashboard voice channel on `Aiur.Voice`

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C1.
- **User value:** none visible. Dashboard dictation and spoken replies behave
  exactly as today. `AiurWeb.VoiceChannel` stops naming ElevenLabs, and its
  two test seams collapse into the single `:voice_provider` seam.
- **Deliverable:**
  - `voice_channel.ex` calls `Aiur.Voice.start_transcription/1`,
    `push/2`, `commit/1`, `stop/1` and `start_speech/3`.
  - The `:voice_stt_start_fun` and `:voice_tts_start_fun` endpoint-config
    keys are deleted.
  - Tests and the browser fixture server inject a fake provider module instead.
- **Non-goals:**
  - new copy (T04);
  - target awareness or `reason_code` (MP-E5);
  - the limiter. `VoiceSessionLimiter` stays in `aiur_web`; it is supervised by
    `AiurWeb.FinancialData.Supervisor` (`financial_data/supervisor.ex:9,18`),
    which answers plan RQ2.

## Dependencies and blockers

- **Blocked by:** DESIGN-R5 and MP-R5-C1-T01.
- **May run concurrently with:** MP-R5-C1-T03 (a different channel file,
  though both touch `test/browser/fixture_server.exs`; rebase the second one)
  and the C4 tickets.

## Verified starting point (base `45a290e3`)

`src/lib/aiur_web/voice_channel.ex`:

- `alias Aiur.ElevenLabs.{Realtime, TTS}` (`:22`).
- Join → `join_stt/4` → `start_stt/1` (`:64-81`, `:238-246`). Branches:
  - `Endpoint.config(:voice_stt_start_fun)` if set;
  - otherwise `start_realtime/0` (`:248-267`), which maps:
    - `:unconfigured` → "ElevenLabs speech-to-text is not configured.
      Dictation is unavailable; ask the Executor to run `aiur init` and add an
      ElevenLabs API key." (`:254`);
    - other errors → "Speech-to-text could not start. Check the daemon log and
      retry." (`:258`);
    - a raise → "Speech-to-text is unavailable right now." (`:263,266`).
  - `safe_start/2` (`:269-282`) handles the injected fun.
- Audio: `Realtime.push(socket.assigns.stt.pid, data)` (`:90`).
- Stop: `Realtime.commit(pid)` (`:111`).
- Terminate: `Realtime.stop(pid)` (`:199`).
- TTS: `start_tts/2` (`:284-291`), through `:voice_tts_start_fun` or
  `TTS.start(self(), text)`. `tts_error/1` (`:308-314`) maps the reasons.

Tests and fixtures:

- `src/test/aiur_web/voice_channel_test.exs` sets the seams at `:96-97`,
  `:160`, `:224` and `:255`.
- The `"unconfigured dictation explains in the rejected join"` test (`:156`)
  removes the STT seam so the real `Realtime` path runs without a key.
- `src/test/browser/fixture_server.exs:2591-2600` sets both seams.

## Chosen design

- Store the facade session in `socket.assigns.stt` as `%{pid, module}`. Today
  it is `%{pid: pid}`. All `Realtime.*` calls become `Aiur.Voice.*` on that
  map.
- `start_stt/1` becomes:

  ```elixir
  case Aiur.Voice.start_transcription(owner: self()) do
    {:ok, session} -> {:ok, session}
    {:error, :unconfigured} -> {:error, <the :254 string, unchanged>}
    {:error, :not_installed} -> {:error, "Speech-to-text could not start. Check the daemon log and retry."}  # replaced by approved copy in T04
    {:error, reason} -> Logger.warning(...); {:error, <the :258 string>}
  end
  ```

  The `rescue`/`catch` → "Speech-to-text is unavailable right now." stays.
- `start_tts/2` becomes `Aiur.Voice.start_speech(self(), text, [])`.
  `{:error, :not_installed}` maps through `tts_error/1`'s catch-all ("Voice
  playback could not start.") until T04.
- `safe_start/2` is deleted. The fake provider replaces it.
- Test seam: a `FakeVoiceProvider` in the test file. Its `transcriber/0`
  returns a fake transcriber that forwards `push`/`commit` to the test pid,
  as the current fake fun does. Its `synthesizer/0` returns a fake
  synthesizer. Set it with
  `Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)` in `setup`
  and restore it `on_exit`. The file is already `async: false` (`:2`).
- The test at `:156` sets a fake provider whose `transcriber/0` returns the real
  `Aiur.ElevenLabs.Realtime` with no key. It keeps exercising the real
  `:unconfigured` path and asserts the same string.

## Implementation steps

1. Edit `voice_channel.ex` as above. Remove `alias Aiur.ElevenLabs.{Realtime, TTS}`
   and update the moduledoc line `:8`.
2. Update `voice_channel_test.exs`: replace the four seam sites with the fake
   provider. Assertions are unchanged.
3. Update `test/browser/fixture_server.exs:2591-2600` to install a fake provider
   module with the same behaviour as today's funs.
4. `git grep -n "voice_stt_start_fun\|voice_tts_start_fun" -- src` must be
   empty.

## Non-happy paths

- **Provider crash at start:** caught as today and mapped to the same string.
- **Credential rotation between connect and join:** unchanged
  (`voice_channel.ex:49-56`; test `:170`).
- **Lease leak:** `join_stt` must still release the lease on every
  `{:error, _}`, including `:not_installed` (`:77-79`). The test "bounds
  concurrent sessions" (`:283`) catches a leak.

## Compatibility and rollout

- The `:voice_stt_start_fun` and `:voice_tts_start_fun` endpoint-config keys
  are test-only. No operator config or docs mention them (grep of `website/`
  and `.aiur/` at the base finds none). Removing them is safe.
- No wire change. Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/voice_channel_test.exs test/aiur/voice_test.exs
```

- Every existing `voice_channel_test.exs` test passes with **unchanged
  assertions**. That is the behaviour-preservation oracle.
- New test "dictation join without a voice provider is refused and releases its
  lease": set `:voice_provider` to `nil`; join; assert `{:error, %{reason: _}}`;
  then join twice more with a working fake and assert both succeed (the
  capacity is not leaked).
  - Mutation: delete the `VoiceSessionLimiter.release(lease)` in the error
    branch of `join_stt` (`:78`). The new test fails on the third join.
- Browser fixture smoke, if Playwright is available: `src/browser/tests/units.browser.spec.mjs` (the
  only browser spec referencing dictation at base) passes against
  `fixture_server.exs`.

## Completion and handoff

- [ ] No `Aiur.ElevenLabs` reference remains in `voice_channel.ex`.
- [ ] Both seams are gone from `src/`.
- [ ] Docs: none (internal).
- **Dependents:**
  - T04 replaces the interim `:not_installed` text with approved copy;
  - MP-E5-C2 adds render-time availability on top of
    `Aiur.Voice.availability/0`.
