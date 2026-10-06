---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-E4
bucket: 2-platform
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: DESIGN-E4
contracts_owned: [MP-CT-conversations-transcripts-anchors]
contracts_consumed: [events-and-replay (MP-R2), harness-adapter (MP-R7), listener-mode (MP-E7), command-request-resolution (MP-E2), identity]
prior_units: [U4, U6, U8]
prior_boundaries: [RUN, WEB, SD, BUS, DEC, PRJ]
---

# MP-E4 — Dashboard conversations and event navigation: plan

Chunks: [chunks.md](chunks.md). Owned contract:
[../../contracts/conversations-transcripts-anchors.md](../../contracts/conversations-transcripts-anchors.md).
Owner gate: [../../owner-design-tasks/DESIGN-E4.md](../../owner-design-tasks/DESIGN-E4.md).

## 1. Goal

Show the full worker and Executor transcripts in the dashboard, with event jump
points (progress updates, pushes, PR creation, merges, Command requests) that
take the operator to the conversation position where they happened. Keep the
event ↔ instance ↔ agent/session ↔ position relationship as data that phone and
watch (MP-N6) reuse. Write access is only: send a message (through the listener
mode, MP-E7) and answer that agent's open Commands (D15). Logs are never
rewritten; controls stay where they are.

## 2. Repository findings (extends baseline E4)

### 2.1 Transcript storage today — none of it is a complete history

| Store | Shape | Durability | Evidence |
| --- | --- | --- | --- |
| Workspace `logs/agent.ndjson` + `agent.md` | The backend message map as-is; always `event`, `timestamp`; no id, no seq. Append only, no rotation. | Deleted with the workspace (`File.rm_rf`). Not written at all for remote workers. Rewritten (old prefix + new, temp + rename) on workspace rebuild. | `agent_event_log.ex:23-48,24`; `workspace/remove.ex:25,61`; `workspace/reconstruction` merge (`finish_promotion`) |
| IssueLog `.agent_events.jsonl` | `role, body, timestamp, msg_id, sequence, turn_id, payload`; body cut to 1,000 chars, diffs to 2,000; records over 16 KiB reduced. | Per-launch log root: "does not survive a daemon restart". | `issue_log.ex:37,680-805`; `config/paths.ex:27-36` |
| IssueLog `.log` / `.events.log` | Human lines and bus markers `[event:<kind>] id=<id> topic`. | Per launch. | `issue_log.ex:298-327,946-971` |
| `Aiur.LiveConversation` | Normalized messages; states `:live|:ended|:known_empty|:stale|:unavailable|:restart_unknown`. | Memory only; 80 messages / 64 KB; generation is a per-BEAM integer. | `live_conversation.ex:6-47,680-687`; `retention.ex:6-10`; `dispatcher.ex:2494` |
| `Aiur.SessionHandle` | `{backend, thread_id}` per ticket. | Durable (`runtime_state_dir`), resumable local backends only. | `session_handle.ex:2-20`; `session_resume.ex:150-160` |
| Event publication log | `tool_call_id`, `topic`, `event_id`, status per agent `emit_event`. | Per launch, fsynced, never read by the daemon. | `event_publication_log.ex:1-36`; `tool_executor.ex:423-503` |

**Single ingest point for worker transcripts:** the closure built by
`AgentRunner.MessageHandler` (`agent_runner/message_handler.ex:52-63`) sees every
normalized backend message and its `transcript_event` for every backend and for
remote workers too. It already fans out to `AgentEventLog`, transcript broadcast
and `LiveConversation`. The journal tee belongs there.

### 2.2 Readers and UI today

| Surface | Source and window | Evidence |
| --- | --- | --- |
| Conversation drawer (`/chat/:owner/:repository/:identifier`) | `LiveConversation` snapshot (80 messages); states labelled Live / Ended / Stale / Unavailable / Continuity unknown | `router.ex:141`; `operator_control_center/conversation_drawer/presenter.ex:5-213`; `dashboard_live.ex:2254-2267` |
| Agent log modal | `AgentLog.read_workspace/1`: whole file read, last 80 messages, no cursor | `agent_log_modal.ex:148-162`; `agent_log.ex:25,42-53,147-159` |
| `GET /api/v1/:issue_identifier/events` | `AgentEventFeed.list/2`: limit ≤ 50, byte-offset cursor into the per-launch JSONL | `router.ex:191`; `agent_event_feed.ex:76-91,310-329` |
| Stream Deck logs | `StreamdeckLogs.load/1`: 50 newest transcript rows + 40 bus events; "last event at or before" anchoring | `streamdeck_logs.ex:306-338,628-635`; `agent_event_feed.ex:106-114` |
| Send | LiveView `send-operator-message` → `AgentChat.send/3`; API `POST /api/v1/:id/messages`; gated by `observability.dashboard_writable` (schema default **true**; the router comment still says "disabled by default") | `dashboard_live.ex:640-661,2662-2693`; `router.ex:55-62,151-164`; `config/schema/observability.ex:12` |
| Commands answer | `/commands/:decision_id`; `answer-decision` etc. | baseline E2 |

`dashboard_live.ex` is 2,903 lines at `45a290e3` (U8 package `WEB`). New
conversation code goes into new modules.

### 2.3 Milestone and event model to reuse

- Bus event ids are durable (`events/id_generator.ex:2-11`); `bus_events/2`
  returns `%{id, kind, topic, label, body, timestamp}` (`agent_event_feed.ex:231-244`).
- Labels exist for progress, phase, blocked/unblocked, paused, comment, PR
  opened/merged, review comment, CI, decision requested/seen/resolved
  (`agent_event_feed.ex:52-72`). **Missing:** `branch.push` (pushes) and
  `executor.*`.
- Pushes are observed by `ls-remote` polling every 30 s
  (`events/ls_remote_ticker.ex:4`) or by webhook; their time is observation time.
- `Decision.source.session_id` is the provider thread id
  (`tool_executor.ex:602,691`), so a Command can find its session.

## 3. Proposed boundaries

```text
aiur_conversations  NEW component (projection family PRJ, prior boundary #28)
  Conversation.Journal        single writer per conversation; positions; sessions; gaps
  Conversation.Ingest         worker tee (MessageHandler) + Executor (MP-E3) + importer
  Conversation.History        list_entries / list_sessions / subscribe (contract §7)
  Conversation.Anchors        resolver: exact | causal | observed | unanchored (contract §10)
  Conversation.JumpPoints     catalogue: topic → kind/label (extends AgentEventFeed labels)
aiur_web
  ConversationLive / component  full chronology + event rail; worker and Executor modes
  JSON: /api/v1/conversations/:id/{entries,sessions,anchors}
Stream Deck (MP-R6)
  StreamdeckLogs → calls Conversation.Anchors(:observed rule) and History (behaviour-preserving)
```

Required deps: event bus ids/history (BUS), `TrackerIdentity`. Optional:
listener mode (MP-E7: without it the composer falls back to today's `AgentChat`
path for workers, see §5), Commands (MP-E2), Executor (MP-E3). The journal must
work without the dashboard running (it is daemon-side).

## 4. Alternatives and recommendation

### 4.1 Where full history lives

| Option | For | Against |
| --- | --- | --- |
| A. **New durable append-only journal** per conversation outside workspace and launch dirs, with a writer-assigned `pos` | Survives restart and workspace removal; one position space for anchors; same for workers and Executor; meets brief §3 "retain complete transcripts". | New store, new disk usage; must not slow the agent message path. |
| B. Make the IssueLog root durable and use byte offsets | Smallest code change. | Byte offsets differ per file and producer (`issue_log.ex:114-116`); bodies already truncated to 1,000 chars; three formats; IssueLog also feeds agents' replay, so changing it is cross-cutting. |
| C. Read provider transcripts on demand | No copy. | Workers' files die with the workspace; Codex app-server workers have no file aiur owns; no shared positions. |

**Recommendation: A.** IssueLog stays as is (it feeds `BootstrapDigest`). The
journal is a separate, display-oriented record. Writes are batched off the
message path (cast to the writer; the writer fsyncs per batch) so a slow disk
cannot stall a turn.

### 4.2 How events point into conversations

| Option | Verdict |
| --- | --- |
| Timestamps only (StreamdeckLogs rule) | Kept as the `observed` fallback. Ambiguous under bursts and clock skew. |
| **Strongest-provable precision ladder** (exact tool-call match → causal command match → observed → unanchored), stored as append-only anchors | **Chosen.** Exact for agent-emitted events (progress, phase, Command request) because `tool_call_id` and `event_id` are already recorded together. |
| Inject markers into transcripts | Rejected: rewrites the agent's input; logs are never rewritten. |

### 4.3 What "write" means (settled, D15)

Send a message (via MP-E7) and answer that agent's open Commands. Pause,
resume, interrupt and spawn stay where they are today (drawer `Pause`, TUI,
CLI). No editing, hiding or deleting of entries.

## 5. Send path before and after MP-E7

E3 and E4 are wave 3 and E7 is wave 4
([value-and-sequencing.md](../../value-and-sequencing.md)), so E4 must work
before E7 exists:

- **Workers, before E7:** the composer uses today's `AgentChat.send/3`
  (`agent_chat.ex:14-19`) with its existing queued/delivered statuses. This is
  not new behaviour; it moves the existing drawer composer into the new view.
- **Workers and Executor, after E7:** the composer calls the listener-mode
  service; the overlay shows E7 receipts.
- **Executor, before E7:** read-only, composer disabled with the reason (MP-E3).

**Superseded by RC-05 (Phase C):** MP-E7-C1–C3 move into wave 3 ahead of the
write chunks, and E7-C3 ships behind a flag that keeps today's behaviour. E4-C6
therefore ships once, on `Aiur.Listener.send/3`, with no interim `AgentChat`
step (MP-E4-C6-T01).

## 6. Non-happy paths

| Case | Behaviour |
| --- | --- |
| No transcript yet | "No messages yet" (known empty) distinct from "unavailable". Reuse the drawer state vocabulary (`presenter.ex:188-213`). |
| History before the journal existed | Importer reads workspace `agent.ndjson` (if present) and current-launch IssueLog JSONL once, writes them as an `import` session, preceded by a `pre_journal` gap. Never claims completeness it lacks (`complete_from_start: false`). |
| Daemon restart mid-turn | `LiveConversation` already marks `:restart_unknown`; the journal ends the session `daemon_restart_unknown` and continues. |
| Remote worker | Expected to work because the `MessageHandler` closure runs in the daemon while only `AgentEventLog` skips remote hosts (`agent_event_log.ex:24`). Phase C must confirm this on an SSH worker (RQ-E4-5). |
| Duplicate messages (Codex deltas, replay) | `assistant_delta` skipped as `LiveConversation` does (`message_handler.ex:131-134`); entry `id` dedup. |
| Event with no session covering it | `unanchored`; shown in the rail without a jump. |
| Two events at the same position | Both listed on that position, ordered by `event_id`. |
| Long history (tens of thousands of entries) | Paged by `pos`, 50 default / 200 max; "load older" and "jump to start" use cursors; anchor jump loads `around: pos`. |
| Journal write failure (disk full) | Message path unaffected; a `gap` (`source_unreadable`) is written when writing resumes; one alert. |
| Reader behind live tail | Subscribe + `after: pos` catch-up; no gap from reconnect. |
| Command answered elsewhere | Command contract wins (first answer); the inline answer form shows resolved state from the Command store, not from the conversation. |
| Read-only dashboard | Full read; no composer; no Command answer buttons (same gate as today). |

## 7. Privacy and security

- Journal files 0600 in a 0700 dir; no public route; dashboard auth for reads.
- Bodies up to 64 KiB with head/tail truncation flagged; reasoning stored,
  display per DESIGN-E4.
- Phone (MP-N6) deep links carry `conversation_id` + `pos`/`anchor_id` only; the
  body is fetched over the paired, authorized channel (MP-N2/N4).
- No secret scrubbing is promised; the view must say transcripts may contain
  secrets the agent printed (owner question on display-time masking).

## 8. Acceptance criteria

1. A worker whose workspace was removed still has its full conversation in the
   dashboard after a daemon restart.
2. Every entry has a `pos`; paging `before`/`after`/`around` returns contiguous,
   non-overlapping pages; reconnect with `after: last_pos` yields no gap and no
   duplicate (property test).
3. A progress update emitted by `emit_event` anchors `exact` to the tool-call
   entry; a test fails if the resolver falls back to `observed` when the
   publication record exists.
4. `pr.merged` by another actor anchors `observed` to the last entry at or
   before `observed_at`; an event before the first session is `unanchored` and
   rendered without a jump (mutation test: replacing `unanchored` with "nearest
   entry" fails).
5. A Command opens its requester's conversation at the request position.
6. Pushes (`branch.push`) appear as jump points with the head sha.
7. Selecting a jump point loads `around: pos` and highlights the entry within
   one round trip.
8. The Stream Deck logs projection produces identical keys for its existing
   fixtures after it is moved onto the shared anchor rule
   (`streamdeck_logs_test.exs` unchanged and green).
9. No code path writes to a provider transcript or edits a journal line
   (static test: journal module exposes append-only functions only).
10. The journal tee adds no synchronous disk I/O to the agent message closure
    (test with a blocked writer: the closure returns).

## 9. Chunk summary (detail in [chunks.md](chunks.md))

| Chunk | Outcome | Depends on |
| --- | --- | --- |
| MP-E4-C1 | Durable conversation journal (contract §3–§6) + worker tee | MP-R2 event ids (exist today); identity |
| MP-E4-C2 | History API: paging, sessions, live subscribe, JSON routes | C1 |
| MP-E4-C3 | Anchor resolver + persisted anchors | C1, MP-R2 history read, MP-E2 source fields |
| MP-E4-C4 | Jump-point catalogue (push, executor, Commands) + Command→conversation links | C3 |
| MP-E4-C5 | Dashboard conversation view (worker; Executor mode for MP-E3) | C2, C4, **DESIGN-E4** |
| MP-E4-C6 | Write surface: composer (AgentChat then E7) + inline answer of this agent's open Commands | C5, MP-E2, later MP-E7 |
| MP-E4-C7 | Stream Deck logs on the shared anchor rule | C3, coordinate MP-R6 |
| MP-E4-C8 | Importer for pre-journal history + retention/privacy docs | C1 |

## 10. Open questions

**Owner (Kevin), in DESIGN-E4:**
- OQ-E4-1. Layout: one chronology with an event rail, or a split event list + transcript? (Designer's call; brief says Kevin designs it.)
- OQ-E4-2. Which jump-point kinds are on by default, and is CI/comments noise?
- OQ-E4-3. Show reasoning and raw tool output by default, collapsed, or hidden?
- OQ-E4-4. Display-time masking of likely secrets: wanted, or show raw?
- OQ-E4-5. Retention: confirm "keep forever, no automatic pruning" (brief §3 implies yes).
- OQ-E4-6. Does the existing drawer stay as the quick view with a link to the full view, or is it replaced?

**Research (Phase C):**
- RQ-E4-1. Journal throughput and size: measure entries/hour and bytes/hour per agent on the live fleet (census, AGENTS.md "measured, not estimated"). **Ticket MP-E4-C1-T00.** Preliminary census 2026-10-06 (deltas excluded): lower bound 249 entries/h and 112 KB/h per agent (p50, 389 ticket-launches); upper bound at a 64 KiB cap 228 KB/h p50, 3.0 MB/h p90 (352 workspaces, mostly 2026-08).
- RQ-E4-6. Does the bus event's tool call id match a transcript entry? **Census 2026-10-06:** 1,851 of 2,164 completed publications matched a tool entry `msg_id` in the same launch; re-measured in MP-E4-C3-T02.
- RQ-E4-2. `causal` matching rules for `git push` / `gh pr create` / `gh pr merge` command entries across Codex and Claude output shapes; false-positive rate on recorded transcripts.
- RQ-E4-3. Whether IssueLog's `observed_at` for bus events and the journal's `observed_at` share one clock (both daemon) — confirm for webhook-sourced events.
- RQ-E4-5. Confirm the `MessageHandler` closure runs daemon-side for SSH workers, so the journal tee covers them.
- RQ-E4-4. Import fidelity: which backends' workspace `agent.ndjson` can be replayed through `transcript_event_from/3` offline.

## 11. Plan-refresh note

If MP-R1/R2/R6/R7 land first: `aiur_conversations` sits in the projections
family (#28 `PRJ`); `MessageHandler` moves with `RUN` (#18) under R7, and the
tee becomes a subscription to the adapter's normalized transcript stream;
`StreamdeckLogs` anchoring moves to the shared resolver as part of MP-R6's
shared-projection split (E4-C7 and R6 must not both do it — coordinator to
assign). Event ids and history reads come from the `aiur_events` API (R2)
instead of `IssueLog.event_history/2`. If E4 precedes them, C1–C3 expose only
the contract interfaces above so the refactor moves, not rewrites, them.
