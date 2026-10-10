---
ticket_id: MP-E6-C2-T02
feature_id: MP-E6
chunk_id: MP-E6-C2
bucket: 2-platform
title: ElevenLabs Agents adapter — connect, authenticate, relay audio, close (daemon-held websocket)
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T01, MP-E6-C11-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new file, target < 400 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C2-T02 — `Provider.ElevenLabsAgents` connection layer

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C2.
- **User value:** the daemon can hold an ElevenLabs Agents conversation without the browser,
  phone or watch ever seeing the key or the signed URL (V4).
- **Deliverable:** `Aiur.VoiceConversation.Provider.ElevenLabsAgents` (PROPOSED,
  `src/lib/aiur/voice_conversation/provider/eleven_labs_agents.ex`) implementing `open/1`,
  `push_audio/2`, `send_context/2`, `send_user_text/2`, `close/1`, with these frames:
  `conversation_initiation_client_data` (overrides), `user_audio_chunk`,
  `contextual_update`, `user_message`, `pong`. Inbound mapping of the **connection-level**
  events only (`conversation_initiation_metadata` → `ProviderConversationId`; `ping` → reply
  `pong`; close/errors → `Closed`/`Error`). Content events and tools are C2-T03.
- **Non-goals:** event mapping for transcripts/audio/tools (C2-T03, waits on spike
  fixtures); `DELETE` (C2-T04); provisioning (C3).

## Dependencies and blockers

- **Predecessors:** MP-E6-C2-T01; MP-R5-C1-T01 (key resolution through the voice facade's
  config access; until then `Aiur.Config.elevenlabs_api_key/0`, `config.ex:329-330`).
- **Spike:** RQ-E6-1 may show header auth works. This ticket implements the **documented**
  path (signed URL fetched by the daemon), which works either way; if the spike shows header
  auth works, C2-T03 may switch with a one-function change. Not a blocker.
- **May run concurrently with:** MP-E6-C2-T04, MP-E6-C6-*.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Credential handling rules | key in header only, resolved inside connect and discarded, failure values never logged (`realtime.ex:21-36,122-140`) |
| Transport behaviour to reuse | `connect(url, headers)`, `send_text/2`, `close/1`; inbound `{:elevenlabs_transport, :text \| :closed \| :error, …}` (`realtime/transport.ex:10-25`); Mint implementation (`mint_transport.ex:16-30`) |
| HTTP client | `{:req, "~> 0.7"}` and `{:mint_web_socket, "~> 1.0"}` (`src/mix.exs:164-165`) |
| Redaction of URL-borne capabilities | `Aiur.SecretRedactor.redact_urls/1` (`secret_redactor.ex:56-60`) |

External (accessed 2026-10-06, see `../provider-research.md` §2): signed URL endpoint
`GET /v1/convai/conversation/get-signed-url?agent_id=…`
(<https://elevenlabs.io/docs/api-reference/conversations/get-signed-url>); websocket
`wss://api.elevenlabs.io/v1/convai/conversation?agent_id=…` and client→server event names
(<https://elevenlabs.io/docs/agents-platform/api-reference/agents-platform/websocket>);
overrides must be enabled per field (<https://elevenlabs.io/docs/agents-platform/customization/personalization/overrides>).

## Chosen design

- One GenServer per conversation, started by `open/1` (unlinked; the session monitors it,
  like `Realtime.start/1`, `realtime.ex:86-92`).
- `init`: fetch the signed URL with `Req.get/2`, header `xi-api-key`, timeout 5 s; keep the
  URL only in the `handle_continue` that calls `transport.connect(url, [])`; **never** store
  it in state (`:sys.get_state/1` must not show it) and never put it in an error.
- After connect, send `conversation_initiation_client_data` with
  `conversation_config_override.agent.prompt.prompt = system_prompt <> "\n\n" <> context`,
  `first_message`, optional `tts.voice_id`, and `dynamic_variables` none (V4: no secrets
  needed). Audio formats come back in `conversation_initiation_metadata`; if the agent's
  output format is not the requested one, emit `Error{code: :provider_error, message:
  "Voice assistant audio format mismatch."}` and close (C3's setup fixes the agent config).
- `push_audio/2` → `{"user_audio_chunk": b64}`; before metadata arrives, buffer up to
  426,668 base64 bytes (the realtime backlog cap, `realtime.ex:62`) then fail with
  `provider_unavailable`.
- Transport injected via `opts[:transport]` (default `MintTransport`) and `opts[:http]` for
  the signed-URL fetch, so tests need no network.
- Errors: HTTP 401/403 → `provider_auth`; 429 → `provider_quota`; timeouts/5xx →
  `provider_unavailable`; anything else → `provider_error` (cause-neutral).

## Implementation steps

1. GenServer skeleton with injected transport/http.
2. Signed-URL fetch + connect in `handle_continue`; discard URL.
3. Outbound frame encoders; `ping`→`pong`.
4. Inbound connection-level mapping; unknown event types are ignored here and handled in
   C2-T03 (log type name only at `:debug`).
5. Tests.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| No key | `open/1` → `{:error, %Error{code: :unconfigured}}` without any request |
| Signed-URL fetch fails | `Error` with the mapped code; no socket opened |
| Socket closes before metadata | `Closed{reason: :provider_error}` |
| Owner dies | adapter monitors the owner and closes the socket |
| Crash | the GenServer's state holds no key or URL, so a crash report cannot leak them |

## Compatibility and rollout

New module; unused until C4. No config. Rollback: delete.

## Verification

| Test (`test/aiur/voice_conversation/provider/eleven_labs_agents_test.exs`) | Expected |
| --- | --- |
| "fetches a signed URL with the key header and connects to it" | fake http sees `xi-api-key`; fake transport `connect` receives the URL |
| "the signed URL is never in state, logs or errors" | after connect, `:sys.get_state/1` inspected string lacks the URL; `capture_log` lacks it; a forced connect error's `Error.message` lacks it |
| "initiation frame carries the overrides" | first `send_text` JSON has `type: "conversation_initiation_client_data"` and the prompt containing the context |
| "audio before metadata is buffered then flushed in order" | three pushes before metadata → three `user_audio_chunk` frames after, in order |
| "ping is answered with pong" | inbound ping with `event_id` 7 → outbound pong with 7 |
| "401 maps to provider_auth, 429 to provider_quota, an unknown status to provider_error" | table test |
| "no key never makes a request" | fake http call count 0 |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/provider/eleven_labs_agents_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Store the URL in state: the "never in state" test fails. Map unknown
statuses to `provider_unavailable`: the table test fails (collapsed-cause rule).

## Completion and handoff

- [ ] Adapter connection layer with injected transport and http; tests green.
- [ ] Docs: none yet (MP-E6-C9-T01 documents the Agents permission).
- **Dependents:** MP-E6-C2-T03, MP-E6-C2-T04, MP-E6-C3-T02.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.Provider.ElevenLabsAgents`. The key comes from the `Credentials`
  port (plan §17.4), not from `Aiur.Config.elevenlabs_api_key/0`. The aiur implementation of
  that port (C11-T04) reads the MP-R5 voice facade.
- Log redaction uses the core redactor hook. The test asserts that neither the key nor the
  signed URL appears in any log line or crash reason.
- Predecessor MP-R5-C1-T01 is replaced by MP-E6-C11-T01. The OpenAI Realtime / GPT-Live
  adapter is C11-T06. If GPT-Live wins the bake-off (C1-T01), the two tickets swap targets.

## Amendment 2026-10-10 — /talk and native providers

Source: [../plan.md](../plan.md) §19 (/talk skill) and §20 (native providers and preferences). Kevin, 2026-10-10 (verbatim): "earlier i asked about making convo mode usable by executors, i even want to usable by any agent via a skill separate from aiur" and "just to flag, i originally said i only wanted air convo to support eleven, this means full support for native model convo wrappers to use model APIs in aiur too and .config settings to choose preferences".

- ElevenLabs Agents is now the option `elevenlabs_agents` in the registry (C14-T01); it stays the default third-party provider. Use the WebSocket transport (not WebRTC) because only the WebSocket `audio` event carries character alignment (research §1.4); map it to `AgentTextTiming`.
