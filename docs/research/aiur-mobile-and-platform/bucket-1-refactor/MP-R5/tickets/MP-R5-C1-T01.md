---
ticket_id: MP-R5-C1-T01
feature_id: MP-R5
chunk_id: MP-R5-C1
bucket: 1-refactor
title: Aiur.Voice port — provider, transcriber and synthesizer behaviours; ElevenLabs emits neutral message tags
status: blocked
blocked_by: [DESIGN-R5]
prior_units: [U7, U8]
prior_boundaries: ["VOX #36", "CFG #2", "WEB #34", "SD #35"]
prior_features: [integrations-51, ui-07, ui-08]
prior_findings: []
size_owner: "DECK_WEB (streamdeck_channel.ex 609 lines): edit is a net-zero rename"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C1-T01 — `Aiur.Voice` port and neutral message tags

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C1.
- **User value:** none visible. This ticket creates the single provider-neutral
  seam that E5, E6, N6 and N7 build on (voice-session contract §4), so no
  later feature reaches into `Aiur.ElevenLabs.*`.
- **Deliverable:**
  1. Four new modules: the `Aiur.Voice.Provider`, `Aiur.Voice.Transcriber`
     and `Aiur.Voice.Synthesizer` behaviours, and the `Aiur.Voice` facade
     (provider resolution, `availability/0`, transcription and speech start).
  2. A new `Aiur.ElevenLabs` module that implements `Aiur.Voice.Provider`.
     `Aiur.ElevenLabs.Realtime` and `Aiur.ElevenLabs.TTS` declare the
     transcriber and synthesizer behaviours.
  3. The owner messages are renamed to the RC-14 names. Every receiver is
     updated in the same PR:
     - `{:elevenlabs_transcript, k, t}` → `{:voice_transcript, k, t}`
     - `{:elevenlabs_error, r}` → `{:voice_error, r}`
     - `{:elevenlabs_closed}` → `{:voice_closed}`
     - `{:elevenlabs_audio, …}` → `{:voice_audio, …}` (TTS; see CR-R5-1)
- **Non-goals:**
  - moving callers onto the facade (T02, T03);
  - the `:not_installed` copy (T04);
  - config, init and quota ownership (C2);
  - stable error codes: `reason` stays today's human string, and
    `reason_code` is MP-E5's contract §8 work.
  - No browser- or sidecar-visible event name changes.

## Dependencies and blockers

- **Blocked by:** DESIGN-R5. The plan's other blocker, voice-session contract
  reconciliation, is **resolved by RC-14**: the contract adopts R5's tags and
  the `:unconfigured` / `:not_installed` reasons. The contract text still shows
  the older names; CR-R5-1 asks the coordinator to update it. That is not a
  blocker.
- **Predecessors:** none.
- **May run concurrently with:**
  - MP-R5-C4-T01 (docs) and MP-R5-C4-T02 (sidecar);
  - MP-R6-C1-T01 and MP-R6-C2-T01, which use different files.

  Not with T02 or T03, which build on this ticket.

## Verified starting point (base `45a290e3`)

- **Provider API:** `src/lib/aiur/eleven_labs/realtime.ex` (421 lines):
  - `start/1`, `start_link/1` (`:91-96`). Both return
    `{:error, :unconfigured}` without a key (`:127-134`).
  - `push/2` (`:99-104`), `commit/1` (`:107-112`), `stop/1` (`:115-120`).
  - Messages are sent by `notify/2` (`:389`) and `finish/1` (`:380-384`).
  - There are 9 occurrences of `:elevenlabs_*` tags in the file (grep count).
- **TTS:** `src/lib/aiur/eleven_labs/tts.ex` (135 lines). `start/3` is at
  `:22`; the `{:elevenlabs_audio, …}` messages are at `:56,58,85,90,92,97,100`.
- **Receivers:**
  - `src/lib/aiur_web/voice_channel.ex:154-182` (6 clauses);
  - `src/lib/aiur_web/streamdeck_channel.ex:305-320` and the drain at
    `:391-399`.
- **Tests that send or receive the tags** (grep counts at base):

  | File | Count |
  | --- | --- |
  | `test/aiur/eleven_labs/realtime_test.exs` | 26 |
  | `test/aiur/eleven_labs/tts_test.exs` | 7 |
  | `test/aiur_web/voice_channel_test.exs` | 8 |
  | `test/aiur_web/streamdeck_channel_test.exs` | 5 |
  | `test/aiur_web/streamdeck_voice_latency_test.exs` | 4 (`@moduletag :external`) |
  | `test/browser/fixture_server.exs` | 6 |

- **Namespace:** there is no `Aiur.ElevenLabs` or `Aiur.Voice` module today
  (grep `defmodule Aiur.(Voice|ElevenLabs) `). Only `Aiur.ElevenLabs.*`
  children exist.
- **Contract:** `contracts/voice-session.md` §4 (roles `Voice.Transcriber`,
  `Voice.Synthesizer`). RC-14 fixes the message names.

## Chosen design

PROPOSED files:

```
src/lib/aiur/voice.ex                 Aiur.Voice (facade, always compiled in core)
src/lib/aiur/voice/provider.ex        Aiur.Voice.Provider (behaviour)
src/lib/aiur/voice/transcriber.ex     Aiur.Voice.Transcriber (behaviour)
src/lib/aiur/voice/synthesizer.ex     Aiur.Voice.Synthesizer (behaviour)
src/lib/aiur/eleven_labs.ex           Aiur.ElevenLabs (implements Provider)
```

```elixir
defmodule Aiur.Voice.Provider do
  @callback transcriber() :: module()        # implements Aiur.Voice.Transcriber
  @callback synthesizer() :: module()        # implements Aiur.Voice.Synthesizer
  @callback configured?() :: boolean()       # presence of a credential only; never the credential
end

defmodule Aiur.Voice.Transcriber do
  # owner receives {:voice_transcript, :partial | :final, String.t()}, {:voice_error, String.t()}, {:voice_closed}
  @callback start(keyword()) :: {:ok, pid()} | {:error, :unconfigured | term()}   # opts include owner: pid
  @callback push(pid(), String.t()) :: :ok      # base64 PCM16 16 kHz mono, relayed verbatim
  @callback commit(pid()) :: :ok                # flush tail; the session closes itself after
  @callback stop(pid()) :: :ok
end

defmodule Aiur.Voice.Synthesizer do
  # owner receives {:voice_audio, :chunk, binary}, {:voice_audio, :done}, {:voice_audio, :error, String.t()}
  @callback start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, atom()}
end

defmodule Aiur.Voice do
  @type reason :: nil | :unconfigured | :not_installed
  @spec provider() :: module() | nil
  #   Application.get_env(:aiur, :voice_provider, Aiur.ElevenLabs); nil, or a module that
  #   Code.ensure_loaded?/1 rejects, means "not installed".
  @spec availability() :: %{available: boolean(), reason: reason()}
  @spec start_transcription(keyword()) :: {:ok, %{pid: pid(), module: module()}} | {:error, :not_installed | :unconfigured | term()}
  @spec push(%{pid: pid(), module: module()}, String.t()) :: :ok
  @spec commit(%{pid: pid(), module: module()}) :: :ok
  @spec stop(%{pid: pid(), module: module()}) :: :ok
  @spec start_speech(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, :not_installed | atom()}
end
```

Rationale:

- **One seam.** `:voice_provider` holds a module, never a credential. This
  keeps the rule in the `streamdeck_channel.ex:352-354` comment. T02 and T03
  replace the four endpoint-config seams with it.
- **The session carries its module.** The session map remembers the
  transcriber module, so a config change mid-session cannot redirect
  `push`/`commit`. This is the same rule as `streamdeck_channel.ex:366-368`.
- **The adapter emits neutral tags directly.** There is no translating process.
  This answers plan RQ1: the message path is unchanged, so latency is unchanged
  by construction. `streamdeck_voice_latency_test.exs` is `:external` and
  needs a live key; it only gets the rename.
- **`Aiur.ElevenLabs.configured?/0`** returns
  `present?(Config.elevenlabs_api_key())`. That is the same rule as
  `StreamdeckProjection.configured_elevenlabs_key?/0` (`streamdeck_projection.ex:46-58`),
  including rescue → `false`.
- **Invariants (contract V2, V4, V5):**
  - no audio is written to disk or logs (no `File.*` and no audio-bearing
    `Logger` call in the new modules);
  - no credential appears in any return value;
  - the facade never delivers text to an agent.

## Implementation steps

1. Add the four `Aiur.Voice*` modules and `Aiur.ElevenLabs` (about 120 lines of
   code plus docs).
2. In `realtime.ex`:
   - add `@behaviour Aiur.Voice.Transcriber` plus `@impl` on
     `start/push/commit/stop`;
   - rename the 9 tags.
3. In `tts.ex`:
   - add `@behaviour Aiur.Voice.Synthesizer` plus `@impl` on `start/3`;
   - rename the 7 tags.
4. Rename the receiving clauses in `voice_channel.ex:154-182` and
   `streamdeck_channel.ex:305-320,391-399`. Pattern bodies are unchanged; only
   the tag atom changes.
5. Rename the tags in the six test files listed above. No other fixture change.
6. Add the PROPOSED test `src/test/aiur/voice_test.exs` (below).

## Non-happy paths

- **No key:** `start_transcription/1` passes through `{:error, :unconfigured}`
  from `Realtime.start/1`. Callers still map it to today's text (T02, T03).
- **Provider unset (`nil`) or not loadable:** `{:error, :not_installed}` from
  `start_transcription/1` and `start_speech/3`. `availability/0` returns
  `%{available: false, reason: :not_installed}`. No production path reaches
  this until C3. The callers' handling and copy come in T04.
- **`configured?/0` raises:** return `false`, matching today's projection.
- **Stale messages:** the deck drain (`streamdeck_channel.ex:391-399`) must
  match the new tags. If it did not, a replaced session's transcript could be
  relabelled with the new session id. The existing test for this behaviour is
  renamed with the rest.

## Compatibility and rollout

- **Internal rename only.** Browser events (`transcript`, `error`, `stopped`,
  `audio`, `audio_done`, `audio_error`) and deck events (`voice`,
  `voice_error`, `voice_closed`) are unchanged.
- No config change. `:voice_provider` defaults to `Aiur.ElevenLabs` and is not
  an operator setting, so it gets no docs entry.
- Rollback means reverting the PR. No persisted state is involved.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/voice_test.exs test/aiur/eleven_labs/realtime_test.exs test/aiur/eleven_labs/tts_test.exs \
  test/aiur_web/voice_channel_test.exs test/aiur_web/streamdeck_channel_test.exs
env -C <worktree>/src mise exec -- mix compile --warnings-as-errors
```

New tests in `test/aiur/voice_test.exs` (`async: false`; each sets
`:voice_provider` and restores it in `on_exit`):

| Test | Fixture | Expected |
| --- | --- | --- |
| "availability is available when the provider reports a credential" | fake provider, `configured?` → true | `%{available: true, reason: nil}` |
| "availability is unconfigured without a credential" | fake, `configured?` → false | `%{available: false, reason: :unconfigured}` |
| "availability is not_installed without a provider" | `:voice_provider` = `nil` | `%{available: false, reason: :not_installed}` |
| "start_transcription returns not_installed without a provider" | `nil` | `{:error, :not_installed}` |
| "a session keeps the transcriber it opened with" | start with fake A, switch env to fake B, `push` | fake A receives the push; B does not |
| "the default provider is Aiur.ElevenLabs" | env unset | `Aiur.Voice.provider() == Aiur.ElevenLabs` |

Mutation checks (revert each; the tree is dirty only by that hunk):

- Make `availability/0` return `:unconfigured` for a nil provider. The
  "not_installed" tests fail.
- Have `push/2` re-read the provider instead of using `session.module`. The
  "keeps the transcriber" test fails.
- Revert the tag rename in `realtime.ex` only. The renamed `realtime_test.exs`
  assertions fail, because they `assert_receive {:voice_transcript, …}`.

## Completion and handoff

- [ ] `git grep -n ":elevenlabs_\(transcript\|error\|closed\|audio\)" -- src`
  is empty.
- [ ] The browser fixture server (`test/browser/fixture_server.exs`) still
  boots. Run one browser spec that uses dictation, if the implementer's
  environment has Playwright.
- [ ] Docs: none. The change is internal, and no operator-visible name changes
  (AGENTS.md: internal refactors need no docs).
- **Dependents:**
  - T02 and T03 (callers move to the facade);
  - MP-R1-C3-T2: the `voice.stt` capability callback should read
    `Aiur.Voice.availability/0`;
  - MP-E5 and MP-E6 build sessions on this port.
