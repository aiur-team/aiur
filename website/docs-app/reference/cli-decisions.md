---
pageClass: cli-reference
---
# CLI decisions and Executor events

## Decisions, Executor events, and findings
`aiur ticket estimate <id> [<hours> | --clear] [--reason <text>] [--by <who>] [--json]` shows the default, override and last 20 changes, or sets/clears an override.

Hours must be multiples of 0.25 in 0.25..999; writes require a reason (1..500 characters, no controls). Actor defaults to `cli:$USER` and accepts 1..64 letters, digits or `._:@-`.

JSON includes `default_hours` and `planned` (true, false, or `"unknown"`); overrides for tickets outside the plan are saved for later. Defaults by complexity 1..5 are 1, 2, 4, 7, 11 hours; unknown complexity has no default.

A timeout leaves the outcome unknown (repeat the show form); an unavailable store refuses writes, so restore or remove the quarantined file and restart after corruption.

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur ticket estimate <id> [<hours> or --clear] [--reason <text>] [--by <who>] [--json]` | Show, set or clear durable estimate overrides; writes require a reason. See the validation and recovery details above. | `aiur ticket estimate 2412 7 --reason "Three design rounds"` |
| `aiur ask "Title"` | Creates a durable operator request for the current repository. Add `--body` or `--body-file`, `--urgency low\|normal\|high`, and `--blocking` as needed. | `aiur ask "Approve production cutover" --blocking --urgency high` |
| `aiur ask "Title" --body "Context"` | Stores short supporting Markdown in the ask. | `aiur ask "Approve production cutover" --body "Production freeze ends today."` |
| `aiur ask "Title" --body-file request.md` | Reads the supporting body from a UTF-8 file. | `aiur ask "Approve production cutover" --body-file request.md` |
| `aiur ask "Title" --urgency high` | Classifies the request as `low`, `normal`, or `high`. | `aiur ask "Approve production cutover" --urgency high` |
| `aiur ask --done ASK-ID` | Resolves one open ask; `--note` records the resolution context. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur ask --done ASK-ID --note "Approved"` | Saves the optional resolution context with a completed ask. | `aiur ask --done ask_123 --note "Approved by release manager"` |
| `aiur asks` | Lists open asks by default. Use `--all` to include resolved records and `--json` for the durable rows. | `aiur asks --all --json` |
| `aiur asks --open` | Makes the open-asks default explicit. | `aiur asks --open --json` |
| `aiur commands` | Lists durable Executor decisions. An optional decision ID selects one record. | `aiur commands` |
| `aiur commands --filter open` | Accepts `all`, `open`, `blocking`, or `resolved`. `--ticket` and `--search` require `--filter all`. | `aiur commands --filter open` |
| `aiur commands --blocking` | Limits the decision list to blocking records. | `aiur commands --blocking` |
| `aiur commands --ticket 142` | Narrows an `all` decision query to a ticket. | `aiur commands --filter all --ticket 142` |
| `aiur commands --search timeout` | Searches an `all` decision query. | `aiur commands --filter all --search timeout` |
| `aiur commands --cursor TOKEN` | Continues a paginated decision query. | `aiur commands --cursor TOKEN` |
| `aiur commands --limit 20` | Sets a positive result limit. | `aiur commands --limit 20` |
| `aiur commands --json` | Emits machine-readable decision rows. | `aiur commands --json` |
| `aiur operator-relay-answer DECISION-ID` | Records an operator's already-given answer when `executor.relay_operator_answers: true`. Requires `--expected-version`, exactly one of `--option` or `--custom-response`, `--quote` (verbatim operator words), `--relayed-by` (Executor identity), and `--idempotency-key`. Accepted for `human_required`; recorded as `operator_relayed`, never a direct operator answer. | `aiur operator-relay-answer dec_123 --expected-version 1 --option keep --quote "keep them" --relayed-by attended-executor --idempotency-key palette-1` |
| `aiur operator-relay-answer DECISION-ID --supersede` | Relays the operator's corrected answer before worker delivery, preserving the prior answer in history. Refused while delivery is in flight, after delivery, or when the active answer was recorded directly by the operator. | `aiur operator-relay-answer dec_123 --expected-version 1 --option replace --quote "replace them instead" --relayed-by attended-executor --idempotency-key palette-2 --supersede` |
| `aiur answer DECISION-ID --operator` | Human operators only. Requires an interactive terminal, shows the Command question, version and selected answer, then requires typing the decision ID to confirm. Agents and Executors must never run it. It accepts only `human_required` Commands and records actor `cli:<user>`. | `aiur answer dec_123 --option build_content --operator` |
| `aiur executor-answer DECISION-ID` | Records a supervising-Executor answer to one open decision. It requires `--expected-version`, `--rationale`, `--idempotency-key`, and exactly one of `--option` or `--custom-response`. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --expected-version 1` | Optimistic-concurrency guard. It must be a positive integer and must match the decision's current version, so a stale answer is rejected instead of overwriting a newer one. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --option morning` | Selects one of the decision's offered option IDs. It is mutually exclusive with `--custom-response`. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --custom-response "Hold"` | Supplies a bounded free-text answer instead of an offered option. It is mutually exclusive with `--option`. | `aiur executor-answer dec_123 --expected-version 1 --custom-response "Hold until Monday" --rationale "Freeze" --idempotency-key run-2` |
| `aiur executor-answer DECISION-ID --rationale "Why"` | Required. It records why the answer was chosen, so decision history is auditable. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --idempotency-key run-1` | Required. Replaying the same key does not record a second answer, so a retried command is safe. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1` |
| `aiur executor-answer DECISION-ID --executor-id exec-1` | Optional attribution for the answering Executor. It must not be empty when present. | `aiur executor-answer dec_123 --expected-version 1 --option morning --rationale "Lowest risk" --idempotency-key run-1 --executor-id exec-1` |
| `aiur executor-answer DECISION-ID --supersede` | Replaces the answer of a decided Command that no agent has received yet. The new answer is recorded as a revision, the old answer stays in the audit history, and only the newest answer is delivered. It is refused once a worker picked up any answer for sending, and for a Command that has no answer yet. | `aiur executor-answer dec_123 --expected-version 1 --custom-response "Use the new fixture" --rationale "Operator changed direction" --idempotency-key run-3 --supersede` |
| `aiur executor-escalate DECISION-ID` | Hands a decision back to the human Executor instead of answering it. It requires `--expected-version` and `--reason`. | `aiur executor-escalate dec_123 --expected-version 1 --reason "Needs the release owner"` |
| `aiur executor-reclassify DECISION-ID` | Reclassifies an open historical `human_required` decision with no human-only basis. Refuses decisions with product, spend, publication, security, or legacy-attention provenance. Requires `--expected-version` and `--rationale`; reclassification increments the version. | `aiur executor-reclassify dec_123 --expected-version 1 --rationale "Acceptance specifies the fallback"` |
| `aiur executor-escalate DECISION-ID --reason "Text"` | Required. It records why the supervising Executor declined to answer. | `aiur executor-escalate dec_123 --expected-version 1 --reason "Needs the release owner"` |
| `aiur executor-moot DECISION-ID` | Retires a Command whose question is void — its ticket closed, its originating agent is gone, or the operator changed direction before the answer reached an agent — recording why and by whom, without fabricating an answer. It requires `--expected-version` and `--reason-class`. It also withdraws a decided answer that no worker has picked up for sending; that answer is never delivered. For a decided Command, the Executor may withdraw only an answer that an Executor recorded or could have recorded itself; otherwise use `executor-escalate`. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed` |
| `aiur executor-moot DECISION-ID --reason-class ticket_closed` | Required. A bounded class such as `ticket_closed` or `origin_agent_gone` that explains why the Command was voided. | `aiur executor-moot dec_123 --expected-version 1 --reason-class origin_agent_gone --reason "Agent no longer runs"` |
| `aiur executor-moot DECISION-ID --reason "Text"` | Optional free-text detail explaining why the Command was retired. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed --reason "Folded into #2073"` |
| `aiur executor-moot DECISION-ID --executor-id exec-1` | Optional attribution for the Executor retiring the Command. It must not be empty when present. | `aiur executor-moot dec_123 --expected-version 1 --reason-class ticket_closed --executor-id exec-1` |

A mooted Command leaves `aiur commands --blocking` and the open/blocking counts, and stays visible under `--filter resolved`. A Command mooted while open keeps its answer unset in the audit history. A Command mooted after it was decided keeps its undelivered answer in the audit history, but that answer is never delivered.

A decided answer is addressed to the ticket, not to one worker session. Until an agent receives it, Aiur delivers it to whichever worker runs the ticket, including a new worker after a requeue or a daemon restart.

If the operator changes direction before delivery, run `executor-moot` to withdraw the answer or `executor-answer --supersede` to replace it. While a worker is sending it, the answer is in flight and cannot be changed. If the send fails, it can be changed again.

Executor mutation failures include a remedy on stderr. Supply any named missing flag and retry; when `--expected-version` is stale, read the current version from the error and retry only after confirming the Command has not changed unexpectedly.

If `executor-answer` says a field is outside Executor scope, use `aiur executor-escalate` for genuinely human-owned questions. `executor-reclassify` only handles historical decisions with no recorded human-only basis; use the incremented version when answering.

A stopped daemon is reported separately with the command needed to start it; a live but silent or unreachable daemon reports the attempted decision ID, expected version, and daemon endpoint so the same call can be diagnosed without guessing.

| `aiur listen` | Streams the `executor.#` pattern by default as one JSON line per event. The stream reconnects after a daemon restart and resumes from its durable cursor; use `--ticket` or `--topic` to follow one narrower pattern. After a dropped stream it retries with a backoff from 2 to 60 seconds and stops when one outage lasts about 10 minutes; an attempt that lasted 30 seconds or more counts as connected and starts a new outage. A stream exit other than a lost daemon stops at once. | `aiur listen` |
| `aiur listen --ticket <id>` | Shorthand for `--topic 'ticket.<id>.#'`. Each wake line includes `wake_id`, `topic`, `ticket`, and `pr_number` (null when unavailable). Re-arm this command after resuming from an operator pause. | `aiur listen --ticket 3028` |
| `aiur listen --topic '<pattern>'` | Accepts any `executor.*` pattern, a reviewed Executor binding, a pattern whose every match is inside one reviewed binding (such as `ticket.3028.agent.attention.*`), or `ticket.<id>.#` for a numeric id. `ticket.<id>.#` is always accepted and matches every topic for that ticket, including topics outside the reviewed bindings. Other patterns are refused with the allowed bindings listed. | `aiur listen --topic 'ticket.3028.#'` |
| `aiur executor-listen` | Deprecated alias for `aiur listen`, retained for one release. | `aiur executor-listen --ticket 3028` |
| `aiur executor-wait` | Returns immediately when durable Executor wake records are pending; otherwise blocks for up to 300 seconds. Exit `0` covers both outcomes that lose nothing: wakes were returned and acknowledged, or the wait timed out quietly having consumed nothing. It auto-claims the wake stream when nobody holds it, and the shared cursor advances only for the owner. Before it waits, it also returns a wake for every open blocking decision older than 15 minutes that no wake surfaced in the last 15 minutes, even when no event backs it; plain mode shows `decision=<id> gates=<n> escalation=<created\|rewake\|backstop>`. | `aiur executor-wait` |
| `aiur executor-wait --timeout 60 --json` | Sets the positive timeout in seconds and emits the identifier-only wake batch as JSON, alongside this consumer's `role` and a `status` of `woken`, `timeout` or `error`. Non-Executor wakes contain validated IDs and typed flags, never source free text, except an `operator-decision` wake: its sanitized `question` and `recommendation` are listed in `untrusted_fields`. | `aiur executor-wait --timeout 60 --json` |
| `aiur executor-wait --as agent-b` | Names the consumer explicitly instead of using `AIUR_EXECUTOR_ID` or the derived host identity. Refused by a live owner, it reads the same records as an observer and does not advance the cursor. An owning `executor-wait` also records its harness session (`CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`) on the claim; a subagent (`CLAUDE_CODE_CHILD_SESSION`) and observers never do. `--session-id <uuid> [--harness claude|codex]` records that session explicitly instead and refuses an invalid UUID. | `aiur executor-wait --as agent-b` |
| `aiur executor-wait --session-id <uuid> [--harness NAME]` | Overrides the detected session when this consumer owns the claim. The harness defaults to `claude`; invalid UUIDs are refused. | `aiur executor-wait --session-id 12345678-1234-1234-1234-123456789abc --harness codex` |
| `aiur executor-wait --defer-ack --json` | Returns a batch with `ack: "deferred"` and its `max_wake_id` without moving the cursor. The same batch is returned again until a later call acknowledges through its id. | `aiur executor-wait --defer-ack --json` |
| `aiur executor-wait --ack-through 44 --defer-ack` | Acknowledges as owner through wake 44 before waiting. Ids already at or below the cursor are accepted even if trimmed; an id beyond the journal returns `journal_reset`. | `aiur executor-wait --ack-through 44 --defer-ack` |
| `aiur --instance all executor-wait --as fleet-executor --json` | One remote Executor waits concurrently on every registered instance. It returns the first delivered wakes, tags each record with its instance, and keeps a separate deferred-ack cursor per instance under `~/.aiur/remote-state/`. Remote waits cap at 600 seconds; `--as` is required. | `aiur --instance all executor-wait --timeout 60 --as fleet-executor --json` |
| `aiur --instance nuc executor-wait --as fleet-executor --json` | Waits on one named remote instance using the same per-instance cursor and deferred acknowledgement behavior. | `aiur --instance nuc executor-wait --as fleet-executor --json` |
| `aiur executor-fast-forward <wake-id>` | Explicitly acknowledges an exact durable wake prefix that this Executor demonstrably covered by another complete means. It acquires the owner lease, refuses a live peer owner, rejects an absent or future id, reports before/through/acknowledged/pending counts, and preserves newer wakes. This is recovery, not the normal consumption loop. | `aiur executor-fast-forward 2832 --as agent-a` |
| `aiur executor-roster` | Lists every Executor consumer with the evidence behind its state: role, host, pid, `claimed_at`, `last_renewed_at`, `last_acknowledged_at`, `pending_count`, cursor position, and whether the cursor moved since the previous observation. | `aiur executor-roster --json` |
| `aiur executor-session [--json]` | Prints the live Executor's harness session handle: `harness`, `session_id`, `config_dir`, `cwd`, `harness_pid`, `recorded_at`. Reads `{"state":"unknown","reason":…}` when nobody owns the stream (`no_live_owner`, including an expired lease), the owner recorded no session (`no_session`), or its `harness_pid` is dead (`harness_pid_dead`). | `aiur executor-session --json` |
| `aiur executor-claim` | Claims the wake stream. Refused when a live, renewing owner holds it; the refusal names that owner so a takeover is an operator decision, never a silent steal. | `aiur executor-claim --as agent-a` |
| `aiur executor-release` | Gives up this consumer's claim so a successor can take over immediately. | `aiur executor-release --as agent-a` |
| `aiur executor-revoke <consumer-id>` | Operator-only revoke of the named live owner. Requires the owner's id, read from the roster first. | `aiur executor-revoke agent-a` |
| `aiur executor-emit executor.note --payload '{"text":"ready"}'` | Publishes JSON on a nonempty `executor.` topic. Empty segments and other namespaces are rejected. | `aiur executor-emit executor.note --payload '{"text":"ready"}'` |
| `aiur executor-subscribe 'executor.#'` | Adds a persistent Executor event binding. Bindings accept `executor.*` and reviewed ticket/system patterns only; broader wildcards are rejected. | `aiur executor-subscribe 'executor.#'` |
| `aiur executor-unsubscribe 'executor.#'` | Removes that exact persistent binding. | `aiur executor-unsubscribe 'executor.#'` |
| `aiur executor-subscriptions` | Lists persistent Executor event bindings. | `aiur executor-subscriptions` |
| `aiur findings` | Reads the host-local findings ledger. | `aiur findings` |
| `aiur findings --unfiled` | Filters ledger entries that have no filed ticket. | `aiur findings --unfiled` |
| `aiur findings --slugs` | Emits only finding slugs. | `aiur findings --slugs` |
| `aiur findings --scope repo` | Filters to `aiur` or `repo` scope. | `aiur findings --scope repo` |
| `aiur findings --record JSON --repo owner/repo` | Appends one validated finding to the named repository ledger. Both options are required together. | `aiur findings --record '{"slug":"example"}' --repo aiur-team/aiur` |
| `aiur findings --digest` | Generates the Markdown projection, optionally scoped. | `aiur findings --digest --scope repo` |
### `executor-wait` outcomes
A quiet timeout is a **successful empty result**, not a failure: nothing was pending, so nothing was consumed and nothing was lost. Plain mode prints `NO-WAKES role=<role> timeout_ms=<ms> nothing pending, nothing consumed`; `--json` returns `{"status":"timeout","role":...,"records":[]}`. Both exit `0`.

Under `--json` every outcome carries a `status`: `woken` for a returned batch, `timeout` for a quiet wait, `superseded` when a newer deferred wait replaces this consumer's blocked wait, or `error` for a failure. Deferred batches also include `ack: "deferred"` and `max_wake_id`. Branch on `status` rather than on the presence of `records`.

Every nonzero exit names the stage that failed — `claim`, `wait` or `acknowledge` — on stderr, and as a `status: "error"` envelope with that `stage` under `--json`.

| Exit | Meaning |
| --- | --- |
| `0` | Wakes were delivered (and acknowledged, when this consumer is the owner), or the wait timed out quietly. |
| `69` | Contention on the shared claim: the cross-process claims lock was still held after its bounded retry, or the claim moved to another consumer before the batch could be acknowledged. Nothing was consumed and the cursor did not move, so the same call is safe to retry. |
| `1` | Daemon or store failure — an unreadable wake ledger, or a claims store that cannot be written. Retrying repeats it. |
| `64` | Invalid usage. |

If lease renewal detects that this consumer lost ownership during a wait, the wait continues as an observer and leaves the shared cursor untouched. Ownership loss discovered only when acknowledging still returns `69`.

The `69` diagnostic reports the retry bounds actually spent, read from the live configuration: by default the claims lock is retried every 25ms for 5 seconds, and a lock older than 60 seconds is broken as stale.

A batch that could not be acknowledged is still **printed** — losing a wake is a worse failure than announcing a redelivery — so an acknowledge-stage failure emits the wake envelope first and the `status: "error"` envelope after it.

Read the last line for the outcome: its `unconsumed_wake_ids` name the records whose cursor did not advance, and they will be delivered again to whichever consumer holds the claim next.

### Wake ledger bound and lease TTL

The wake ledger is capped at 10,000 records. Consumed records are evicted first. Past the cap the **oldest unread wakes are evicted too**. The shared cursor is advanced past them and an `executor.wakes.overflow` alert names the count and id range; those wakes are never delivered.

In practice that only happens when a run records for a long time with no consumer, or with a stalled one. The roster's `stalled` state is the earlier warning.

A claim is a lease with a 10-minute TTL. An `--executor` run registers and renews its principal below that TTL; `executor-wait` also renews while it blocks, and every claim or acknowledgement renews. A consumer that stops renewing is reported `expired` after the TTL lapses, and a successor may take over with no operator action.

### Executor roster states

A stalled consumer still holds a claim and still renews its lease, so a presence-based list reports it as fine; `aiur executor-roster` derives state from evidence, never from presence.

| State | Meaning |
| --- | --- |
| `active` | Positive evidence of consumption: it acknowledged inside the stall window, or the shared cursor moved since the previous observation. |
| `idle` | Lease live, nothing pending, cursor legitimately still. |
| `stalled` | Lease renewing, but acknowledgements are frozen while `pending_count` grows. The "backgrounded stuck" case. |
| `expired` | Lease lapsed. A successor may take over with no operator action. |
| `unknown` | The evidence needed to decide is missing. Never reported as `active`. |

Multiple executors are a supported configuration, so a healthy peer is listed plainly and is not a fault. An agent reports what it finds and recommends; it never revokes a live peer's claim on its own.

Records — the journal, wake inbox, cursor, and subscriptions — are created automatically on first use beneath the per-repository state node (`~/.aiur/repo/<owner>/<repo>/executor`), so they survive a daemon restart and a successor resumes from the durable cursor.

Within that node, wake files are prefixed by the sanitized final segment of the tracker project identity (`Paths.repo_name/0`): `<repo>.executor.wakes.ndjson`, `<repo>.executor.wakes.cursor.json`, and `<repo>.executor.wakes.pending.json`.

A notification monitor must use that `<repo>` prefix (for example, `khala.executor.wakes.ndjson`), check that the wake file exists before declaring itself armed, and never substitute the `aiur` prefix in a consumer repository.

A `tail -F -n0` follower is a notification aid only: it has no consumer identity or lease and never advances the durable cursor. Each trim renames a new file into place and `tail -F` re-emits it from the top, so print only a `wake_id` above the last one seen, seeded from the file's last `wake_id` at arm time. The `aiur-run` monitor command does this.

`executor-wait` is the normal discovery and consumption path. Use `executor-fast-forward` only after independently verifying the exact prefix already covered. The 10,000-record bound remains an emergency disk bound, not evidence of consumption. Exceeding it trims the journal to the newest 8,000 records, consumed first: one rewrite per 2,000 wakes.

`AIUR_EXECUTOR_ID` names this consumer when `--as` is omitted. Nothing infers consumer identity from the terminal, parent process, or any other environment signal.

Executor subscriptions are the Executor's half of the event system; see [Message Bus](/concepts/message-bus). Agents do not need these commands: every agent is auto-subscribed to its own comment, review, and CI topics, and to both directions of every blocker edge.

Normal control commands use a bounded RPC. After ten seconds the launcher terminates its helper and descendants, exits 124, and reports the timeout. A crash marker distinguishes a known crashed daemon from a stopped one; run `aiur stop` to reap possible orphaned agents before restarting.

A daemon that dies after becoming ready restarts with backoff, raising one `system.daemon.down` alert per outage, then `system.daemon.restarted`. It keeps the first and latest timestamped crash dumps. After over five crashes in ten minutes (`AIUR_DAEMON_MAX_RESTARTS`) it raises `system.daemon.gave-up` and stays down. `aiur stop` stops it for good.

An open **blocking** ask is also printed by plain `aiur status`; no extra flag is required. That keeps a durable request in the normal operating view instead of hiding it in a ledger that nobody reads. `--blocking` and `--filter blocking` mean *dispatch is held until you answer this*, which is also what the dispatch gate reads.

An agent attention is a visibility signal rather than a gate — the agent keeps running after it opens one — so attentions are listed by `aiur commands` but are not counted as blocking.

Answering a Command dismisses duplicate unanswered Commands on the same ticket, including deferred ones. A blocking Command is not swept up, since the waiting agent needs its answer. Dismissing a Command closes it; a live agent is told to use its judgement, while a gone agent gets no notice.
