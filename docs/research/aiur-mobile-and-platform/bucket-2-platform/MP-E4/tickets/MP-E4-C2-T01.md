---
ticket_id: MP-E4-C2-T01
feature_id: MP-E4
chunk_id: MP-E4-C2
bucket: 2-platform
title: "Conversation.History: paged reads by position, sessions, live subscribe and catch-up"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T02]
prior_units: [U6]
prior_boundaries: [PRJ]
prior_features: []
prior_findings: [contract conversations-transcripts-anchors §7]
size_owner: n/a (new module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C2-T01 — History read API

## Identity and outcome

- Bucket 2 · MP-E4 · C2 · T01.
- **User value:** one read path for the dashboard, JSON clients, the Stream
  Deck (C7) and later the phone (MP-N6), able to page a conversation of tens
  of thousands of entries and to resume without gaps.
- **Deliverable:** `Aiur.Conversation.History` with `list_entries/2`,
  `list_sessions/1`, `list_anchors/2`, `subscribe/1`, `catch_up/2`; an ETS head
  table the writer updates after each flush.
- **Phase D (security M5):** `list_entries/2` and `catch_up/2` mask secrets by
  principal at read time; the journal is never rewritten.
- **Non-goals:** HTTP (C2-T02), UI (C5), anchor resolution (C3).

## Dependencies and blockers

- DESIGN-E4; MP-E4-C1-T02 (writer, files, PubSub messages).
- Concurrent with: MP-E4-C1-T03, MP-E4-C3-T01.

## Verified starting point

- Today's only cursor is a byte offset into a per-launch IssueLog file
  (`AgentEventFeed.list/2` → `IssueLog.read_tail/2`,
  `src/lib/aiur/agent_event_feed.ex:76-91`; `issue_log.ex:111-141`), limit
  ≤ 50. It cannot serve a full or durable history (contract §1).
- `LiveConversation` snapshots are bounded to 80 messages / 64 KB
  (`live_conversation/retention.ex:6-10`).
- Files produced by T01/T02: `entries.<n>.jsonl`, `sessions.jsonl`,
  `anchors.jsonl`, `head.json` (contract §6).

## Chosen design

PROPOSED `src/lib/aiur/conversation/history.ex`; edit `journal.ex` (T02) to
upsert `{conversation_id, last_pos, segments}` into a public ETS table
`:aiur_conversation_heads` (created by a small owner process
`Aiur.Conversation.HeadTable`, a supervised child next to the Registry) after
every successful flush. Readers never call the writer, so a busy writer never
slows a page.

```elixir
@type cursor_opt :: {:before, pos_integer()} | {:after, non_neg_integer()} | {:around, pos_integer()}
                  | {:from_start, true} | {:tail, true}
@spec list_entries(Ref.t() | String.t(), keyword()) :: {:ok, page()} | {:error, :not_found | :unavailable | :invalid_cursor | :invalid_limit}
@type page :: %{entries: [map()], sessions: [map()], prev_cursor: pos_integer() | nil,
                next_cursor: pos_integer() | nil, head_pos: non_neg_integer(),
                complete_from_start: boolean(), observed_at: DateTime.t()}
@spec list_sessions(Ref.t() | String.t()) :: {:ok, [map()]} | {:error, :not_found | :unavailable}
@spec list_anchors(Ref.t() | String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found | :unavailable}
@spec subscribe(Ref.t() | String.t()) :: :ok          # PubSub "conversation:<id>"
@spec catch_up(Ref.t() | String.t(), non_neg_integer()) :: {:ok, [map()], non_neg_integer()} | {:error, term()}
```

**Cursor semantics (all by `pos`, never time):**

| Option | Returns (ascending `pos`) | `prev_cursor` / `next_cursor` |
| --- | --- | --- |
| `tail: true` (default) | the last `limit` entries | first pos if earlier exist / nil |
| `before: p` | the `limit` entries with `pos < p` closest to `p` | first pos if earlier exist / last pos if later exist |
| `after: p` | the `limit` entries with `pos > p` closest to `p` | same rule |
| `around: p` | `div(limit, 2)` before `p`, `p`, the rest after | same rule; `:not_found` if `p > head_pos` |
| `from_start: true` | the first `limit` entries | nil / last pos if later exist |

- **Principal and masking (contract §7).** `opts[:principal]` is required
  (`{:operator, :loopback | :basic_auth} | {:device, device_id} | :internal`); a call
  without it raises `ArgumentError`. For `{:device, _}`, every returned `body` and
  `output` goes through `Aiur.SecretRedactor.redact/1` then `redact_urls/1`
  (`secret_redactor.ex:49-60`), and `redacted: true` is set on an entry whose text
  changed; `reveal` is ignored. For `{:operator, _}` the default follows DESIGN-E4
  decision 4 (proposed: mask; `reveal: true` honoured only for `:loopback`).
  `:internal` is unmasked and is used only by in-daemon readers that never serialize
  bodies to a client (the anchor resolver). The C7 Stream Deck projection reaches a
  client, so it reads as `{:operator, :basic_auth}`. Note that `redact_urls/1`
  replaces **every** `http(s)`/`ws(s)` URL (`secret_redactor.ex:24-42`), PR links
  included; that is the accepted cost on devices until DESIGN-E4 decision 4 narrows it.
  Masking runs on the decoded page, after the cursor walk, so `pos` and
  cursors are identical for every principal. `subscribe/1` delivers raw entries;
  `Aiur.Conversation.History.mask_for/2` is the one function a socket handler (MP-N6)
  calls before pushing, so live and paged reads mask the same way.
- Exactly one cursor option; two → `{:error, :invalid_cursor}`. `limit`
  1..200, default 50, else `:invalid_limit`.
- `kinds: [...]` filters, but `gap` entries are always returned; a filtered
  read scans at most 5,000 entries and then returns a short page with a
  `next_cursor`, so one request is bounded.
- `sessions` = the sessions overlapping `[first_pos, last_pos]` of the page.
- `complete_from_start` is `false` when the conversation's first entry is a
  `gap` with reason `pre_journal` or its first session has `start_reason:
  "import"`.
- Reading: pick segments from the head table's `segments` list; stream lines
  of only those segments; decode with `Entry.from_json/1`; stop when the page is
  full. A missing head row falls back to `Store.read_head/1`.
- `catch_up(ref, last_pos)` loops `after:` pages until `next_cursor` is nil;
  callers subscribe **first**, then catch up, then drop live messages with
  `pos <= returned head` (the reconnect rule, contract §7).

## Implementation steps

1. `HeadTable` owner process + child; writer upsert after flush (≤ 10 lines in T02's module).
2. `History` functions above, accepting a `Ref` or a raw `conversation_id`
   (validated against `~r/^conv_[a-z2-7]{26}$/` before any path join).
3. `list_sessions/1` folds `sessions.jsonl` start/end lines by `session_seq`.
4. `list_anchors/2` reads `anchors.jsonl`, keeps the strongest per
   `(event.event_id, event.kind)`, filters by `kinds`, `pos_range`, `since`.

## Non-happy paths

- **Unknown or malformed id** → `:not_found` (the regex blocks path traversal).
- **Segment unreadable or corrupt** → `:unavailable`; never a partial page that
  looks complete.
- **Reader races the writer:** a line being appended may be torn; the reader
  only returns entries with `pos <= head table last_pos` (written after fsync),
  so it never returns an unacknowledged line.
- **Executor conversation not attached** → `:not_found`; the caller (MP-E3)
  turns it into the capability reason, not an empty list (contract §11).
- **Conversation with only gaps** → entries are the gaps; `complete_from_start`
  false.

## Compatibility and rollout

- New module and one supervised ETS owner. No behaviour change. Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/history_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| property "random page walks cover every pos exactly once" (StreamData: 1..3,000 entries over random segment bounds; walk back from tail with `before:` and forward from start with `after:`) | union = 1..N, no duplicate | cursor arithmetic |
| "around centers on p" | `p` at index `div(limit,2)` when enough entries | `around` clause |
| "around beyond head is not_found" | `{:error, :not_found}` | head check |
| "reader never returns an entry past the head table" (append a torn line by hand) | page ends at head | head-table bound |
| "subscribe then catch_up then live: no gap, no duplicate" | positions contiguous | the drop-`<= head` rule in the helper |
| "kinds filter keeps gaps and bounds the scan" | gaps present; ≤ 5,000 scanned (counter) | gap passthrough / scan cap |
| "two cursor options is invalid_cursor" | `{:error, :invalid_cursor}` | option validation |
| "conversation id with ../ is not_found, no file touched" | `:not_found` | id regex |
| "pre_journal first gap → complete_from_start false" | false | the flag rule |
| **"device principal receives redacted body; journal bytes unchanged"** (M5) | fixture entry body `"token ghp_" <> 36 chars` and a `https://user:pw@host` URL; `{:device, "d1"}` page → neither secret present, `redacted: true`; `sha256` of the segment file equal before and after | the principal branch (remove it and the token is returned) |
| "operator loopback reveal returns raw; basic_auth reveal is ignored" | raw for `{:operator, :loopback}` + `reveal: true`; masked for `{:operator, :basic_auth}` + `reveal: true` | loopback check |
| "missing principal raises" | `ArgumentError` | required-opt check |
| "mask_for/2 masks a live entry the same as a page" | equal bodies | shared masking function |

## Completion and handoff

- [ ] Tests green; `make ci` green on the head SHA.
- Dependents: MP-E4-C2-T02, MP-E4-C5-T01, MP-E4-C7-T01, MP-E3-C6-T01, MP-N6.
- Docs: none (API documented in C2-T02).
