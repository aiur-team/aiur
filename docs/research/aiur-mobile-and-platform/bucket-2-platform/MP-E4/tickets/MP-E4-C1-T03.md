---
ticket_id: MP-E4-C1-T03
feature_id: MP-E4
chunk_id: MP-E4-C1
bucket: 2-platform
title: "Worker tee: journal every worker transcript record from the three daemon ingest points"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T02]
prior_units: [U4]
prior_boundaries: [RUN, CDX, CLD]
prior_features: [MP-R7 (harness adapter: the tee moves with MessageHandler)]
prior_findings: [contract conversations-transcripts-anchors §5, §6 "Ingest points"; RQ-E4-5]
size_owner: "U8 RUN owner (message_handler.ex 671 lines, session_lifecycle.ex: keep net additions small)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C1-T03 — Worker tee

## Identity and outcome

- Bucket 2 · MP-E4 · C1 · T03.
- **User value:** a worker's full conversation is kept after its workspace is
  removed and after a daemon restart (plan acceptance 1).
- **Deliverable:** every daemon-run worker's transcript record and every
  operator delivery is cast to `Aiur.Conversation.Ingest`, for every backend,
  local and SSH, with no synchronous disk I/O on the agent message path.
- **Non-goals:** the Executor (MP-E3), history before the journal (C8-T01),
  changing `LiveConversation`, `IssueLog` or `AgentEventLog`.

## Dependencies and blockers

- DESIGN-E4; MP-E4-C1-T02.
- MP-R7: if R7 has landed, the three call sites live in the harness-adapter
  package and the tee becomes a subscription to its normalized transcript
  stream (plan §11). Re-read R7's tickets at pickup; the behaviour below is
  unchanged either way.
- Concurrent with: C2-T01, C3-T01.

## Verified starting point

Three daemon-side points see transcript records (contract §6):

1. **Per-message closure** `MessageHandler.build/7`
   (`src/lib/aiur/agent_runner/message_handler.ex:34-64`): normalizes, builds
   `transcript_event` (`:293-298`), writes `AgentEventLog` (which skips remote
   hosts, `agent_event_log.ex:24`), broadcasts, and feeds `LiveConversation`
   unless the display tailer is authoritative (`:104-115`, `:504-505`).
2. **Remote-Control display path** `SessionLifecycle.display_tailer_handler/3`
   (`agent_runner/session_lifecycle.ex:741-765`). It deliberately bypasses the
   closure ("Do NOT route through codex_message_handler", `:700-704`), handles a
   `:display_backfill` branch (broadcast only) and a live branch
   (`MessageHandler.observe_display_transcript/4`, `message_handler.ex:218-239`).
   Bodies are capped at 8,000 bytes by `DisplayTailer` (`claude/display_tailer.ex:36,301-322`).
3. **Operator delivery** `MessageHandler.observe_operator_delivery/4`
   (`message_handler.ex:173-216`), called from `checkpoint_delivery.ex:218,231`,
   `queue_drain.ex:803` and the display path (`session_lifecycle.ex:818-829`).
   It builds `msg_id: "operator:#{request_id}"`; `request_id` is the
   `AgentChat.send/3` queue id (`agent_chat.ex:12-19`).

Session data available in `opts`: `:session_id` (provider thread id,
`session_lifecycle.ex:487-492`), `:attempt_id` (`message_handler.ex:70,455`),
`:resumed` (`session_lifecycle.ex:443-446`). Session end:
`MessageHandler.finish_live_conversation/4` (`message_handler.ex:254-260`),
called at `session_lifecycle.ex:456-461`.

Codex command and reasoning transcript events carry no `msg_id`
(`codex/transcript.ex:55-70`); the raw message keeps the item id at
`payload.params.item.id`.

## Chosen design

A single private helper in `MessageHandler`, invoked from all three points:

```elixir
@spec journal(Issue.t(), map(), String.t(), keyword()) :: :ok
def journal(issue, transcript_event, backend, opts)   # @doc false; never raises
  # 1. skip when opts[:conversation_journal] == :disabled (tests, R7 move)
  # 2. Ref.worker(Issue.tracker_identity(issue)) — :unjoinable → count + :ok
  # 3. source = %{harness: backend, role: :worker,
  #              provider_session_id: opts[:session_id], aiur_attempt_id: live_attempt_id(opts),
  #              transcript_source: %{kind: opts[:journal_source_kind] || :aiur_ingest, locator_hash: nil},
  #              start_reason: if(opts[:resumed], do: :resume, else: :spawn)}
  # 4. Ingest.append(ref, source, [Map.put(transcript_event, :provider_item_id, opts[:provider_item_id])])
```

- **Closure (1):** after `maybe_observe_live_conversation/3`, call
  `journal/4` unless `display_tailer_authority?(opts)` (that worker's
  conversation comes from point 2; the closure only sees hook skeletons).
  Pass `provider_item_id` extracted from the raw message
  (`MapAccess.get` of `payload.params.item.id`) so Codex commands get a
  provider identity.
- **Display path (2):** both branches of `display_tailer_handler/3` call
  `MessageHandler.journal/4` with `session_id: source_session_id` and
  `journal_source_kind: :provider_file`. The backfill branch is included:
  `from: :start` replay after a restart re-sends old records, and the
  writer's dedup (`msg_id` = Claude record `uuid`, `claude/transcript.ex:178`)
  drops them.
- **Operator delivery (3):** in `observe_operator_text/5` call `journal/4`
  with `%{role: :user, msg_id: "operator:#{request_id}", body: text,
  payload: %{delivery_id: request_id}}`; `Entry.from_transcript_event/2` puts
  `delivery_id` into `refs.delivery_id`. Skipped when the text is empty (the
  existing `""` clause).
- **Session end:** `finish_live_conversation/4` also calls
  `Ingest.end_session(ref, opts[:session_id], reason)` with
  `{:error, _} → :crashed`, otherwise `:stopped`.

## Implementation steps

1. Add `journal/4`, `journal_end/4` and `provider_item_id/1` to
   `MessageHandler` (target ≤ 60 added lines).
2. Wire the closure, `observe_operator_text/5`, and `finish_live_conversation/4`.
3. Wire both clauses of `SessionLifecycle.display_tailer_handler/3`.
4. Add `conversation_journal: :disabled` to existing tests that assert exact
   message counts only if they break (prefer leaving them unchanged; the tee
   is a cast to a process the tests do not observe).

## Non-happy paths

- **No synchronous I/O:** `Ingest.append/3` is a cast (T02). The closure must
  return even if the journal supervisor is down: `journal/4` catches `:exit`.
- **Unjoinable identity:** skipped and counted; `LiveConversation` already
  refuses these (`message_handler.ex:440-447`).
- **Remote (SSH) worker:** the closure runs in the daemon for every worker; only
  `AgentEventLog` skips remote hosts. RQ-E4-5 is answered by test 4 below and by
  one manual check on an SSH worker before the PR is marked ready.
- **Provider fallback** (`claude-repl` → `claude`): the backend label changes,
  so `{harness, provider_session_id}` changes and the writer opens a new session
  (`superseded`), which is the honest record.
- **Duplicate delivery observation** (checkpoint and queue-drain both observing
  one item): same `msg_id "operator:<id>"` → same `dedup_key` → one entry.
- **8,000-byte display cap:** Remote-Control bodies arrive already cut by
  `DisplayTailer`; the entry keeps the cut text and the marker. Raising that cap
  is out of scope (display-only module).

## Compatibility and rollout

- On by default once merged (D: "retain complete transcripts"; DESIGN-E4
  decision 5). No config key; if DESIGN-E4 asks for an opt-out, add
  `observability.conversation_journal` with docs in
  `reference/configuration.md` (checked by `scripts/check-config-docs.py`).
- Rollback: revert this ticket; journals already written stay readable.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/agent_runner/message_handler_test.exs \
  test/aiur/agent_runner/session_lifecycle_test.exs \
  test/aiur/conversation/worker_tee_test.exs
```

| Test (in PROPOSED `worker_tee_test.exs` unless noted) | Expected | Fails without |
| --- | --- | --- |
| 1 "codex assistant + command + tool records land in order with positions" | 3 entries, kinds `message`, `command`, `tool_result` | closure hook |
| 2 "codex command gets the raw item id as identity" (same command twice, different item ids) | 2 entries | `provider_item_id/1` |
| 3 "assistant_delta is not journaled" | 0 entries | `Entry` skip (T01) reached via the tee |
| 4 "remote worker (worker_host set) is journaled" | 1 entry; `agent.ndjson` absent | — documents RQ-E4-5 (would fail only if a future change gated on host) |
| 5 "display authority: closure skips, display handler writes, backfill dedups" | entries once, even after the backfill branch replays them | the authority skip and the display-handler call |
| 6 "operator delivery entry carries refs.delivery_id" | `operator_message`, `refs.delivery_id == request_id` | the call in `observe_operator_text/5` |
| 7 "closure returns with journal supervisor stopped" | closure returns `:ok`; no crash | the `catch :exit` |
| 8 "finish with {:error, _} ends the session crashed" | session end line `crashed` | `journal_end` |
| 9 (message_handler_test) existing "deduplicates replayed tool results…" | unchanged, green | — regression guard |

Manual (RQ-E4-5): with an SSH worker configured, run one ticket, then list
`<conversation_state_dir>/<conversation_id>/entries.*.jsonl` line count > 0.
Record the result in the PR body.

## Completion and handoff

- [ ] All tests green; `make ci` green on the head SHA.
- [ ] RQ-E4-5 manual result in the PR body.
- [ ] Workspace removed after a run → the conversation's entries still exist
      (manual: remove a test workspace, check the journal directory).
- Dependents: MP-E4-C2-T01 (reads), MP-E4-C3-T02 (exact anchors need
  `refs.tool_call_id`), MP-E4-C5-T01.
- Docs: none here (MP-E4-C8-T02 documents storage).
