# Differently named concept probe

Frozen source: `3339b887196d5e9aefb273117a14bf33391ee41f`.
This is an independent, bounded lexical and source-role probe beyond the 275
inherited duplication-category findings. It searched every one of the 1,032
`src/lib/**/*.ex` files in the frozen snapshot. It did not edit production
or promote a raw finding. The terms were chosen as domain concepts, not
function names from the name-duplication census.

## Reproducible search boundary

For each Python regex in the code block below, count each `re.findall` hit in each frozen
`src/lib/**/*.ex` file and count a file once if it has any hit. All terms
used `re.IGNORECASE` where marked `(?i)`. The broad terms intentionally
maximize recall; counts are lexical matches, not duplicate implementations.

| Concept / Python regex | Files | Hits |
|---|---:|---:|
| Freshness: `(?i)freshness\|observed_at\|age_ms\|stale_after` | 196 | 2,330 |
| Identity: `(?i)same_(run\|identity\|repo\|ticket)\|normalize_(repo\|identity\|ticket)\|ticket_key` | 31 | 160 |
| Retry deadline: `(?i)monotonic_time\|deadline\|sleep_until\|retry_after` | 88 | 549 |
| Timestamp: `DateTime\\.from_iso8601\|NaiveDateTime\\.from_iso8601\|ISO8601` | 83 | 97 |
| Path safety: `Path\\.expand\|Path\\.relative_to\|realpath\|canonicalize\|symlink` | 87 | 302 |
| Write authority: `(?i)read.only\|can_write\|write_policy\|allow_write` | 60 | 99 |
| Quota: `(?i)rate.limit\|request_cost\|resource_pool\|github_quota` | 132 | 874 |
| Ticket topics: `ticket\\.\\#\\{\|String\\.split\\(topic\|Regex\\.run\\(.+ticket` | 50 | 127 |
| Token dimensions: `input_tokens\|output_tokens\|cache_read\|cache_write` | 29 | 250 |
| Source health: `(?i)source_health\|degraded\|last_known_good\|unavailable` | 360 | 2,712 |
| Pagination: `(?i)next_page\|page_info\|has_next_page\|link.*next` | 24 | 107 |
| Durable write: `File\\.rename\|File\\.sync\|fsync\|atomic_write` | 47 | 127 |
| Terminal state: `(?i)cancelled\|canceled\|terminal_state\|terminal\\?` | 59 | 349 |
| Coalescing: `(?i)flush_scheduled\|debounce\|coalesce` | 34 | 199 |

The exact regexes used for the counts (the table above escapes Markdown
punctuation):

```python
queries = {
    "freshness": r"(?i)freshness|observed_at|age_ms|stale_after",
    "identity": r"(?i)same_(run|identity|repo|ticket)|normalize_(repo|identity|ticket)|ticket_key",
    "retry_deadline": r"(?i)monotonic_time|deadline|sleep_until|retry_after",
    "timestamp": r"DateTime\.from_iso8601|NaiveDateTime\.from_iso8601|ISO8601",
    "path_safety": r"Path\.expand|Path\.relative_to|realpath|canonicalize|symlink",
    "write_authority": r"(?i)read.only|can_write|write_policy|allow_write",
    "quota": r"(?i)rate.limit|request_cost|resource_pool|github_quota",
    "ticket_topics": r"ticket\.\#\{|String\.split\(topic|Regex\.run\(.+ticket",
    "token_dimensions": r"input_tokens|output_tokens|cache_read|cache_write",
    "source_health": r"(?i)source_health|degraded|last_known_good|unavailable",
    "pagination": r"(?i)next_page|page_info|has_next_page|link.*next",
    "durable_write": r"File\.rename|File\.sync|fsync|atomic_write",
    "terminal_state": r"(?i)cancelled|canceled|terminal_state|terminal\?",
    "coalescing": r"(?i)flush_scheduled|debounce|coalesce",
}
```

The follow-up read representative cross-domain matches in provider/runtime,
orchestrator, GitHub, events, Build Order, storage, telemetry, web, CLI, and
workspace code. Only the queue below received source-role judgment. The large
freshness and source-health populations were sampled, not exhaustively read.

## Candidate and rejection queue

| Probe | Frozen source anchors | Judgment and inherited overlap |
|---|---|---|
| Fallible ISO instant parsing under unlike names | `src/lib/aiur/executor/roster.ex:130-166`; `src/lib/aiur_web/streamdeck_projection.ex:488-499`; `src/lib/aiur_web/streamdeck_logs.ex:539-549`; `src/lib/aiur/run_telemetry/writer.ex:443-476` | **Existing candidate, no new ID.** Roster turns an invalid timestamp into `false` for stall checks; Stream Deck turns it into `nil` for presentation; Writer substitutes the clock only for lifecycle/clock timestamps and preserves other binary timestamps. The parser mechanics may be shared with a caller-supplied failure policy. `loose-4-16`, `telemetry-usage-19`, `web-occ-16` already describe this family. |
| Path checking under unlike names | `src/lib/aiur/path_safety.ex:79-101`; `src/lib/aiur/build_gate.ex:130-145`; `src/lib/aiur/decision_log.ex:209-215` | **Reject blanket extraction.** BuildGate already delegates canonicalization to PathSafety. DecisionLog rejects a symlink at one durable file path; PathSafety resolves symlinks to test containment. These are different security contracts. `platform-misc-17`, `dup-by-body-14` cover related mechanics. |
| Atomic write and staged log merge | `src/lib/aiur/fs.ex:18-47`; `src/lib/aiur/current_run_membership/store/file_ops.ex:20-42`; `src/lib/aiur/workspace/reconstruction.ex:210-231` | **Existing primitive plus rejected merger.** Membership already delegates to `Fs.atomic_write` with `fsync: true` and mode `0o600`. Reconstruction streams previous/current logs into a temporary file before rename; it cannot simply call an in-memory write helper without changing bounds and failure handling. `loose-4-13`, `dup-by-body-04`, `dup-by-body-31` overlap. |
| Coalescing under different state variable names | `src/lib/aiur_web/live/dashboard_live.ex:1344-1361,1514-1529`; `src/lib/aiur/events/github_webhook.ex:407-445`; `src/lib/aiur/build_order/graph_projection.ex:1616-1645` | **Keep distinct contracts.** Dashboard holds latest snapshot for a trailing render; webhook performs a leading wake plus conditional trailing wake with generation; graph projection holds per-root timer tokens and invalidates in-flight reads. `web-rest-11` covers the within-Dashboard repeated pattern. A universal debounce helper would hide materially different edge and cancellation behavior. |
| Ticket topic construction and parse | `src/lib/aiur/agent_runner/session_lifecycle.ex:1018-1023`; `src/lib/aiur/events/github_firehose.ex:420-429`; `src/lib/aiur/orchestrator/event_topics.ex:83-105` | **Existing candidate, no new ID.** A typed grammar could connect producer and parser despite unlike local function names. Model-alert eligibility and GitHub merge admission stay with their source owners. `agent-runtime-22`, `loose-3-38`, `orch-a-14`, `dup-by-concept-02` already cover it. |
| GraphQL/REST pagination | `src/lib/aiur/linear/client.ex:440-459`; `src/lib/aiur/build_order/github_graph/pager.ex:55-104`; `src/lib/aiur/github/pull_requests.ex:482-493`; `src/lib/aiur/github/review_threads.ex:152-169` | **Reject one cross-provider pager from lexical evidence.** Linear GraphQL, GitHub GraphQL and GitHub REST use different cursors/Link headers and truncation contracts. Within-provider pagination is already raised by `platform-misc-24`, `github-a-16`, and `github-b-07`; further extraction needs per-endpoint response checks. |
| Freshness and source-health display | `src/lib/aiur_web/streamdeck_projection.ex:477-499`; `src/lib/aiur_web/live/dashboard_live.ex:1344-1361`; `src/lib/aiur_web/build_order/ticket_context_presenter.ex` | **Existing concept, no new ID.** Source observation age, provider meter health and Build Order source diagnostics have different clocks and causes. Common age conversion can be pure; a single `available?` default would collapse unknown/degraded distinctions. `web-occ-17`, `web-occ-20`, `web-rest-10`, `dup-by-body-12` overlap. |

## Promotion judgment

This probe found source-backed cross-boundary opportunities already represented
by inherited or draft IDs and several attractive but unsafe extractions.
It adds no independent finding. Combined with the inherited-ID closure
ledger, it supports promotion of a **bounded** concept review: the 14 lexical
families above plus their representative source follow-up. It does not
support a claim that all differently named semantic duplication across the
1,032 files has been found. Such an exhaustive claim would require a
function-level semantic review of the remaining matches and concepts that
these terms cannot express.
