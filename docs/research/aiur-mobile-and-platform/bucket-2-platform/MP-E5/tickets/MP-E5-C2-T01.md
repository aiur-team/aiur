---
ticket_id: MP-E5-C2-T01
feature_id: MP-E5
chunk_id: MP-E5-C2
bucket: 2-platform
title: voice:dictate topic with a validated v1 join payload and stable reason_code on every error
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: backend; message text unchanged)", MP-R5-C1-T02]
prior_units: [U8]
prior_boundaries: [VOX, WEB, DEC]
prior_features: [ui-07, ui-08, integrations-51]
prior_findings: []
size_owner: WEB (voice_channel.ex is 331 lines; target validation goes to a new module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C2-T01 — Target-aware `voice:dictate` join and `reason_code`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C2 target-aware dictate channel.
- **User value:** a dictation aimed at an agent that has stopped, or at a Command that was
  already resolved, is refused **before** recording starts, with a reason a client can
  translate (phone, watch, dashboard), instead of failing only when the human presses Send.
- **Deliverable:**
  1. `voice:dictate` topic on `AiurWeb.VoiceSocket`; `voice:dictation` kept as an alias.
  2. Join payload v1 (contract §3.2) validated by a new `AiurWeb.VoiceTargets` (PROPOSED,
     `src/lib/aiur_web/voice_targets.ex`).
  3. Every `error`/`audio_error` push and every join refusal carries `reason_code` (contract
     §8) next to the unchanged `reason` text.
- **Non-goals:** delivery (the surface's own Send stays the only delivery, V7); `cancel`
  (C2-T02); render-time availability (C2-T03); device sockets (C8); Executor target
  validation beyond refusing it (`unsupported_target`) until MP-E5-C5-T02.

## Dependencies and blockers

- **Predecessors:** MP-R5-C1-T02 (`VoiceChannel` on the `Aiur.Voice` facade; neutral
  `{:voice_transcript | :voice_error | :voice_closed}` messages, RC-14).
- **Contracts:** voice-session §3.2, §3.4, §5.1, §8; identity target shapes (RC-02).
- **Contract request R-1 accepted (Phase D):** MP-R5-C1-T01 emits
  `{:voice_error, %{code: atom, message: binary}}` (voice-session §4). This ticket reads
  `code` and keeps the text-mapping table only as the fallback for a bare string.
- **May run concurrently with:** MP-E5-C1-*, MP-E5-C2-T03, MP-E5-C8-T01 (touches the socket
  module list only).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Topics | `voice_socket.ex:17-18` (`voice:dictation`, `voice:conversation`) |
| Join | `voice_channel.ex:33-62`: writable check, auth generation, limiter; refusal texts at `:54-56`; `:60` `unauthorized`; `:62` `invalid_topic`. The payload is ignored (`_payload`, `:36`) |
| Error pushes | `:93` five-minute limit; `:98` decode errors (`:316-326`: "Audio chunk is too large.", "Audio chunk encoding is invalid."); `:104`; provider errors `:159-162`; start failures `:253-266`; TTS errors `:141,147,180,308-314` |
| Provider error texts | `realtime.ex:402-409` `describe_failure/2` |
| Worker target rule | `agent_log_modal.ex:68-82` `find_running_entry/2`; uniqueness `:173-179` (`unique_identifier?/2`, private); the drawer and modal gate Send on it (`dashboard_live.ex:647`) |
| Payload source | `AiurWeb.OperatorControlCenter.PayloadLoader.load/1` (`payload_loader.ex:14-30`), the same cached payload `DashboardLive.mount/3` uses (`dashboard_live.ex:120`) |
| Command target | `Aiur.DecisionStore.get/2` → `{:ok, %Aiur.Decision{decision_status, version}}` or `{:error, :not_found}` (`decision_store.ex:387-390`; `decision.ex:168-184`); answerable statuses `[:open, :deferred, :dismissed]` (`decision_action.ex:20`) |
| Tests | `src/test/aiur_web/voice_channel_test.exs` (setup `:76`, socket/join tests `:122-180`, error relay `:381`) |

## Chosen design

### Join handling

```text
join("voice:dictate" | "voice:dictation", payload, socket):
  base checks (unchanged order): writable → auth generation → limiter lease
  then case payload:
    %{} with no "v"              -> legacy join: no target check (today's browser)
    %{"v" => 1, "mode" => "dictate", "surface" => s, "target" => t, "client_session_id" => id}
                                 -> VoiceTargets.validate(t, s) → :ok | {:error, code}
    anything else                -> {:error, %{reason: "Voice request is invalid.", reason_code: "invalid_payload"}}
  on :ok -> start transcription (unchanged)
```

- The lease is acquired before target validation, as today, and released on any refusal
  (existing pattern `voice_channel.ex:77-79`).
- `voice:conversation` (legacy auto-submit) is untouched by this ticket.

### `AiurWeb.VoiceTargets.validate/2` (PROPOSED)

| Target `kind` | Allowed surfaces | Rule | Refusal codes |
| --- | --- | --- | --- |
| `worker` `{ticket}` | `agent_composer` | `PayloadLoader.load(:cached)`; exactly one running entry whose `issue_identifier` equals `ticket` (the drawer's rule) | `target_not_found` (no entry), `target_not_writable` (more than one entry) |
| `command` `{decision_id, expected_version?}` | `command_response` | `DecisionStore.get/2`; status in `[:open, :deferred, :dismissed]`; if `expected_version` is given and differs → stale | `target_not_found`, `target_stale` |
| `executor` | `executor_composer` | refused until MP-E5-C5-T02 | `unsupported_target` |
| other | — | — | `invalid_payload` |

To avoid a second copy of the uniqueness rule, make it public:
`AgentLogModal.unique_running_target?(payload, identifier) :: boolean` (rename of the private
`unique_identifier?/2`, `agent_log_modal.ex:173-179`, which keeps its `nil → true` clause for
existing callers; `VoiceTargets` calls it with a loaded payload and also requires
`find_running_entry/2` to be non-nil).

`instance_id` in the target is accepted and compared to this instance's id when MP-R1-C2's
identity is available; until then it is ignored. A mismatch returns `target_not_found`.

### `reason_code` mapping (contract §8)

| Today's text (location) | `reason_code` |
| --- | --- |
| "Dashboard writing is disabled." (`:54`) | `read_only` |
| "Too many dashboard dictation sessions are active…" (`:55`) | `capacity` |
| "Dashboard authentication changed…" (`:56`); `unauthorized` (`:60`) | `auth_changed` |
| `invalid_topic` (`:62`) | `invalid_payload` |
| "Dictation reached the five-minute limit…" (`:93`) | `session_limit` |
| "Audio chunk is too large." (`:318,322`) | `chunk_too_large` |
| "Audio chunk encoding is invalid." (`:104,323`) | `invalid_payload` |
| "ElevenLabs speech-to-text is not configured…" (`:254`) | `unconfigured` |
| `{:error, :not_installed}` from the facade (MP-R5) | `not_installed` |
| "Speech-to-text could not start…" / "…is unavailable right now." (`:258,263,266,278,281`) | `provider_unavailable` |
| provider "ElevenLabs rejected the API key" (`realtime.ex:402`) | `provider_auth` |
| "ElevenLabs quota exhausted", "…rate limit reached", "…terms not accepted…" (`:403-406`) | `provider_quota` |
| "ElevenLabs session time limit reached" (`:407`) | `session_limit` |
| any other provider text | `provider_error` (cause-neutral, never a specific class) |
| TTS `:unconfigured` / `:capacity` / `:empty_text` / `:text_too_large` / other (`:308-314`) | `unconfigured` / `capacity` / `invalid_payload` / `invalid_payload` / `provider_error` |

The mapping is one private function `reason_code/1` in `VoiceChannel`. Request R-1 is
accepted (see Dependencies), so provider errors use the carried `code`; this text table is
only the fallback for a sender that still passes a bare string, and is deleted once no such
sender remains. Every code it produces is a row of voice-session §8.1, the client table that
gives retry eligibility (Phase D, M7).

## Implementation steps

1. `voice_socket.ex`: add `channel("voice:dictate", AiurWeb.VoiceChannel)`.
2. `voice_channel.ex`: extend the join guard to `["voice:dictate", "voice:dictation",
   "voice:conversation"]`; add payload parsing and the `VoiceTargets` call for the two
   dictate topics; assign `voice_target` and `voice_surface` (used by C2-T02 logs and C6).
3. Add `reason_code` to every refusal map and every pushed `error`/`audio_error` payload.
4. Create `voice_targets.ex`; make `AgentLogModal.unique_running_target?/2` public.
5. Tests below.

## Non-happy paths

- Payload loader returns an error payload (`%{error: %{code: "snapshot_unpublished"}}`,
  `presenter.ex:29-33`): no running entries → `target_not_found`. The message text says
  "This agent is not running." — **copy for DESIGN-E5**; until approved, reuse
  `AgentLogModal.format_error(:no_running_agent)` "Agent is no longer running."
  (`agent_log_modal.ex:132`).
- `DecisionStore` exit: rescued as `{:error, :store_unavailable}` like
  `decision_commands.ex:173-177` → `reason_code: "unknown"` (we cannot tell the target's
  state; never `target_not_found`).
- Race: the target ends after a successful join. Not detected by this ticket; the Send path
  refuses as today (`format_error(:no_running_agent)`). C6-T03 shows that result.
- Privacy: target ids are not secrets; nothing new is logged except `Logger.debug` of the
  refusal code (no text, no audio).

## Compatibility and rollout

- Old browser JS (payload `{}`) keeps working on `voice:dictation` and `voice:dictate`.
- New clients send `v: 1`. The alias `voice:dictation` is removed in a later release after
  every shipped client uses `voice:dictate` (tracked in C7-T01's checklist).
- No config or flag. Rollback: revert; old clients unaffected.

## Verification

New tests in `voice_channel_test.exs` and `test/aiur_web/voice_targets_test.exs` (PROPOSED):

| Test | Expected |
| --- | --- |
| "voice:dictate joins with an empty payload like voice:dictation" | `{:ok, _, _}` and the fake transcriber starts |
| "a v1 worker target that is not running is refused before transcription starts" | `{:error, %{reason_code: "target_not_found"}}`; fake transcriber start count 0; lease released (a third join succeeds) |
| "a v1 worker target with two running entries is not writable" | `target_not_writable` |
| "a v1 command target that is resolved is stale" | decision with `decision_status: :resolved` → `target_stale` |
| "a v1 command target with a moved version is stale" | `expected_version: 3`, store version 4 → `target_stale` |
| "an executor target is unsupported in this build" | `unsupported_target` |
| "a malformed payload is invalid" | `%{"v" => 2}` → `invalid_payload` |
| "every pushed error carries a reason_code" | table-driven over the mapping above: e.g. `{:voice_error, "ElevenLabs quota exhausted"}` → push has `reason_code: "provider_quota"` and the unchanged `reason` |
| "an unclassified provider error is provider_error, not a specific cause" | `{:voice_error, "socket reset"}` → `provider_error` |
| "a store exit is unknown, not target_not_found" | store stub exits → `unknown` |
| existing `voice_channel_test.exs` tests (`:122-405`) | pass with `reason` text unchanged |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_channel_test.exs test/aiur_web/voice_targets_test.exs test/aiur_web/operator_control_center/agent_log_modal_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after: a local `mix test` boots aiur and can
overwrite it.

**Mutation checks.** (1) Replace `VoiceTargets.validate/2`'s worker clause with `:ok`: the
"not running" test fails. (2) Replace the unknown-provider-text branch with `"provider_quota"`:
the "unclassified provider error" test fails (AGENTS.md collapsed-cause rule). (3) Replace the
store-exit branch with `target_not_found`: the "store exit" test fails. (4) Skip the lease
release on refusal: the "lease released" assertion fails.

## Completion and handoff

- [ ] Topic, payload validation, `reason_code` everywhere; legacy joins unchanged.
- [ ] Docs: none user-facing (codes are a client contract, documented in
      `contracts/voice-session.md` §8).
- **Dependents:** MP-E5-C2-T02, MP-E5-C4-T01, MP-E5-C5-T01, MP-E5-C5-T02, MP-E5-C6-T01,
  MP-E5-C8-T01, MP-N6-C4, MP-N7.
