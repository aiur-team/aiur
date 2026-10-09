---
ticket_id: MP-E6-C2-T01
feature_id: MP-E6
chunk_id: MP-E6-C2
bucket: 2-platform
title: Conversation provider behaviour, normalized event structs and a fake provider
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend, DESIGN-E6 header)", MP-E6-C11-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C2-T01 — `Aiur.VoiceConversation.Provider`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C2 provider boundary.
- **User value:** none directly; it makes the assistant provider-replaceable (ElevenLabs now,
  OpenAI Realtime as the documented second adapter) and lets every later ticket be tested
  without a network or a bill.
- **Deliverable (all PROPOSED, `src/lib/aiur/voice_conversation/`):**
  - `provider.ex` — behaviour `Aiur.VoiceConversation.Provider`.
  - `events.ex` — structs for the contract §4.1 normalized events.
  - `src/test/support/voice_conversation/fake_provider.ex` — `Aiur.VoiceConversation.FakeProvider`
    implementing the behaviour, scriptable from tests.
- **Non-goals:** the ElevenLabs adapter (C2-T02/T03), sessions (C4).

## Dependencies and blockers

- **Predecessors:** MP-R5-C1-T01 (the `Aiur.Voice` facade exists; this namespace sits beside
  it in the voice component, `VOX`).
- **Contracts:** voice-session §4 (Conversation role), §4.1 (events).
- **May run concurrently with:** MP-E6-C6-T01, MP-E6-C2-T04.

## Verified starting point (base `45a290e3`)

- Seam precedent: a behaviour owning only the bytes, with the session owning decisions —
  `Aiur.ElevenLabs.Realtime.Transport` (`realtime/transport.ex:1-25`) and its Mint
  implementation (`realtime/mint_transport.ex:12-31`).
- Fake precedent in channels: `:voice_stt_start_fun` / `:voice_tts_start_fun` injection
  (`voice_channel.ex:235-291`), which MP-R5-C1 replaces with module injection.
- Test support directory exists: `src/test/support/` (used by `use Aiur.TestSupport`,
  e.g. `conversation_drawer_test.exs:2`).

## Chosen design

```elixir
defmodule Aiur.VoiceConversation.Provider do
  @type session_spec :: %{
          required(:owner) => pid(),                 # receives {:voice_conversation, ref, event}
          required(:system_prompt) => String.t(),    # role pre-context + glossary (C4-T04)
          required(:first_message) => String.t() | nil,
          required(:context) => String.t(),          # ContextBuilder output (C4-T03), already redacted
          required(:tools) => [tool_spec()],
          required(:audio_in) => :pcm_16000,
          required(:audio_out) => :pcm_16000 | :pcm_44100,
          optional(:voice_id) => String.t(),
          optional(:llm) => String.t()
        }
  @type tool_spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback open(session_spec()) :: {:ok, ref :: term()} | {:error, Events.Error.t()}
  @callback push_audio(ref :: term(), base64_pcm :: String.t()) :: :ok
  @callback send_context(ref :: term(), text :: String.t()) :: :ok      # non-interrupting
  @callback send_user_text(ref :: term(), text :: String.t()) :: :ok
  @callback tool_result(ref :: term(), call_id :: String.t(), result :: String.t()) :: :ok
  @callback close(ref :: term()) :: :ok
  @callback capabilities() :: %{events: [atom()], text_only?: boolean()}
end
```

- Owner messages: `{:voice_conversation, ref, %Events.X{}}` where X ∈ `UserTranscript{text,
  final?}`, `AgentText{turn_id, text, final?}`, `AgentAudio{turn_id, format, data_b64}`,
  `Interruption{turn_id}`, `ToolCall{call_id, name, params}`,
  `ProviderConversationId{id}`, `Closed{reason}`, `Error{code, message}`.
- `Error.code` ∈ contract §8 provider codes (`provider_auth`, `provider_quota`,
  `provider_unavailable`, `provider_error`); `message` is operator-safe text, never a raw
  provider frame (the realtime precedent discards raw error terms, `transport.ex:17-19`).
- `capabilities/0` lets a provider declare missing events (contract §4.1 last sentence);
  the session degrades (e.g. no `Interruption` → playback cannot be cut by the provider).
- **Invariant:** no provider event name or field leaks past the adapter; the session sees only
  these structs.
- `FakeProvider`: `open/1` returns a ref registered to the test pid; helpers
  `FakeProvider.emit(ref, event)` and `FakeProvider.calls(ref)` (records `push_audio`,
  `send_context`, `tool_result`, `close` with arguments) — the same "record what was sent"
  style the channel tests use for the fake transcriber.

## Implementation steps

1. `events.ex` structs with `@enforce_keys`.
2. `provider.ex` behaviour and types.
3. `fake_provider.ex` in test support (an `Agent` keyed by ref).
4. Unit tests for the fake (it is used by C4–C7 tests, so its semantics are pinned).

## Non-happy paths

n/a beyond the type contract — no runtime behaviour in this ticket. The `Error` struct is the
single path for provider failures.

## Compatibility and rollout

New modules, unused until C4. No config. Rollback: delete.

## Verification

| Test (`test/aiur/voice_conversation/fake_provider_test.exs`, PROPOSED) | Expected |
| --- | --- |
| "fake records every behaviour call in order" | `push_audio`, `send_context`, `tool_result`, `close` appear in `calls/1` with arguments |
| "emitted events reach the owner as normalized structs" | `{:voice_conversation, ref, %Events.AgentText{}}` received |
| "the behaviour module documents every §4.1 event" | `Events.__all__/0` (or a list constant) equals the contract list — a regression guard, labelled as such |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/fake_provider_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after: a local `mix test` boots aiur and can
overwrite it.

**Mutation check.** Make `FakeProvider.calls/1` drop `tool_result` entries: the first test
fails. (The structure tests are regression guards, not coverage of new behaviour.)

## Completion and handoff

- [ ] Behaviour, structs and fake; tests green; `make lint` clean.
- [ ] Docs: none (internal).
- **Dependents:** MP-E6-C2-T02, MP-E6-C2-T03, MP-E6-C4-T01, every later E6 test.

## Amendment 2026-10-08 — fast voice over a slow agent

Source: [../realtime-convo-research.md](../realtime-convo-research.md) (Kevin's request of
2026-10-08: voice with high-effort agents is "extremely slow and broken up"). Context-handoff
requirement: the voice assistant must be able to answer from a current briefing in about one
second, without stopping or waiting for the coding agent.

- The `ConversationProvider` behaviour gains one optional callback, `announce(session, text,
  when: :idle | :now)`: speak an aiur-originated line at the next pause (or now). ElevenLabs
  maps it to a `user_message`-style trigger or a client-tool result; OpenAI Realtime maps it to
  `conversation.item.create` + `response.create`; Gemini Live to a NON_BLOCKING function
  response with `scheduling: WHEN_IDLE`. The spike (MP-E6-C1-T01) confirms the mapping.
- Keep the behaviour provider-neutral: MP-E6-C1-T01 now compares ElevenLabs Agents and OpenAI
  Realtime, and the winner may be either.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.Provider`, `VoiceConverse.Events`, and
  `VoiceConverse.Testing.FakeProvider`. The fake moves to the package's `lib/` (not
  `test/support`), so any host can use it in its own tests.
- `session_spec` gets the key `credentials: {module, provider_id}`. The adapter calls
  `Credentials.fetch/2` at connect time. It never puts a key in `session_spec` or in state.
- Predecessor changes from MP-R5-C1-T01 to **MP-E6-C11-T01** (package skeleton). The
  behaviour no longer sits beside `Aiur.Voice`, so MP-R5 does not block it.
- Add a provider conformance suite (`VoiceConverse.Testing.ProviderConformance`), driven by
  recorded fixtures. Every adapter (C2-T02/T03, C11-T06) must pass it.
