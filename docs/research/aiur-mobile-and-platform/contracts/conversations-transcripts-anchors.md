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
