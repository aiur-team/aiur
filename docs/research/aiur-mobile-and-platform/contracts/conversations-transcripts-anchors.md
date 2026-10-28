# Conversations, transcripts and anchors — persisted foundation

This records the foundation implemented by MP-E4-C1-T01. The earlier contract
referenced by the research tickets is absent from the integration branch and
its cited research revision. These sections restate the ticket's specified
identity, records and storage contract; they do not define the later reader,
writer process or anchor APIs.

## §3 — Conversation identity

`Ref` is version 1 with subject `{:worker, TrackerIdentity.t()}` or `:executor`.
Only joinable tracker identities have worker conversations. The canonical text
is `worker:github:<lowercase-owner>/<lowercase-repository>:<provider_id>` or
`executor`. Display identifiers do not participate in identity. The ID is
`conv_` followed by the first 26 lowercase, unpadded Base32 characters of the
SHA-256 digest of the canonical text. Instance/project separation comes from
the enclosing decision-state root.

`subject.json` is written once. It contains `v`, `conversation_id`, `kind`,
and, for a worker, `owner`, `repository`, `identifier`, `provider_id`. The
identifier is informational and remains the original display locator.

## §4 — Session records

A session carries `v: 1`, `session_seq`, `harness`, `provider_session_id`,
`aiur_attempt_id`, `aiur_run_id`, `first_pos`, `last_pos`, `started_at`,
`ended_at`, `start_reason`, and `end_reason`. Sequences and positions are
positive integers. Times encode as ISO 8601 strings. Unknown optional values
are null.

The session journal contains append-only lines with `type: "start"` or
`type: "end"`. Start lines omit end fields and `last_pos`; end lines contain
`v`, `session_seq`, `ended_at`, `end_reason`, and `last_pos`. No end operation
rewrites a start line. The later writer owns session lifecycle decisions.

## §5 — Entry records and provenance

An entry carries `v: 1`, `pos`, `session_seq`, `observed_at`, `occurred_at`,
`kind`, `role`, `body`, `body_truncated`, and `refs`. The writer assigns
position, session sequence and observation time. Transcript conversion returns
an input with these writer-owned fields unset.

The optional extension fields are:

| Field | Meaning |
| --- | --- |
| `output` | Command output, tool result, or edit diff text; null when absent. |
| `output_truncated` | Whether output was shortened; false by default. |
| `meta` | Structured details: command `exit_code`/`cwd`, tool `tool`/`success`, `provider_role`, or `alert`. |

Kinds are `message`, `reasoning`, `command`, `diff`, `tool_result`,
`operator_message`, `system`, and writer-generated `gap`. Assistant deltas are
skipped. Assistant/reasoning/command records have role `agent`; tools and diffs
have role `tool`; system/alert records have role `system`.

A worker provider `user` record is `system` / `provider_input` with
`meta.provider_role: "user"`. Only the daemon delivery tee supplying a
nonempty `payload.delivery_id` may produce `operator_message` / `operator`.
Callers reading agent-writable provider files must never copy an untrusted
delivery claim into that field. Executor input uses role `executor_operator`
only after its source path has been validated by the Executor ingest boundary.
The two roles have distinct dedup keys even when they describe the same text.

Refs carry `provider_msg_id` from `msg_id`, optional `provider_item_id`,
`turn_id`, and `delivery_id`. Commands, tools and diffs carry `tool_call_id`
from the payload or, failing that, `msg_id`. Dedup selects the first nonempty
provider message ID, provider item ID, or tool call ID, together with role;
otherwise it hashes role, turn ID, occurred-at time and body. The result is
an opaque `ent_` ID. Two identical fallback commands at different times stay
separate.

Both body and output are bounded independently: 16,384 bytes for `command`
and `tool_result`, 65,536 bytes for other kinds. Overlong text retains at most
one quarter of the bound at each end, preserving UTF-8 boundaries, with
`\n…[N bytes omitted]…\n` between them. The marker counts toward the bound.
Invalid UTF-8 bytes become U+FFFD before encoding. Reasoning is retained;
its display policy belongs to later surfaces. No pruning is implemented.

## §6 — Store API and durability

`Store.prepare(dir)` prepares owner-only files and returns `{:ok, head}`.
`Store.prepare(dir, ref)` also creates/verifies immutable subject metadata,
published only after the staged bytes have been synced.
The caller obtains the enclosing root through `Paths.conversation_state_dir/0`
and appends `Ref.conversation_id(ref)` to select a conversation directory.
That path accessor defaults to `<decision_state_dir>/conversations` and
supports an Application override for isolated tests; no config key is added.

`append_entries(dir, head, records)` performs one raw write and one file sync
per batch. It rolls before a batch that exceeds the current segment's budget;
a single batch larger than the segment budget returns `:batch_too_large`.
A failure acknowledges nothing. Complete lines may have survived a failed
batch: callers must rebuild state before reconciling or retrying it.

Session and anchor lines append and sync without replacing earlier lines.
Directories use mode 0700; files use 0600. Symlinked conversation paths and
files are refused. Only `head.json` is replaced atomically. Recovery syncs surviving complete
entry and session records before publishing their positions.

## §8 — Segments and recovery

Segments are named `entries.000001.jsonl`, `entries.000002.jsonl`, and so on,
with an 8,388,608-byte production bound. Records require `v: 1` and strictly
increasing positive integer `pos`, including across segment boundaries.

The head cache contains `v`, `last_pos`, `last_session_seq`, and `segments`
with `n`, `first_pos`, `last_pos`, `bytes`. `sessions_bytes` is an additional
cache freshness stamp. Missing, malformed, or stale caches are rebuilt.
Only an incomplete tail of the final entry segment is eligible for
recovery truncation; side journals refuse appends after a torn tail, and complete corrupt records return
`{:error, {:corrupt, filename, line}}`. Earlier segments are never repaired.

`stream_entries(dir, from_pos, to_pos)` returns `{:ok, enumerable}` over the
inclusive range (`:infinity` is supported). With a current head it opens only
overlapping entry segments. Rebuilding a stale head necessarily reads the
segments first. The store is a pure file API for one writer, with no process,
PubSub, page cursor, retention, or anchor-resolution policy.

Callers must serialize recovering reads with appends. A stale-head rebuild
may truncate an incomplete final line, so it must never run against an
in-flight writer batch. The later writer/reader integration owns this ordering.

## §10 — Journal positions and precision

`Anchors.exact(event, entries)` and `decision_source(event, entries)` return
`{:ok, anchor}` or `:none`. `position(event, entries, sessions)` always returns
`{:ok, anchor}`, including unanchored results. These pure functions scan one
conversation's bounded window in linear time. Callers supply `conversation_id`,
`event_id`, `kind` and `topic` in the event, plus daemon `observed_at`, optional
`occurred_at`, `source_tool_call_id`, `decision_tool_call_id`, `label` and
`subject_ref`. Times may be DateTimes or journal ISO 8601 strings.

Anchors are JSON maps with `v: 1`, `anchor_id`, `kind`, `conversation_id`,
`event: {event_id, topic, observed_at, occurred_at}`, `pos`, `placement`,
`precision`, `method`, `label` and `subject_ref`. Missing optional metadata
is null. Supplied labels and subject references are preserved.

Exact matches use `refs.tool_call_id`, placement `at`, precision `exact` and
method `tool_call`. Command requests (`command_requested`) instead match
`decision_tool_call_id` with method `decision_source`. Missing or empty tool
IDs never match missing refs.

Observed placement selects the greatest position whose daemon `observed_at`
is at or before the event's observation time, including ties. It requires a
session covering that time (inclusive start/end; a null end is open) and no
gap spanning it. Gap entries carry inclusive `from`/`to` observation times in
`meta`; an unreadable or missing bound covers that entire side of the gap.
The gap row itself is never a target. Observed anchors use placement
`after` and method `observed_at`. Otherwise precision is `unanchored`, with
null position, placement and method. Provider occurrence times never affect
placement. The deck's `at_or_before/2` membership rule remains unchanged:
an equal-time entry belongs to the event's group.

`strongest/1` keeps one anchor per event ID, kind and conversation, preferring
`exact > causal > observed > unanchored`. It preserves first-seen group order
and the first anchor at equal precision. Causal inference belongs to C3-T03.

`anchor_id/1` hashes the JSON array `[event_id, kind, conversation_id, precision]`
with SHA-256 and returns `anc_` plus the first 26 lowercase, unpadded Base32
characters. Position and labels do not affect identity; upgraded precision
creates a new identity for append-only resolution.

## §7 — Serialized ingestion

`Ingest.append(ref, source, events)`, `end_session(ref, provider_id, reason)`
and `gap(ref, reason, from, to)` return `:ok` without waiting for disk. The
facade converts transcript events before casting to a Registry-named writer.
Each conversation has one `Journal` process under `JournalSupervisor`; initial
file preparation runs after process startup. Producers are wired separately.

The writer assigns dense positions, batches at most 50 transcript inputs from
one source per entry append, and flushes small batches after 200 ms. Session
identity is `{harness, provider_session_id}`. A changed identity closes the old
session as `superseded`. An explicit end applies only to the matching provider
(or any open session when its provider ID argument is null). Deduplication is
scoped to the open session and retains the latest 50,000 distinct keys.

On reload, a session from the current BEAM run continues with dedup rebuilt
from its durable entries. A session from another run closes as
`daemon_restart_unknown`; the next source starts a `resume` session. An idle
healthy writer flushes and stops after 15 minutes. A later input starts it again.

Failed writes require head reconstruction before any retry. Complete surviving
records are retained and deduplicated; only the store's eligible torn final
entry tail is repaired. Interior corruption leaves the writer read-only.
Readers that use the store's recovering APIs must serialize those calls with
this writer; calling `read_head` or `stream_entries` independently during an
append is unsafe. This writer does not add a journal page-reading API.

## §11 — Gaps and durable notifications

A failed flush retries with exponential backoff, starting at 1 second, for up
to five retries. Exhaustion drops buffered inputs while retaining their observed
span for a later `source_unreadable` gap. A mailbox exceeding 5,000 messages
drops incoming transcript batches, increments the per-conversation dropped
counter, and retains a `backpressure` span. Gap bounds are daemon observation
times; provider occurrence times never define a missing observation span.

The first failure emits `system.conversation.journal.degraded`, naming only the
conversation and error class. Recovery emits its `.resolved` companion.
After fsync, PubSub topic `conversation:<conversation_id>` receives
`{:entries_appended, conversation_id, entries}` and
`{:session_changed, conversation_id, session}`. Head reconstruction syncs
uncertain surviving records before their recovery notifications are published.
