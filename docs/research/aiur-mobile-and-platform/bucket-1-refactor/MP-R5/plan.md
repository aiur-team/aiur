---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-R5
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: ../../owner-design-tasks/DESIGN-R5.md
blockers:
  - MP-R1 package mechanism (in-repo optional Mix dependency vs umbrella app) for C3 only
  - Voice-session contract (owned by the MP-E5/E6 planner) must accept §5 needs before C1 fixes message names
---

# MP-R5 — Optional voice package around ElevenLabs speech-to-text

## Summary

ElevenLabs speech-to-text already works, holds its key only in the daemon,
degrades cleanly without a key, and never reaches agents directly: a human
presses Send. What is missing is **packaging**. The provider is called by name
from:

- two channels;
- one projection;
- one LiveView;
- the app supervisor;
- the config schema;
- `aiur init`.

Two different test seams exist (`:streamdeck_voice_session` and
`:voice_stt_start_fun`). "Voice module absent" has no code path.

MP-R5 does this, in order:

1. **C1:** puts one provider-neutral port, `Aiur.Voice`, between callers and
   ElevenLabs. This is an in-process seam (KTD11).
2. **C2:** moves config, `init`, quota and supervision ownership behind the
   port.
3. **C3:** once MP-R1 picks the package mechanism, moves the modules into an
   optional package and proves the absent-package path.
4. **C4:** documents capture, transport, transcription and delivery
   responsibilities.

User-visible behaviour does not change, with one exception: an "absent
package" message that DESIGN-R5 must approve.

Prior-units: U7 (duplicate path cuts) and U8 (sizes).

Prior-boundaries: `VOX` #36 ("package, optional. Depends only on CFG and the
web shell"), `CFG` #2, `WEB` #34, `SD` #35, `INI` #37.

Prior-features (keep decisions; raw cut and externalize overturned):

- `integrations-51` (STT, TTS, quota; keep the server-held credential)
- `ui-07` (dashboard voice)
- `ui-08` (realtime STT shared by both voice surfaces)
- `ui-09` (quota meter)
- `config-33` (`elevenlabs.*`)

Size-owner: `streamdeck_channel.ex` (609 lines) is `DECK_WEB`;
`dashboard_live.ex` (2,903) is `WEB`. Edits there must be net-neutral or
coordinate with the U8 split.

## 1. Repository findings (verified at `45a290e3`)

This extends `baseline/capability-baseline.md` § R5, which has the stage table.

### 1.1 Provider modules (9 Elixir files)

| File | Lines |
| --- | --- |
| `src/lib/aiur/eleven_labs/realtime.ex` | 421 |
| `realtime/{mint_socket,mint_transport,transport}.ex` | — |
| `tts.ex` | 135 |
| `quota.ex` | 296 |
| `src/lib/aiur/config/schema/eleven_labs.ex` | — |
| `src/lib/aiur/init/eleven_labs.ex` | — |

Realtime's public API (`realtime.ex:91-116`):

- `start/1` and `start_link/1` return `{:error, :unconfigured}` without a key
  (`:125-133`, `:300`).
- `push/2` takes base64 PCM.
- `commit/1` flushes.
- `stop/1` stops the session.
- Owner messages are sent by `notify/2` (`:389`): `{:elevenlabs_transcript,
  :partial | :final, text}`, `{:elevenlabs_error, reason}`, `{:elevenlabs_closed}`.
- The model `scribe_v2_realtime` and the URL are module attributes (`:53-54`).

### 1.2 Every caller of the provider (coupling census)

Command: `git grep -n -E "ElevenLabs\.|elevenlabs_" 45a290e3 -- src/lib`,
excluding the provider's own files.

| Caller | Coupling | Line |
| --- | --- | --- |
| `AiurWeb.VoiceChannel` | aliases `Realtime` and `TTS`; calls `Realtime.start/push/commit` directly; seam `:voice_stt_start_fun` | `voice_channel.ex:22`, `:90`, `:111`, `:199`, `:237-262` |
| `AiurWeb.StreamdeckChannel` | aliases `Realtime`; module seam `:streamdeck_voice_session` defaulting to `Realtime`; handles `{:elevenlabs_*}` | `streamdeck_channel.ex:7`, `:193-230`, `:305-320`, `:355-360`, `:393-395` |
| `AiurWeb.StreamdeckProjection.voice/0` | reads `Config.elevenlabs_api_key/0` (seam `:streamdeck_voice_available_fun`) | `streamdeck_projection.ex:34-56` |
| `AiurWeb.DashboardLive` | `Aiur.ElevenLabs.Quota.snapshot/0` on a 60 s tick | `dashboard_live.ex:19`, `:77`, `:128`, `:248-250`, `:2642` |
| `RunSummaryStrip` | renders the quota map | `components/operator_control_center/run_summary_strip.ex:30-393` |
| `Aiur` application | supervises `Aiur.ElevenLabs.Quota` unconditionally | `src/lib/aiur.ex:355` |
| `Aiur.Config` | `elevenlabs_api_key/0`, `_language_code/0`, `_voice_id/0` | `config.ex:329-340` |
| `Aiur.Config.Schema` | `cast_embed(:elevenlabs, …)` | `config/schema.ex:182` |
| `Aiur.Init`, `Init.Resume`, `Init.Templates` | prompt and YAML section | `init.ex:171`; `init/resume.ex:39,65-67,154-156`; `init/templates.ex:109,132-133` |

The browser side lives in `src/priv/static/conversation-voice-controller.js`
and `voice-capture-worklet.js`. They speak only to `/voice`, not to the
provider.

### 1.3 Absence behaviour today

- **No key:**
  - The dashboard join fails with "ElevenLabs speech-to-text is not
    configured…" (`voice_channel.ex:254`; test `voice_channel_test.exs:156`).
  - The deck `voice_start` replies `"unconfigured"` (test
    `streamdeck_channel_test.exs:1089-1095`).
  - The projection reports `available: false` with a reason
    (`streamdeck_projection.ex:35-41`).
  - Quota reports `:unconfigured`, and `snapshot/0` even rescues a missing
    process (`quota.ex:81-84`).
  - Text chat is a separate path (`Aiur.AgentChat.send/3`) and is untouched.
- **Module absent:** there is no path. Every caller would fail to compile.
- **Raw audio:** no `File.*` call and no audio-bearing `Logger` call in the
  voice modules or the channels (searched by grep at the base SHA). Audio
  lives only in process memory for the session. This matches D17.

### 1.4 Limits and seams worth keeping

| Limit | Value | Where |
| --- | --- | --- |
| Dashboard chunk | 256 KiB | `voice_channel.ex:29` |
| Dashboard session | 9.6 MB, about 5 min | `:31` |
| Concurrent dashboard sessions | capacity lease | `VoiceSessionLimiter.acquire/2`, `voice_session_limiter.ex:22-40` |
| Deck frame | 64 KiB | `streamdeck_channel.ex:16` |

The deck has a stale-frame guard: a session id pattern match
(`streamdeck_channel.ex:207-212`).

### 1.5 Unwired sidecar TTS

`packages/streamdeck/src/audio/elevenlabs-tts.ts` calls the ElevenLabs REST API
with a key. Only `audio/node-fetch.ts` imports it, and only for types. The
sidecar's `main.ts:320` and `audio/relay.ts:5` state the sidecar holds no key.
It is dead code that contradicts the key rule. Phase C confirms that it is
unreachable from `main.ts`.

## 2. Proposed boundary

```
callers (VoiceChannel, StreamdeckChannel, StreamdeckProjection, DashboardLive)
        │  Aiur.Voice (facade, always compiled in core)
        │    availability/0 -> %{available: bool, reason: nil | :unconfigured | :not_installed}
        │    start_transcription(owner, opts) -> {:ok, ref} | {:error, :unconfigured | :not_installed | term}
        │    push(ref, b64_pcm16) / commit(ref) / stop(ref)
        │    quota_snapshot/0 -> today's Quota map, or %{state: :unconfigured, …}
        ▼
Aiur.Voice.Transcriber (behaviour)      Aiur.Voice.Speaker (behaviour, TTS)
        ▼                                         ▼
Aiur.ElevenLabs.Realtime  (optional package aiur_voice_elevenlabs)  Aiur.ElevenLabs.TTS
```

- **Required dependencies of the voice package:** `Aiur.Config` (schema
  registration via the MP-R1 `CFG` mechanism) and the HTTP/WS client it
  already uses (Mint).
- **Not dependent on:** the web shell. The channels stay in `aiur_web` and talk
  only to `Aiur.Voice`.
- **Facade in core:** it resolves the provider through
  `Application.get_env(:aiur, :voice_provider)`. The default is
  `Aiur.ElevenLabs` when that module is loaded (`Code.ensure_loaded?/1`), else
  `:not_installed`.
- **One test seam:** the provider module replaces both existing endpoint-config
  seams. The seam carries a module, never a credential, which preserves the
  rule in the `streamdeck_channel.ex:352-354` comment.
- **Owner messages become neutral:** `{:voice_transcript, kind, text}`,
  `{:voice_error, reason}`, `{:voice_closed}`.
  - The ElevenLabs adapter emits them directly. Phase C must check whether a
    thin translating owner process would add latency for
    `streamdeck_voice_latency_test.exs`; if it would, the adapter emits the
    neutral tags itself.
  - This rename is internal: no channel event name visible to the browser or
    sidecar changes (`voice`, `voice_error`, `voice_closed`, `transcript`,
    `error` stay).
- **Delivery is not voice's job.** The transcript returns to the client, and
  the client sends through `Aiur.AgentChat.send/3`. That stays exactly as is.
  Executor targeting is E3/E5 scope.

## 3. Alternatives

| Option | Verdict |
| --- | --- |
| A. Leave `Aiur.ElevenLabs` in core; add only `available?/0` | Rejected. It meets "missing key" but not "absent module", and it leaves two seams. |
| B. Move the channels into the voice package too | Rejected. The channels also carry auth, CSRF, the session limiter and deck focus state (web shell concerns), and that would make the package depend on Phoenix. `VOX` #36 says depend only on CFG and the web shell, not the other way round. |
| C. A separate repository now | Rejected. Prior decision 11 / `ui-16`: there is no independent release until a versioned protocol exists. KTD11: in-process seam first. |
| **D. Facade and behaviours in core, ElevenLabs adapter as an optional in-repo package (C3 waits for R1)** | **Recommended.** It is behaviour-preserving, makes absence testable, and fits KTD11 and `VOX`. |

## 4. Responsibilities (deliverable for docs, C4)

| Stage | Owner after R5 | Notes |
| --- | --- | --- |
| Capture | Client: the browser worklet, or the sidecar `audio/capture.ts` (`parec`) | 16 kHz mono PCM16. Voice never touches devices. |
| Transport | `aiur_web` channels (`/voice`, `/streamdeck`) | Auth, size limits, the capacity lease and the stale-frame guard stay here. |
| Transcription | `Aiur.Voice` → provider adapter | The key is resolved in the daemon only. Audio and transcript go to ElevenLabs (cloud): **not local processing**. |
| Delivery to agent | Client, then `Aiur.AgentChat.send/3` → `Orchestrator.OperatorMessages` | A human confirms (Send). Voice has no agent-targeting knowledge. |
| Retention | None for audio | Transcripts persist only as normal chat messages. |

## 5. What the voice-session contract (MP-E5/E6 owner) must accept

The coordinator reconciles these. R5 does not write that contract.

1. **The transcription port** is the § 2 shape: a session per owner pid,
   base64 PCM16 at 16 kHz mono, `commit` flushes the tail, and the session
   closes itself after commit. E5/E6 sessions (dictate or converse, D16) are
   built **on** this port, not beside it.
2. **Availability** is one function with reasons `:unconfigured`,
   `:not_installed` and `nil`. Clients render capability absence from it, not
   from a failed join.
3. **Limits** (chunk, session bytes, concurrent leases) stay transport-side
   (`aiur_web`), not in the provider. The contract needs to state them per
   client type (browser, deck, later phone).
4. **The key never leaves the daemon.** No client, including a mobile app, ever
   receives a provider credential. The unwired sidecar TTS violates this, and
   C4 removes it.
5. **No raw audio retention (D17)** is an invariant of the port. Adapters must
   not write audio to disk or logs.
6. **Delivery stays outside voice.** If E5/E6 needs auto-submit (the existing
   `voice:conversation` already auto-submits after push-to-talk), that
   decision lives in the session layer that E5/E6 owns. The port stays a pure
   transcriber.
7. **Message tags** `{:voice_transcript | :voice_error | :voice_closed}` are
   proposed here. If the E5/E6 contract names them differently, C1 adopts
   those names. **C1 must not start until this is reconciled.**

## 6. Non-happy paths

| Case | Expected after R5 |
| --- | --- |
| No key | Identical to today: the same join error text, deck `"unconfigured"`, projection reason, quota `:unconfigured`. |
| Package not installed | Dashboard join error with new copy (DESIGN-R5). The deck replies `"not_installed"` and the projection gives `available: false` with a reason. There is no quota row. Text chat works. **New state; copy needs approval.** |
| Provider error mid-session | Today's `{:elevenlabs_error}` path, renamed. Clients show the same messages. |
| Credential rotated mid-session | The dashboard path rejects on generation change (`voice_channel.ex:44-50`). Unchanged. |
| Two deck holds | The second replaces the first (`streamdeck_channel.ex:193-200`). Unchanged. |
| Multiple browser tabs | Capacity lease. Unchanged. |

## 7. Acceptance criteria

1. No module outside the voice package references `Aiur.ElevenLabs.*`. CI
   asserts this with
   `git grep -n "ElevenLabs\." -- src/lib ':!src/lib/aiur/eleven_labs*' ':!<package path>'`,
   which must be empty, as a script check.
2. These existing tests pass with fixture changes limited to the seam swap
   (module injection) and the message-tag rename:
   - `voice_channel_test.exs`
   - `streamdeck_channel_test.exs`
   - `streamdeck_voice_latency_test.exs`
   - `eleven_labs/*_test.exs`
3. A new test sets `:voice_provider` to `nil` (simulating an absent package)
   and asserts:
   - (a) `Aiur.Voice.availability/0` returns `:not_installed`;
   - (b) the `/voice` join returns the approved copy;
   - (c) the deck `voice_start` replies `not_installed`;
   - (d) `AgentChat.send/3` still delivers a typed message.

   Mutation check: replace the `:not_installed` branch with `:unconfigured`.
   The test fails.
4. Under C3, `mix compile` of core with the voice package excluded succeeds
   (exact command per the MP-R1 mechanism).
5. The config keys `elevenlabs.api_key`, `language_code` and `voice_id`, and
   `ELEVENLABS_API_KEY`, are unchanged. `scripts/check-config-docs.py` passes.
6. `website/docs-app/apis/elevenlabs.md` carries the § 4 responsibility table.

## 8. Chunks

### MP-R5-C1 — `Aiur.Voice` port and facade (in-process)

- **Outcome:** every caller uses `Aiur.Voice`. There is one test seam, and an
  absent provider is a handled state.
- **Dependencies:** voice-session contract reconciliation (§ 5.7); DESIGN-R5
  copy for `:not_installed`.
- **Tickets:**
  - MP-R5-C1-T01: define the `Aiur.Voice.Transcriber` behaviour and the
    `Aiur.Voice` facade. Make the ElevenLabs Realtime adapter implement it with
    neutral tags.
  - MP-R5-C1-T02: move `VoiceChannel` to the facade and retire
    `:voice_stt_start_fun`.
  - MP-R5-C1-T03: move `StreamdeckChannel` to the facade and retire
    `:streamdeck_voice_session`. Coordinate with MP-R6-C3.
  - MP-R5-C1-T04: make `StreamdeckProjection.voice/0` delegate to
    `Aiur.Voice.availability/0`, keeping the wire shape
    `%{available, reason}`.
  - MP-R5-C1-T05: add the `Aiur.Voice.Speaker` behaviour for TTS and move
    `VoiceChannel`'s `TTS` use behind it.
- **Tests:** existing suites with seam swaps; a new absent-provider test
  (§ 7.3); a latency guard (`streamdeck_voice_latency_test.exs`).

### MP-R5-C2 — Config, init, quota and supervision ownership

- **Outcome:** the voice package owns its schema, `init` prompt and quota
  child. Core works when they are absent.
- **Dependencies:** C1; MP-R1 `CFG` schema-registration mechanism (`CFG` #2).
- **Tickets:**
  - MP-R5-C2-T01: register the `elevenlabs` embed through the R1 mechanism,
    with the same keys.
  - MP-R5-C2-T02: route the `init` prompt and YAML section through a voice
    contribution hook. The output stays byte-identical
    (`templates_test.exs`).
  - MP-R5-C2-T03: add the `Aiur.Voice.quota_snapshot/0` facade. Supervise
    `Quota` from the voice package's child spec. `DashboardLive` calls the
    facade.
- **Tests:** templates golden test; config schema test; dashboard quota row
  absent when not installed (mutation: return `:unknown` and the row appears).

### MP-R5-C3 — Physical optional package

- **Outcome:** the ElevenLabs adapter, Quota, TTS and the schema live in
  `aiur_voice_elevenlabs` (name per R1), excluded from core compile when
  absent.
- **Dependencies:** C1, C2; **MP-R1 package mechanism (blocker)**; U8 owners
  for touched >500-line files.
- **Tickets:**
  - MP-R5-C3-T01: move the files and wire the dependency.
  - MP-R5-C3-T02: add a CI job that compiles and tests core without the
    package.
  - MP-R5-C3-T03: release packaging includes the package by default. Whether
    the npm product ships with voice is an owner question.
- **Tests:** the § 7.4 compile and the § 7.1 grep gate.

### MP-R5-C4 — Docs and the dead sidecar TTS

- **Outcome:** responsibilities are documented; the key rule has no
  contradicting code.
- **Dependencies:** C1. Can follow C1 directly.
- **Tickets:**
  - MP-R5-C4-T01: add the responsibility table and the "cloud processing"
    statement to `website/docs-app/apis/elevenlabs.md`.
  - MP-R5-C4-T02: delete `packages/streamdeck/src/audio/elevenlabs-tts.ts` and
    its test, after Phase C confirms it is unreachable. Alternatively, record a
    U7 cut.
- **Tests:** sidecar `npm test`; package build test
  `scripts/test/build-package.test.mjs`.

## 9. Open questions

**Owner (Kevin):**

1. Copy for the "voice package not installed" state, on the dashboard mic and
   the deck mic key (DESIGN-R5).
2. Should the default npm `aiur` include the voice package (opt-in by key, as
   today), or must the user install it separately? The plan assumes it is
   included; the key is the opt-in.
3. Delete the unwired sidecar TTS (recommended), or keep it for a future
   on-deck TTS?

**Research (Phase C):**

- RQ1: Can the Realtime adapter emit neutral tags with no latency change?
  Measure with `streamdeck_voice_latency_test.exs`.
- RQ2: Where is `VoiceSessionLimiter` supervised, and does it stay in
  `aiur_web`?
- RQ3: Is `elevenlabs-tts.ts` unreachable from `main.ts`, by an import graph
  check?
- RQ4: What is the R1 mechanism for optional Mix dependencies inside one
  release (path dep with `optional: true`, or an umbrella app)?

## 10. Plan refresh

- After MP-R1: replace the "(name per R1)" placeholders with real package
  paths. Re-run the § 1.2 census at the implementation head; new callers may
  appear from E5/E6 work.
- After the E5/E6 contract is final: replace the § 5 proposals with links.
  Rename message tags if the contract differs.
