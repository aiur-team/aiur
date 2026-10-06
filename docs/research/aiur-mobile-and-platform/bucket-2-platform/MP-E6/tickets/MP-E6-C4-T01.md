---
ticket_id: MP-E6-C4-T01
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: Conversation session process, supervision, state machine, limits and end reasons
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T01, MP-E6-C6-T01, MP-E6-C2-T04, MP-E6-C3-T01, MP-E6-C3-T03]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new files; session.ex target < 450 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T01 — `VoiceConversation.Session`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4 session manager and context builder.
- **User value:** one well-behaved daemon process per conversation: it ends on time, on
  silence, on target loss or on revocation, saves the transcript before telling any client
  anything, and cleans up the provider copy.
- **Deliverable (PROPOSED):** `Aiur.VoiceConversation.Session` (GenServer),
  `SessionSupervisor` (DynamicSupervisor), `Registry` (by `conversation_id`), and the public
  API `start_session(target, role_id, client) -> {:ok, conversation_id} | {:error, code}`,
  `push_audio/2`, `end_session/2`, `subscribe/1` (the channel process subscribes to events).
- **Non-goals:** context content (C4-T03), tools (C5), transcript format details (C6-T01
  writer), channel (C7-T01).

## Dependencies and blockers

- **Predecessors:** C2-T01 (provider behaviour + fake), C6-T01 (transcript writer), C2-T04
  (cleanup queue), C3-T01 (limits config), C3-T03 (preflight).
- **Contracts:** voice-session §6 state table, §9 write rule.

## Verified starting point (base `45a290e3`)

- Supervision placement: voice-related children are started from the application child list
  (`Aiur.ElevenLabs.Quota`, `src/lib/aiur.ex:355`); MP-R5-C2-T03 moves voice children into
  the voice package's child spec — the session supervisor joins that spec.
- Lease limiter: `AiurWeb.VoiceSessionLimiter.acquire/2` with owner monitor
  (`voice_session_limiter.ex:22-56`). The session lives in core (`Aiur.*`) and must not call
  `AiurWeb`; the **channel** (C7-T01) acquires the lease and passes ownership, keeping layers
  clean (MP-R5 §2: limits stay transport-side).

## Chosen design

- **Start sequence:** validate target via the read port (C4-T02) → `Preflight.check/1` →
  daily-cap check (sum of today's session durations from the transcript index, C6-T02) →
  `TranscriptStore.open(conversation_id, session_started{…})` (fsync) → `ContextBuilder`
  (C4-T03) → `Provider.open/1`. Any failure returns its contract §8 code and writes
  `session_ended{reason}` if the transcript was opened.
- **State machine:** exactly contract §6 table; state is pushed to subscribers as
  `{:voice_conversation_state, id, state}` after the transcript append.
- **Persist-before-notify:** every `UserTranscript{final?: true}`, `AgentText{final?: true}`,
  tool call/result, context block and draft change is appended and fsynced, then broadcast
  (contract §9). Partials and audio are broadcast only (never stored, V2).
- **Timers:** idle (no final user transcript and no agent speech for
  `idle_timeout_seconds`) → `idle_timeout`; hard `max_session_seconds` → `max_duration`;
  `daily_minutes_cap` reached mid-session → `cost_cap` at the next turn boundary.
- **End:** close provider → append `session_ended{reason, at}` (fsync) →
  `ProviderCleanup.enqueue/2` → broadcast `ended` → stop. End reasons per contract §6.
- **Reconnect:** on unexpected provider close: state `reconnecting`, one new
  `Provider.open/1` with context rebuilt from the transcript tail; failure → `error` →
  `ended{provider_error}`.
- **Crash safety:** the process holds no key or URL; restart strategy `:temporary` (a crashed
  session ends; the transcript up to the crash is durable; the channel reports
  `transport_lost`).

## Implementation steps

1. Supervisor, registry, session GenServer with injected provider module, clock and stores.
2. Start sequence and failure mapping.
3. Event handling, persist-before-notify, state transitions.
4. Timers and end sequence; reconnect once.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Target gone mid-session (port reports ended) | `ended{target_gone}` |
| Subscriber (channel) dies | session ends with `transport_lost` after 10 s grace (allows a reconnecting client to resubscribe with its `client_session_id`) |
| Disk write fails | session ends `unknown`; nothing broadcast for the unwritten event |
| Two sessions same target | allowed (MP-E6 plan §8); separate ids |
| Daemon stop | `terminate/2` best-effort appends `session_ended{transport_lost}`; cleanup enqueue is persisted |

## Compatibility and rollout

Inert until the channel (C7-T01) calls it. Rollback: revert.

## Verification

| Test (`test/aiur/voice_conversation/session_test.exs`, FakeProvider) | Expected |
| --- | --- |
| "a final user turn is on disk before subscribers hear of it" | subscriber kills itself on receipt; the transcript file already has the `user_turn` record |
| "audio and partials are never written" | filesystem spy: no write containing audio bytes; no partial text in the file |
| "idle timeout ends the session with idle_timeout and enqueues provider deletion" | injected clock |
| "max duration ends with max_duration" | as above |
| "a failed preflight never opens the provider" | FakeProvider `open` count 0; reason `privacy_preflight_failed` |
| "unexpected provider close reconnects once then errors" | two closes → `ended{provider_error}`; `open` count 2 |
| "state transitions follow contract §6" | scripted events → states sequence equals the table |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/session_test.exs
make -C src fmt-check lint
```

Temp state dir via `:decision_state_dir` app env. Run in an implementation worktree with
`GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check `~/.aiur/github-budget/agent-token` before
and after.

**Mutation checks.** Broadcast before append: the first test fails. Skip `enqueue` on end:
the idle test fails.

## Completion and handoff

- [ ] Session lifecycle complete with fakes; tests green.
- **Dependents:** C4-T02..T06, C5-*, C7-T01, C8-T02.
