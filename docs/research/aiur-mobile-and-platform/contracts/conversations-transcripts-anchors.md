---
contract_id: MP-CT-conversations-transcripts-anchors
owner_feature: MP-E4
co_consumers: [MP-E3, MP-E5, MP-E6, MP-E7, MP-N3, MP-N6, MP-N7, MP-R6]
status: draft (Phase B)
version: 1
base_main_sha: 45a290e3
date: 2026-10-06
---

# Contract: conversations, transcripts and event anchors

This contract defines how aiur names a conversation, how it stores and pages the
full transcript, how it marks session boundaries, and how an event (progress,
push, PR, merge, Command) points to a position in a conversation. MP-E4 owns it.
MP-E3 (Executor), MP-N6 (phone/watch "open in context"), MP-R6 (Stream Deck logs)
and MP-E5/E6/E7 (send paths) consume it.

Decisions D15 and brief §3 apply without change: **logs are never rewritten**,
full transcripts are **retained locally** and stay reviewable, and a summary
never replaces a transcript.

## 1. Why a new contract (verified gaps at `45a290e3`)

| Fact | Evidence | Consequence |
| --- | --- | --- |
| The IssueLog root is per launch and "does not survive a daemon restart". | `src/lib/aiur/config/paths.ex:27-36` | A transcript under `<logs-root>/log` is not a reliable full history. |
| Workspace removal deletes `logs/agent.ndjson` and `logs/agent.md`. | `src/lib/aiur/workspace/remove.ex:25,61` (`File.rm_rf`) | A finished worker's conversation can disappear. |
| `agent.ndjson` records have no id and no sequence. `transcript_event.sequence` is a per-BEAM `unique_integer`. | `src/lib/aiur/agent_event_log.ex:23-48`; `src/lib/aiur/agent_events.ex:28-36,129` | No stable position exists today. |
| The only cursor is a byte offset into the IssueLog `.agent_events.jsonl`. Its doc says producers "do not share an event-id sequence". | `src/lib/aiur/issue_log.ex:111-141` | Byte offsets are per file and per launch. They cannot be shared anchors. |
| `LiveConversation` is in memory only (80 messages, 64 KB). Its generation is a per-BEAM integer. | `src/lib/aiur/live_conversation.ex:6-9`; `live_conversation/retention.ex:6-10`; `orchestrator/dispatcher.ex:2494` | It is a live view, not history. |
| The only event→transcript anchor is `AiurWeb.StreamdeckLogs`: "every transcript entry belongs to the last event at or before it". It loads only the newest 50 transcript rows. | `src/lib/aiur_web/streamdeck_logs.ex:306-338,628-635` | The rule is reusable. The data window is not. |
| Agent-emitted events record `tool_call_id` and `event_id` together in a daemon-owned publication log. | `src/lib/aiur/agent_runner/tool_executor.ex:423-503`; `src/lib/aiur/event_publication_log.ex:1-36` | An **exact** anchor is possible for agent-emitted events. |
| Bus event ids are durable and monotonic across restarts. | `src/lib/aiur/events/id_generator.ex:2-11` | Event identity is already stable (MP-R2 owns it). |

## 2. Terms

| Term | Meaning |
| --- | --- |
| **Subject** | Who the conversation is with: one worker ticket, or the instance's Executor. |
| **Conversation** | The complete, append-only record for one subject in one instance. It spans many sessions. |
| **Session** | One provider session or thread inside a conversation: a Codex thread, a Claude session id, an OpenCode session. A new session starts on spawn, resume into a new thread, `/clear`, compaction that forks a transcript file, takeover, or Executor re-attach. |
| **Entry** | One rendered unit: a message, reasoning block, command, tool result, diff, operator message, system notice, or gap marker. |
| **Position (`pos`)** | A positive integer, assigned by the journal writer, strictly increasing within one conversation and never reused. It is the only shared address of an entry. |
| **Anchor** | A link from one event to one position, with a declared precision. |
| **Gap** | A span the journal knows it does not have (daemon down, source unreadable, history before the journal existed). A gap is an entry, so it has a position and is shown, not hidden. |

## 3. Identity

```text
ConversationRef  = { v: 1, instance_id, subject }
subject          = { kind: "worker",   tracker_identity }     # repo + issue id (Aiur.TrackerIdentity)
                 | { kind: "executor" }                       # one Executor per instance (brief §3)
conversation_id  = "conv_" <> base32(sha256(instance_id <> canonical(subject)))[0..25]
SessionRef       = { conversation_id, session_seq }           # session_seq: 1, 2, 3 … per conversation
EntryRef         = { conversation_id, pos }
```

- `instance_id` comes from the identity contract (coordinator). **Assumption:** it is
  the launcher's per-repository instance key recorded in
  `~/.config/aiur/instances/*.instance` (baseline §4 fact 14). If the identity
  contract picks another key, only this field changes.
- `tracker_identity` reuses `Aiur.TrackerIdentity`, which already keys
  `LiveConversation.Source` (`live_conversation/source.ex:8-15,60`).
- The Executor subject is singular per instance. Re-attaching a different external
  session opens a new **session** in the same conversation (MP-E3).
- Provider ids are attributes of a session, never identities of the conversation.
  The same provider thread resumed after a daemon restart continues the same
  session when the provider id matches (`Aiur.SessionHandle`,
  `src/lib/aiur/session_handle.ex:2-20`).

## 4. Session record

```json
{
  "v": 1,
  "conversation_id": "conv_…",
  "session_seq": 3,
  "harness": "codex | claude | claude-repl | opencode | muse | other",
  "role": "worker | executor",
  "provider_session_id": "opaque string or null",
  "aiur_attempt_id": "string or null",
  "transcript_source": { "kind": "aiur_ingest | provider_file | app_server", "locator_hash": "sha256 or null" },
  "started_at": "ISO8601", "first_pos": 1201,
  "ended_at": "ISO8601 or null", "last_pos": 1650,
  "start_reason": "spawn | resume | clear | compact | fork | reattach | takeover | import",
  "end_reason": "turn_limit | stopped | crashed | superseded | detached | daemon_restart_unknown | null"
}
```

- `locator_hash` hashes a file path. Raw paths into `~/.claude` or `~/.codex` are
  not exposed to clients.
- A daemon restart that cannot prove continuity writes `end_reason:
  "daemon_restart_unknown"` and opens the next session with `start_reason: "resume"`.
  This mirrors `LiveConversation`'s `:restart_unknown`
  (`live_conversation.ex:680-687`).

## 5. Entry record

```json
{
  "v": 1, "pos": 1207, "session_seq": 3,
  "id": "ent_<sha256(provider_msg_id | tool_call_id | fallback tuple)>",
  "kind": "message | reasoning | command | tool_call | tool_result | diff | operator_message | system | gap",
  "role": "agent | operator | executor_operator | tool | system",
  "body": "string (bounded, see §8)",
  "body_truncated": false,
  "refs": { "provider_msg_id": null, "tool_call_id": null, "turn_id": null, "delivery_id": null },
  "occurred_at": "ISO8601 or null", "observed_at": "ISO8601",
  "gap": null
}
```

- `id` is idempotency, not order. Re-ingesting the same provider record produces
  the same `id`, and the writer drops it. The fallback tuple matches
  `LiveConversation.Normalizer` (`normalizer.ex:138-145`).
- `operator_message` is written only when the harness transcript shows the input
  (for Claude, a `user` record or a `queued_command` attachment;
  `claude/transcript.ex:100-140`). A send that was accepted but not yet seen is a
  **delivery overlay** (§9), not an entry. This keeps the journal a record of what
  the agent received.
- `gap` is `{ "reason": "daemon_down | source_unreadable | pre_journal | truncated_source", "from": ISO8601, "to": ISO8601 }`.

## 6. Storage (owned by MP-E4.C1)

- **Location:** a durable, owner-only directory beside the Decision state
  (`Config.Paths.decision_state_dir/0`, `paths.ex:39-41`), not the per-launch log
  root and not the workspace. Proposed path:
  `<durable-state>/conversations/<conversation_id>/`.
- **Files:** `entries.<segment>.jsonl` (append only, fsync per batch),
  `sessions.jsonl` (append only; an end is a new line, never an edit),
  `anchors.jsonl` (append only), `head.json` (last `pos`, last `session_seq`;
  rebuilt from the segments if lost).
- **Never rewritten.** Segments roll at a size bound (proposed 8 MiB, the same
  bound as `AlertLedger`). Old segments are kept. No automatic deletion. Pruning
  is out of scope, and an owner decision if ever added.
- **Permissions:** directory `0700`, files `0600`, like the Decision store.
- **Single writer:** one writer process per conversation. `pos` is assigned under
  that writer.

## 7. History API

One read API serves the dashboard, the JSON endpoint, the Stream Deck projection
and later the phone.

```text
list_entries(ConversationRef, opts) -> {:ok, Page} | {:error, :not_found | :unavailable}
  opts: before: pos | after: pos | around: pos | from_start: true | tail: true (default)
        limit: 1..200 (default 50)
        kinds: [kind] (optional filter; gaps are always returned)
Page = { entries: [Entry], sessions: [Session overlapping the page],
         prev_cursor: pos | null, next_cursor: pos | null,
         head_pos, complete_from_start: boolean, observed_at }

list_sessions(ConversationRef) -> [Session]
list_anchors(ConversationRef, opts) -> [Anchor]     # filter by kind, time range, pos range
subscribe(ConversationRef) -> PubSub "conversation:<conversation_id>"
  messages: {:entries_appended, conversation_id, [Entry]}
            {:session_changed, conversation_id, Session}
            {:anchor_added, conversation_id, Anchor}
```

- **Reconnect:** a client keeps its highest `pos` and calls `after: pos`. No
  timestamps are used for resume.
- **Order:** `pos` order is the display order. Entries from one provider record
  keep their in-record order.
- **HTTP (proposed):** `GET /api/v1/conversations/:conversation_id/entries`,
  `/sessions`, `/anchors`, behind dashboard auth (read). Writes are not on these
  routes (§9).
- **Paging bound:** `limit` 200 bounds a page by count. Bodies are bounded by §8,
  so a page has a known maximum size.

## 8. Body bounds

- Store bodies up to 64 KiB per entry. Above that, keep the first and last 16 KiB
  and set `body_truncated: true`. The provider transcript still has the full text.
  This is display storage, not a rewrite of the provider's log.
- Diffs keep their full hunk list up to the same bound (IssueLog today caps edit
  diffs at 2000 characters, `issue_log.ex:748-754`, which is too small for review).
- Owner question (DESIGN-E4): whether reasoning blocks are stored and shown. The
  default in this draft is "stored, collapsed in the view".

## 9. Writes (D15)

Only two writes act on a conversation. Neither edits the journal.

1. **Send a message** to the subject. The client calls the listener-mode service
   (MP-E7 contract) with `{ConversationRef, text, client_request_id}`. The service
   returns a `delivery_id` and receipt states. The view shows a **delivery overlay**
   keyed by `delivery_id` until the journal writes the matching `operator_message`
   entry (`refs.delivery_id`) or the receipt reports failure.
2. **Answer an open Command** of that subject, through the Command contract
   (MP-E2: `answer` with `expected_version` and `idempotency_key`; existing
   `DecisionStore.answer/5`). The answer appears in the conversation when the
   agent receives it.

Not allowed through this contract: editing, hiding or deleting entries; pause,
resume, interrupt or spawn (controls stay where they are, D15).

## 10. Anchors

```json
{
  "v": 1,
  "anchor_id": "anc_<sha256(event_ref, conversation_id)>",
  "event": { "event_id": 123456, "topic": "ticket.42.pr.merged", "kind": "pr_merged",
             "occurred_at": "ISO8601 or null", "observed_at": "ISO8601" },
  "conversation_id": "conv_…",
  "pos": 1207,
  "precision": "exact | causal | observed | unanchored",
  "method": "tool_call_id | decision_source | command_text | at_or_before_observed | none",
  "label": "PR merged",
  "subject_ref": { "pr_number": 51, "head_sha": "abc123", "decision_id": null }
}
```

Precision levels, strongest first. The resolver records the strongest it can
prove and never upgrades a guess:

| Precision | Rule | Applies to |
| --- | --- | --- |
| `exact` | The event was published by a tool call in this conversation. Match `event-publications.ndjson` `tool_call_id` → entry `refs.tool_call_id`. | Agent `emit_event` / `emit_alert`: progress, progress check-in, phase, blocked, pause request, `decision.requested` (`tool_executor.ex:423-503`). |
| `causal` | A transcript command entry is the cause of an external effect. The resolver matches it by command text and outcome within a bounded window. | `git push` → `branch.push`; `gh pr create` → `pr.opened`; `gh pr merge` → `pr.merged` (Executor merges). |
| `observed` | No causal link. Anchor to the last entry at or before the event's `observed_at` (the StreamdeckLogs rule, `streamdeck_logs.ex:306-338`). | CI results, review comments, merges by others, polled pushes (`ls_remote_ticker.ex:4`, 30 s polling). |
| `unanchored` | No entry exists in a session covering the event time, or the time is unusable. | Event before the first session; event during a gap. Shown in the event list with no jump. |

- An event can anchor into several conversations (for example `pr.merged` anchors
  in the worker's conversation and, as `causal`, in the Executor's when the
  Executor ran the merge).
- A Command anchors in the requester's conversation with `method:
  "decision_source"`, using `Decision.source{session_id, event_id}`
  (`decision.ex`; `tool_executor.ex:602`).
- An anchor is append-only. A better anchor found later is a new line with a
  stronger precision. Readers use the strongest.

### Jump-point catalogue (v1)

| `kind` | Source topic(s) | Best precision |
| --- | --- | --- |
| `progress` | `ticket.<id>.agent.progress`, `.progress.checkin` | exact |
| `phase` | `ticket.<id>.agent.progress.phase` / `phase.*` | exact |
| `push` (commits) | `ticket.<id>.branch.push` (head sha) | causal / observed |
| `pr_opened` | `ticket.<id>.pr.opened` | causal / observed |
| `pr_merged` | `ticket.<id>.pr.merged` | causal / observed |
| `ci` | `ticket.<id>.ci.passed|failed` | observed |
| `review_comment` | `ticket.<id>.pr.review_comment`, `issue.commented` | observed |
| `command_requested` / `command_resolved` | `decision.requested|resolved` | exact / observed |
| `attention` | `ticket.<id>.agent.attention.*` | exact |
| `executor_progress` | `executor.*` events the Executor emits (`executor-emit`) | causal |

"Commit" is shown as `push`: aiur observes pushes, not local commits. A
`git commit` command entry is visible in the transcript but is not an event.

## 11. Failure and edge behaviour

| Case | Behaviour |
| --- | --- |
| No transcript source (for example a backend that emits no transcript events; note `AgentEventLog` already writes nothing for a remote host, `agent_event_log.ex:24`, so the journal must not depend on workspace files) | Conversation exists with zero entries and a `gap` of reason `source_unreadable`. Anchors become `unanchored`. |
| Daemon down while the agent ran | On restart the ingester re-reads the provider transcript from its stored offset when the source is a file (Claude, Executor). Otherwise it writes a `daemon_down` gap. |
| Duplicate provider record | Same `id`; dropped. |
| Provider file truncated or replaced | Detected as in `TranscriptTailer` (`transcript_tailer.ex:112-120`); new session with `start_reason: "fork"` or `"compact"`, never a rewrite. |
| Journal head lost | Rebuilt by scanning segments. |
| Clock skew | `observed` anchors use the daemon's `observed_at` on both sides, so skew between provider and daemon does not move them. |
| Very long history | Paging by `pos`; the dashboard never loads the whole file. |
| Client cannot read Executor conversation (no binding) | `{:error, :not_found}` with capability reason, not an empty list. |

## 12. Privacy

- Transcripts can hold secrets the agent printed. Storage is owner-only (§6).
  Reads need dashboard auth. No public route.
- Executor transcripts are the operator's own session. Capture is opt-in (MP-E3).
- Clients get `locator_hash`, never raw provider file paths.
- Push payloads (MP-N4) carry an `EntryRef`/`anchor_id`, never entry bodies.

## 13. Versioning

Every record has `v`. Readers accept unknown fields. A breaking change is `v: 2`
with both versions readable for one release.

## 14. Assumptions about contracts owned by others

| Contract (owner) | What this contract needs |
| --- | --- |
| Events and replay (MP-R2) | Durable `event_id`, `topic`, ticket, `occurred_at`, `observed_at` per event; a per-ticket history read (today `IssueLog.event_history/2`); `executor.*` journal replay. A subscriber API for the anchor resolver. |
| Harness adapter (MP-R7) | Per harness: a transcript source that turns provider records into entries with `provider_msg_id`, `tool_call_id`, `turn_id`; session-boundary signals (SessionStart source, thread change). Must cover **attached external sessions** (Executor), not only daemon-spawned ones. |
| Listener mode (MP-E7) | `send(ConversationRef, text, client_request_id) -> delivery_id`, receipts `harness_queued | in_context | failed | outcome_unknown`, and the effective mode. The receipt must carry enough (`delivery_id` echoed or a text hash plus time window) to match the later transcript entry. |
| Command request and resolution (MP-E2) | `Decision.source.session_id` and `event_id` filled for worker and Executor requesters; `answer` with `expected_version`. |
| Identity (coordinator) | `instance_id`. |
