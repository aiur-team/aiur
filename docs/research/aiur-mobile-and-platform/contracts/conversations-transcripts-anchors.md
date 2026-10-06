---
contract_id: MP-CT-conversations-transcripts-anchors
owner_feature: MP-E4
co_consumers: [MP-E3, MP-E5, MP-E6, MP-E7, MP-N3, MP-N6, MP-N7, MP-R6]
status: draft (Phase C; RC-02, RC-06, RC-07 applied)
version: 1
base_main_sha: 45a290e3
date: 2026-10-06
phase_c_changes: §15
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
ConversationRef  = { v: 1, instance_id | null, subject }
subject          = { kind: "worker",   tracker_identity }     # repo + issue id (Aiur.TrackerIdentity)
                 | { kind: "executor" }                       # one Executor per instance (brief §3)
conversation_id  = "conv_" <> base32_lower(sha256(canonical(subject)))[0..25]   # unique within one instance
SessionRef       = { conversation_id, session_seq }           # session_seq: 1, 2, 3 … per conversation
EntryRef         = { conversation_id, pos }                   # THE stable entry address (RC-07)
GlobalEntryRef   = { instance_id, conversation_id, pos }      # what a phone, push or deep link carries
```

`SessionRef` is the single session identity for every contract (identity,
Commands, notifications; Phase D, CR-R1-5). `conversation_id` is not derived from
`instance_id`; a global reference carries `instance_id` beside it.

- `instance_id = "<machine_id>/<instance_key>"` (RC-02; identity contract owned by
  MP-R1). It is **not** an input to `conversation_id`: the journal directory is
  already instance-scoped (§6), and keeping `conversation_id` independent of
  `machine_id` means a journal written before MP-R1's identity file exists keeps
  its ids when the identity appears. Clients outside the daemon always key on
  `(instance_id, conversation_id)`. `instance_id` is `null` only while the
  identity contract is not implemented; external (paired) clients are refused
  until it is present.
- `canonical(subject)`: worker → `"worker:github:" <> owner <> "/" <> repository
  <> ":" <> provider_id` from `Aiur.TrackerIdentity.github_key/1`
  (`tracker_identity.ex:141-146`; owner and repository are downcased there, and
  `provider_id` survives a display-number change); executor → `"executor"`. An
  unjoinable identity (`TrackerIdentity.joinable?/1` false) has **no**
  conversation: the tee skips it and counts the skip, as `LiveConversation`
  does (`live_source/3`, `message_handler.ex:400-445`).
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
  "harness": "<harness_id from harness-adapter §1> | other",   // X-39: no local enum
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
  "dedup_key": "ent_<sha256(source identity, see below)>",
  "kind": "message | reasoning | command | tool_call | tool_result | diff | operator_message | system | gap",
  "role": "agent | operator | executor_operator | provider_input | tool | system",
  "body": "string (bounded, see §8)",
  "body_truncated": false,
  "redacted": false,
  "refs": { "provider_msg_id": null, "tool_call_id": null, "turn_id": null, "delivery_id": null },
  "origin": "operator | voice_assistant | null",
  "occurred_at": "ISO8601 or null", "observed_at": "ISO8601",
  "gap": null
}
```

- **`pos` is the entry's stable identity** (RC-07). It is assigned once by the
  single journal writer and never changes, so an anchor, a deep link and a deck
  key all name an entry by `EntryRef {conversation_id, pos}`. There is no second
  entry id.
- `dedup_key` is idempotency only, never an address. Source identity, in order:
  `provider_msg_id` (with role) → `tool_call_id` (with role) → the fallback tuple
  `{role, turn_id | occurred_at, body}` that `LiveConversation.Normalizer.stable_id/3`
  uses (`live_conversation/normalizer.ex:138-145,196-199`). Re-ingesting the same
  record yields the same key and the writer drops it, inside the open session
  and across a daemon restart (MP-E4-C1-T02).
- `operator_message` is written when the input reaches the agent, never at
  acceptance: for daemon-run workers at aiur's delivery point
  (`MessageHandler.observe_operator_delivery/4`, `message_handler.ex:173-216`,
  `msg_id "operator:<queue item id>"`, so `refs.delivery_id` is the
  `AgentChat.send/3` request id); for an attached Executor when the provider
  transcript shows it (Claude `user` record or `queued_command` attachment,
  `claude/transcript.ex:100-140`). A send that was accepted but not yet
  delivered is a **delivery overlay** (§9), not an entry.
- **Operator provenance (Phase D, security M6).** For a **worker** conversation,
  role `operator` comes **only** from daemon delivery evidence
  (`observe_operator_delivery/4`, `refs.delivery_id` set). Provider JSONL files are
  agent-writable, and Claude `user` records also carry tool results and the aiur
  prompt, so a provider `user` record that matches no daemon delivery maps to
  `kind: system`, `role: provider_input`; views label it "provider input", never as
  the operator. For the **Executor** conversation, `role: executor_operator` stays
  (it is the operator's own session), but only for a `transcript_path` that passed
  the MP-E3 path check (canonical file under `~/.claude/projects/` or
  `~/.codex/sessions/`, regular file, not a symlink, owned by `$USER`, basename
  matching `session_id`; MP-E3-C1-T02).
- `gap` is `{ "reason": "daemon_down | source_unreadable | pre_journal | truncated_source", "from": ISO8601, "to": ISO8601 }`.
- `origin` (Phase D, E6 R-1/R-2) is set only on `operator_message` entries:
  `voice_assistant` when the queue item's origin is `:voice_assistant`, else
  `operator` (listener-mode §7 `opts[:origin]`). Views render
  `voice_assistant` entries with the DESIGN-E6-approved label; until approved, they
  render as a plain operator message. `null` on every other kind.

## 6. Storage (owned by MP-E4.C1)

- **Location:** a durable, owner-only directory beside the Decision state, not
  the per-launch log root and not the workspace. PROPOSED
  `Aiur.Config.Paths.conversation_state_dir/0` = `<decision_state_dir>/conversations`
  with an `Application` env override `:conversation_state_dir` (the pattern of
  `progress_retention_state_dir/0`, `config/paths.ex:99-109`; the root is
  instance- and project-scoped by `decision_state_dir/0`, `paths.ex:61-66,322-328`).
  One directory per conversation: `<conversation_state_dir>/<conversation_id>/`.
- **Files:** `subject.json` (written once at creation: subject kind, and for
  workers owner, repository, display identifier, provider id; lets a finished
  ticket's identifier resolve to its conversation), `entries.<segment>.jsonl`
  (append only, fsync per batch),
  `sessions.jsonl` (append only; an end is a new line, never an edit),
  `anchors.jsonl` (append only), `head.json` (last `pos`, last `session_seq`;
  rebuilt from the segments if lost).
- **Never rewritten.** Segments roll at a size bound (proposed 8 MiB, the same
  bound as `AlertLedger`). Old segments are kept. No automatic deletion. Pruning
  is out of scope, and an owner decision if ever added (DESIGN-E4 decision 5).
- **Size budget** is measured, not estimated: MP-E4-C1-T00 (RQ-E4-1) gives
  bytes/hour per agent from the live fleet and confirms or lowers the §8 body
  bound before C1-T01 fixes it.
- **Ingest points (workers).** Three daemon-side call sites see every transcript
  record: the per-message closure (`MessageHandler.build/7`,
  `agent_runner/message_handler.ex:52-63`), the Remote-Control display path
  (`SessionLifecycle.display_tailer_handler/3`, `agent_runner/session_lifecycle.ex:741-765`,
  which bypasses the closure on purpose and backfills `from: :start`), and
  operator delivery (`MessageHandler.observe_operator_delivery/4`). All three
  tee to the journal with a non-blocking cast.
- **Permissions:** directory `0700`, files `0600`, like the Decision store.
- **Single writer:** one writer process per conversation. `pos` is assigned under
  that writer. Anchor lines also go through it.
- **Layering (MP-R1 CR-C8-1).** The write side (`Aiur.Conversation.{Ref, Entry,
  Session, Store, Journal, Ingest}`) sits at the agent-runner layer, because
  agent-runner call sites feed it; it depends only on `Config.Paths`,
  `DecisionLog`, `TrackerIdentity` and PubSub. The read side
  (`Aiur.Conversation.{History, Anchors, AnchorResolver, JumpPoints}`) is the
  projection layer and is the in-daemon read facade every surface uses. The name
  `Aiur.Conversations` (plural) is already taken by the tmux conversation-pane
  facade (`src/lib/aiur/conversations.ex`), so it is not used here.

## 7. History API

One read API serves the dashboard, the JSON endpoint, the Stream Deck projection
and later the phone.

```text
list_entries(ConversationRef, opts) -> {:ok, Page} | {:error, :not_found | :unavailable}
  opts: principal: {:operator, :loopback | :basic_auth} | {:device, device_id} | :internal
          (REQUIRED, Phase D; a call without it raises ArgumentError, so no caller
          gets unmasked bodies by forgetting it)
        before: pos | after: pos | around: pos | from_start: true | tail: true (default)
        reveal: boolean (default false; honoured only for {:operator, :loopback})
        limit: 1..200 (default 50)
        kinds: [kind] (optional filter; gaps are always returned)
Page = { entries: [Entry], sessions: [Session overlapping the page],
         prev_cursor: pos | null, next_cursor: pos | null,
         head_pos, complete_from_start: boolean, observed_at }

list_sessions(ConversationRef) -> [Session]
list_anchors(ConversationRef, opts) -> [Anchor]     # filter by kind, time range, pos range
anchor_for_decision(decision_id) -> {:ok, Anchor} | :none   # strongest anchor across conversations
subscribe(ConversationRef) -> PubSub "conversation:<conversation_id>"
  messages: {:entries_appended, conversation_id, [Entry]}
            {:session_changed, conversation_id, Session}
            {:anchor_added, conversation_id, Anchor}
```

- **`anchor_for_decision/1`** (Phase D, CR-N6-4) returns the strongest anchor
  (`exact` with `method: decision_source` first) for a Command across all
  conversations of the instance, from an index the resolver keeps; it never scans
  `anchors.jsonl`. The device Command view (MP-N6-C1-T01) includes
  `{conversation_id, pos, anchor_id, precision}` from it, or `null`. Owner ticket:
  MP-E4-C3-T02 (resolver index).
- **Secret masking on read (Phase D, security M5).** The journal stays unredacted
  (it is never rewritten, D15). `list_entries` masks at read time by principal:
  - `{:device, _}`: every `body` (and a `tool_result` output) passes
    `Aiur.SecretRedactor.redact/1` then `redact_urls/1` (`secret_redactor.ex:49-60`),
    and the entry carries `redacted: true` when either changed the text. `reveal` is
    ignored. `redact_urls/1` replaces every `http(s)`/`ws(s)` URL, not only ones with
    credentials, so PR links are masked too on devices (accepted; DESIGN-E4 decision 4
    may narrow it). Subscribed `{:entries_appended, …}` payloads to a device socket are
    masked the same way.
  - `{:operator, _}` (dashboard): default per DESIGN-E4 decision 4, proposed "mask by
    default, `reveal` allowed only for loopback sessions".
  - `:internal` (in-daemon callers such as the anchor resolver): unmasked; never
    serialized to a client.

  Phones and watches keep entry bodies in memory only, never on disk, and drop them on
  revoke (MP-N1, MP-N6). Test: MP-E4-C2-T01 "device principal receives redacted body;
  journal bytes unchanged".
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
   returns a `delivery_id` and receipt states. The facade is
   `Aiur.Listener.send(target, text, client_request_id)` and
   `Aiur.Listener.receipt(delivery_id)` (MP-E7-C3-T03/T04). For workers it wraps
   `Aiur.AgentChat.send/3` with `message_id: client_request_id`
   (`agent_chat.ex:22-25`), so `delivery_id` is the queue request id; MP-E7-C3
   routes it through the mode (RC-05), behind a flag that keeps today's
   behaviour until DESIGN-E7 is approved. The Executor target arrives with
   MP-E7-C6 (hook delivery). The view shows a **delivery overlay**
   keyed by `delivery_id` until the journal writes the matching `operator_message`
   entry (`refs.delivery_id`) or the receipt reports failure.
2. **Answer an open Command** of that subject, through the Command contract
   (MP-E2: `answer` with `expected_version` and `idempotency_key`; existing
   `DecisionStore.answer/5`). The answer appears in the conversation when the
   agent receives it.

Not allowed through this contract: editing, hiding or deleting entries; pause,
resume, interrupt or spawn (controls stay where they are, D15).

## 10. Anchors

**Address (RC-07).** An anchor points at an `EntryRef {conversation_id, pos}`.
Row indices (the Stream Deck's `start`, `streamdeck_logs.ex:355-396`) and byte
offsets are presentation details derived from `pos`, never stored.

```json
{
  "v": 1,
  "anchor_id": "anc_<sha256(event_id, event_kind, conversation_id, precision)>",
  "event": { "event_id": 123456, "topic": "ticket.42.pr.merged", "kind": "pr_merged",
             "occurred_at": "ISO8601 or null", "observed_at": "ISO8601",
             "source_tool_call_id": "exec-… or null" },
  "conversation_id": "conv_…",
  "pos": 1207,
  "placement": "at | after",
  "precision": "exact | causal | observed | unanchored",
  "method": "provenance_tool_call | decision_source | command_text | at_or_before_observed | none",
  "label": "PR merged",
  "subject_ref": { "pr_number": 51, "head_sha": "abc123", "decision_id": null }
}
```

- `placement: "at"` (exact, causal): the event *is* that entry's effect; the
  view highlights the entry. `placement: "after"` (observed): the event
  happened after entry `pos` and before `pos + 1`; the view draws a marker
  below `pos`. `unanchored` has `pos: null`.
- `anchor_id` includes `precision`, so a stronger anchor found later is a new
  line with a new id; re-running the resolver at the same precision produces
  the same id and is dropped.

Precision levels, strongest first. The resolver records the strongest it can
prove and never upgrades a guess:

| Precision | Rule | Applies to |
| --- | --- | --- |
| `exact` | The event carries the id of the tool call that published it, and an entry of this conversation has that id in `refs.tool_call_id`. The id is on the bus event itself: `ticket_observation.provenance.source_event_id` = the tool invocation id (`agent_runner/tool_executor.ex:423,875-882`; kept verbatim by `ticket_observation.ex:181-198`). The per-launch `event-publications.ndjson` is **not** read (its moduledoc says no running code reads it back, `event_publication_log.ex:13-19`). | Agent `emit_event` / `emit_alert`: progress, check-in, phase, blocked, pause request, attention, `decision.requested`. |
| `exact` (Command) | `Decision.source.event_id` is the same invocation id and `source.session_id` the provider thread id (`tool_executor.ex:845-850`), so a Command anchors `at` the tool-call entry with `method: "decision_source"`. | `command_requested`. |
| `causal` | A command entry is the cause of an external effect: rule table in MP-E4-C3-T03 (command text, exit code, window, and for pushes the head sha in the output). | `git push` → `branch.push`; `gh pr create` → `pr.opened`; `gh pr merge` → `pr.merged`. |
| `observed` | No provable link. Anchor `after` the last entry whose `observed_at` ≤ the event's `observed_at`, in a session whose span covers the event. Ties: the event goes after every entry with an equal `observed_at`. Both sides use the daemon clock (§11 clock skew). | CI results, review comments, merges by others, polled pushes (`events/ls_remote_ticker.ex:4`, 30 s). |
| `unanchored` | No session covers the event time, the event falls inside a `gap`, or its `observed_at` is unusable. | Event before the first session; event while the daemon or the source was down. Listed, no jump. |

- An event can anchor into several conversations (for example `pr.merged` anchors
  in the worker's conversation and, as `causal`, in the Executor's when the
  Executor ran the merge).
- An anchor is append-only. A better anchor found later is a new line with a
  stronger precision. Readers use the strongest per `(event_id, conversation_id)`.
- **Event source.** GitHub, CI and push events are `live` class: they reach
  only subscribers bound at publish time, and IssueLog keeps per-launch markers
  only for joinable events while a writer is registered (events contract §6;
  `issue_log.ex:545-560,573-581`). The resolver is therefore a live
  `Aiur.Events.Exchange` subscriber (`events/exchange.ex:69-77`) bound at boot,
  and `anchors.jsonl` stores the event metadata above, which makes it the
  durable per-conversation jump-point index. Events published while the daemon
  was down are not recoverable before MP-R2's export journal (R2-C6); after it
  is enabled the resolver backfills from it by `seq`.
- **Shared module (RC-06).** MP-R6-C1 extracts the Stream Deck rule verbatim
  into the device-neutral `Aiur.Conversation.Anchors` (MP-R6-C1-T01:
  `at_or_before/2`, `with_origin/2`, `event_identity/2`, `origin_id/0`; each
  entry belongs to the last event at or before it; nil-timestamp events claim
  nothing; leftovers go to a synthetic origin; identity `{source, kind, id}`;
  `streamdeck_logs.ex:267-351`). MP-E4-C3-T01 extends the same module with
  `position/3` (the `observed` rule above, over journal entries) and the
  precision ladder. The two functions agree except at ties, where `at_or_before/2`
  keeps the deck's `>=` membership (its tests are the oracle) and `position/3`
  places the event after the tied entry.

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
| Duplicate provider record (Codex replay, Remote-Control `from: :start` backfill after restart) | Same `dedup_key`; dropped. |
| Unjoinable tracker identity | No conversation; skip counted (§3). |
| Journal write fails (disk full, permission) | The agent message path is unaffected (the tee is a cast). The writer keeps the failed batch's time span and, when a write next succeeds, appends one `gap` (`source_unreadable`) for it, plus one needs-attention alert per conversation per outage. |
| Anchor resolver down or restarted | Events published while it was not subscribed are not anchored (live class). On boot it re-subscribes before agents start and writes nothing for the downtime; the view shows those events only if MP-R2's export journal later supplies them. |
| Provider file truncated or replaced | Detected as in `TranscriptTailer` (`transcript_tailer.ex:112-120`); new session with `start_reason: "fork"` or `"compact"`, never a rewrite. |
| Journal head lost | Rebuilt by scanning segments. |
| Clock skew | `observed` anchors use the daemon's `observed_at` on both sides, so skew between provider and daemon does not move them. |
| Very long history | Paging by `pos`; the dashboard never loads the whole file. |
| Client cannot read Executor conversation (no binding) | `{:error, :not_found}` with capability reason, not an empty list. |

## 12. Privacy

- Transcripts can hold secrets the agent printed. Storage is owner-only (§6).
  Reads need dashboard auth or a device bearer. No public route. Device reads are
  masked (§7, security M5); the masking is best-effort pattern redaction, and the view
  still says that transcripts may contain secrets.
- Operator lines come only from daemon delivery evidence for workers (§5, security M6).
- Executor transcripts are the operator's own session. Capture is opt-in (MP-E3).
- Clients get `locator_hash`, never raw provider file paths.
- Push payloads (MP-N4) carry an `EntryRef`/`anchor_id`, never entry bodies.

## 13. Versioning

Every record has `v`. Readers accept unknown fields. A breaking change is `v: 2`
with both versions readable for one release.

## 14. Assumptions about contracts owned by others

| Contract (owner) | What this contract needs |
| --- | --- |
| Events and replay (MP-R2) | Durable `event_id`, `topic`, `ticket_observation` (tracker identity, `observed_at`, `provenance.source_event_id`) per event; the in-BEAM `Exchange.subscribe/1` (exists); later the export journal (R2-C6) for downtime backfill; `executor.*` journal replay. The envelope's reserved `anchor` field (events contract §4.2) is `{conversation_id, pos, placement, precision}` per RC-07 (adopted in Phase D, CR-E4-1). Anchor backfill from the export journal is a consumer-side follow-up after R2-C6 (events §12, CR-E4-7). |
| Harness adapter (MP-R7) | Per harness: a transcript source that turns provider records into entries with `provider_msg_id`, `tool_call_id`, `turn_id`; session-boundary signals (SessionStart source, thread change). Must cover **attached external sessions** (Executor), not only daemon-spawned ones. |
| Listener mode (MP-E7) | `send(ConversationRef, text, client_request_id) -> delivery_id`, the receipt set defined in listener-mode §7 (not restated here, X-39), and the effective mode, for both subjects. For workers the `delivery_id` is the `AgentChat` queue item id, which the journal already records as `refs.delivery_id` at delivery (§5). For the attached Executor (E7-C6 hook transport) the receipt must echo `delivery_id` inside the delivered frame so the Executor transcript record can be matched. |
| Command request and resolution (MP-E2) | `Decision.source.session_id` and `event_id` filled for worker and Executor requesters; `answer` with `expected_version`. |
| Identity (MP-R1, RC-01/02/04) | `instance_id = <machine_id>/<instance_key>` for `GlobalEntryRef`; not used to derive `conversation_id` (§3). |
| Stream Deck (MP-R6, RC-06) | R6-C1 ships `Aiur.Conversation.Anchors.at_or_before/2` behaviour-preserving; E4-C3-T01 extends it; E4-C7 moves the deck's data source onto `History`. |

## 15. Phase C changes (2026-10-06)

- RC-02: `instance_id` form; `conversation_id` no longer hashes `instance_id` (§3).
- RC-07: `pos` is the only entry identity; the hash field is renamed
  `dedup_key` (§5); anchors carry `placement` (§10).
- RC-06: the neutral anchor module name and the R6/E4 split (§10).
- Verified: exact anchoring reads the tool call id from the bus event's own
  `provenance.source_event_id`, not from the per-launch publication log (§10).
  A census of the live fleet logs (48 launches, 2,164 completed publications,
  read 2026-10-06) found 1,851 (85.5 %) whose `tool_call_id` equals a tool
  transcript entry's `msg_id` in the same launch; MP-E4-C3-T02 re-measures it.
- Verified: a third worker ingest point (the Remote-Control display path) and
  the operator-delivery point (§6, §5).
- Live events reach the resolver only by live subscription (§10).
