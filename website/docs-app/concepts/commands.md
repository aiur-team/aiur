# Commands

A Command is a durable question raised by a worker or an Executor. Routing
decides who is asked first; authority decides who may answer.

## What the Commands page shows

The Commands page is dashboard `/decisions` and CLI `aiur commands`.

A Command's **Open in conversation** link carries its agent's recorded request
position, including after the Command is answered. An observed position is marked
**approximate**; when no position is known, the detail shows **Conversation position unknown**.

<img src="/images/dashboard/commands-dark.png" alt="Desktop Commands decision inbox populated with synthetic decisions">

| Field | Meaning |
| --- | --- |
| Ticket and source | Work and agent that raised the Command. |
| Urgency and authority | How quickly it matters and who may answer. |
| Options and recommendation | Bounded outcomes with the agent's preferred choice. |
| Lifecycle | Open, answered, delivered, acknowledged, resolved, or superseded. |

## Executor responses

| Response | Result |
| --- | --- |
| Answer directly | Pick an option or write a bounded response and send it to the agent. |
| Defer | Leave the Command for a designated Executor agent to investigate and decide. |
| Send correction | Append a corrected action without rewriting the original record. |

On writable Command cards and detail pages, open the microphone menu and choose
**Dictate** to speak a custom response. This selects **Custom response** and
appends to any text already there. Review and edit the text, then use the existing
answer button to record it; dictation never submits an answer.

Capture stops at the 4,000-character limit and keeps the full transcript for editing. If voice is
unavailable, you can still type. Structured multi-question forms use their own
answer fields and do not offer this custom-response microphone.

On an answered Command, **Send correction** offers the same dictation flow for
the revised response. Dictation selects **Custom response** and appends to your draft.
Review the text, type a reason for revision, then press **Send correction**.
A rejected correction keeps your draft and shows the existing revision error.

## Authority and attention signals

A structured agent question with `blocking: false` remains visible for an answer
while the worker keeps working; it must not trigger a self-pause. Bare coordination
pauses and explicit operator-decision pauses (including legacy attentions) remain
valid.

Open blocking Commands count toward `waiting_for_human`. Expired unanswered
blockers remain visible and answerable, but stop gating dispatch. A matching
re-raise moots the stale record before opening its replacement. The Executor
can also moot or dismiss a blocker whose ticket is closed or question is moot.

Agents classify the action, not the subsystem around it. Routine,
reversible operational choices should use `supervisor_allowed`.

Irreversible actions, spend, external publication, and product direction
remain `human_required`. By default, the Executor can answer only a Command
that declares `supervisor_allowed` or `supervisor_preferred` together with
`reversible`.

Operators may opt in to delegation for reversible legacy
engineering Commands with `executor.allow_reversible_human_required_answers`;
product, spend, publication, and security decisions remain human-only.

Classification is consequence-based and defaults delegable: a Command that
omits `authority`/`reversibility` is treated as `supervisor_allowed` +
`reversible`, so reversible engineering calls reach the Executor instead of
parking an agent until an operator appears.

Known Command types carry an explicit policy
(`src/lib/aiur/decision_command_type.ex`): a **re-review request**
(`kind: "rework_review"`) classifies `supervisor_preferred` + `reversible`, a
**PR/ticket sequencing** question (`kind: "sequencing"`) classifies
`supervisor_allowed` + `reversible`, and pre-OCC `legacy_attention` projections
stay `human_required`.

Because omission defaults to the Executor floor, a Command that is genuinely
irreversible, involves spend or external publication, or changes product
direction must declare `authority: human_required` (and the matching
`reversibility`) and set `context.authority_basis` to `product`, `spend`,
`external_publication`, or `security`.

Explain the specific boundary in the request context; missing or unrecognized
bases are rejected. Legacy attention projections remain human-required without
this worker field.

An Executor can reclassify an open historical `human_required` Command only
when it has no recorded human-only basis. Product, spend, publication, security,
and legacy-attention Commands remain human-only.

Reclassification records the Executor's rationale and increments the Command
version. A separate `aiur executor-answer` must use the new version.

Aiur warns when reversible human-required Commands offer only low-risk options
and when an Executor-unanswerable nonblocking Command expires. Expired blockers
remain answerable until answered or mooted. A matching agent re-raise replaces
an expired Command with a new open Command; the old record is mooted so it no
longer inflates the open or awaiting counts.

A blocking Command never waits in silence. When it is created, the Executor gets
one `ticket.<N>.agent.attention.operator-decision` wake with the decision id,
the question, the recommended option and the number of open tickets it gates.

While it stays open, Aiur wakes the Executor again at 15 and 30 minutes and
alerts the operator at 45 minutes, then every hour. A Command that gates 10 or
more open tickets alerts the operator at 15 minutes. Answering the Command
resolves the alert and stops the ladder.

The ladder is computed from the
Command's age, so a restart continues it. `aiur status` prints
`DECISIONS open N (E expired) ids=[…] oldest <age> (#ticket, gates M)`;
the sorted IDs identify the exact Commands included in the count.

That line counts the same Commands as `aiur command --filter open`, including
unanswered expired blocking Commands. It is marked `ATTENTION` when the oldest
is older than 15 minutes.

Deferred Commands remain visible in the Open and Blocking dashboard counts until they are answered or retired. Their cards show both the deferred lifecycle and the age of the outstanding Command.

<span id="routing-and-escalation"></span>

## Who is asked

With `decisions.escalation.enabled` (default `true`), Commands use the live
Executor roster to choose the first responder (a live Executor is active or idle).

| Command and roster | First responder | Dashboard chip |
| --- | --- | --- |
| Worker question the live Executor may answer | Executor | With Executor |
| Human-required worker question, live Executor | You and the Executor; only you may answer | Needs you and Executor |
| Worker question, Executor offline or stalled | You | Needs you |
| Worker question outside the live Executor's answer authority | You | Needs you |
| Executor's own question | You | From Executor |

**Needs you** filters outstanding Commands routed to you, including those shared
with the Executor. Cards retain the time they first needed you. **With Executor**
and **From Executor** distinguish delegated questions from the Executor's own asks.

## When a Command becomes yours

An Executor-only Command moves to you when the Executor explicitly escalates it,
goes offline, stalls, or misses a deadline.

| Recorded cause | Meaning |
| --- | --- |
| `executor_originated` | The Executor asked you. |
| `authority_human_required` | Only a human may answer. |
| `executor_not_answerable` | The Executor's authority does not cover this question. |
| `executor_offline` | No live or stalled Executor remains in the roster. |
| `executor_stalled` | The roster has no active or idle Executor, or its lookup failed. |
| `executor_escalated` | The Executor handed the question to you. |
| `executor_ack_timeout` | The Executor did not acknowledge in time. |
| `executor_answer_timeout` | The Executor did not answer in time. |

By default, acknowledgement is due five minutes after routing and an answer is
due fifteen minutes after routing. Acknowledging stops only the first deadline;
it does not restart the answer clock. High- or critical-urgency blocking Commands
halve both deadlines (2½ and 7½ minutes).

Offline or stalled Executors trigger
escalation at the next sweep, within 30 seconds.

Configure `decisions.escalation.executor_ack_ms`,
`decisions.escalation.executor_answer_ms` and `decisions.escalation.urgent_factor`
in the [decisions configuration](/reference/configuration-daemon#decisions).
Disabling `decisions.escalation.enabled` stops routing writes.

Deadlines and first human visibility survive restarts. Routing never re-asks:
it emits one `human_needed` event per Command, including after a defer. See
[Message Bus decisions](/concepts/message-bus#commands-and-decisions).

Answers and terminal lifecycle states stop the routing deadlines. Expiry wins:
an expired Command does not trigger another routing escalation, even though an
unanswered expired blocker remains answerable as described above.

**Defer to Executor** accepts worker Commands whose authority permits an Executor
answer. Human-required and Executor-originated Commands cannot defer. An accepted
defer starts routing deadlines again and preserves first human visibility,
without another `human_needed` notification.

## Durability

| Contract | Why it matters |
| --- | --- |
| ID and version | Scope every answer and revision. |
| Action ID | Correlates delivery, acknowledgement, and resolution. |
| Append-only revision | Preserves what the Executor previously decided. |
| Shared projection | Dashboard and CLI read the same durable record. |

See [Message Bus decisions](/concepts/message-bus#commands-and-decisions) for the event path.

The Decision journal remains authoritative if `decisions.json` cannot be rewritten.
Accepted events remain readable and new journal writes continue.

`aiur status`
and retained Command reads report the stale projection with its timestamp and age
(or “age unknown” when the timestamp is unavailable). Projection repair retries
once per second, with one alert on entering stale health.

Request, enrichment and lifecycle notifications wait for a successful projection
write, then replay in journal order. The projection retains `last_event_id` and
`pending_notification_ids` so restart recovers withheld sends. Successful replay
clears those IDs.

A crash during sending can repeat an event ID; consumers must
deduplicate it. Existing projections without these fields are upgraded without
replaying historical notifications. Journal corruption still makes writes read-only.

## Operator answers relayed in conversation

When you answer a Command in conversation with an attended Executor, it can record that answer with [operator-relay-answer](/reference/cli) if you enabled `executor.relay_operator_answers`. This accepts human-only Commands without granting the Executor decision authority.

Command detail, history and `aiur commands <decision-id>` distinguish it as **answered by operator, relayed by `<executor-id>`** and retain your verbatim quote and the recording timestamp.

Enabling the relay gate raises an info alert. Every relay also raises an info alert naming the Command, quote and relayer. Use the dashboard's existing revision or moot actions to correct or withdraw an answer; withdrawal delivery guards still apply.

<span id="who-can-replace-an-answer"></span>

## Answering and replacing

The first accepted answer wins. If another responder answers first, the conflict
shows the accepted answer and its delivery state instead of overwriting it.

Use **Replace** before delivery, or **Send correction** after delivery. Both
record an override of the original Command.

Before delivery the new answer
replaces the pending answer; after delivery it sends corrective direction to the
active worker on unmerged work. If the PR has merged, it creates a corrective
ticket for a new worker and PR. It cannot retract earlier effects.

Both revise and supersede use the current active answer's precedence:
**direct operator > operator relayed by an Executor > Executor or supervisor**.
A caller can override an answer of equal or lower precedence, including after
delivery or acknowledgement.

A relayed answer never replaces a direct operator answer; an Executor
or supervisor cannot replace either human-attributed kind.

An override retains its original Command, prior/new action IDs, ticket, and the
PR number and merged state observed when routed. Unknown PR state stays explicit.
`aiur commands --json` includes an `overrides` array with route, state and timestamps.


A newer override supersedes the previous one; stale queued messages cannot deliver.
Records survive daemon restart.

Active-worker overrides progress from `queued` to `delivered` after confirmed
delivery, then `implemented` when the worker acknowledges the override or a later
branch push is confirmed as a changed head on the same PR. The record names the
evidence.

Push evidence needs a verified PR head-update timestamp later than
delivery; unknown or same-second chronology stays unproven until acknowledgement
or a later proven push. Queue acceptance alone does not mean implementation.

When the PR has merged, the override creates one corrective ticket, with the
question, old and new answers, original PR and merge SHA. Its `corrective_ticket`
link survives restart, and comments link the original ticket and merged PR to it.
Retries reconcile the override marker before creating a ticket.

Linking a corrective ticket closes any follow-up about the old target.
Delayed results from that target cannot cancel the corrective work.

If the local PR observation is missing or stale, reconciliation checks a closed
ticket's merged PR through GitHub before filing the correction. This runs outside
worker dispatch.

Reconciliation errors appear in `aiur commands --json` as a `failure` record,
including the redacted reason, attempt count and next retry time. Before
delivery, the override state becomes `failed`; confirmed delivery remains
visible. Retries back off from one minute to one hour. Permanent failures
alert immediately; other failures alert after three attempts.

The corrective
ticket enters normal dispatch and capacity limits; merged history is preserved.
A later override targets this corrective ticket while its PR remains unmerged.
It keeps the observed active-worker, resume or capacity-wait route.
For corrective work, `implemented` requires the corrective PR to merge.

For a confirmed unmerged ticket, `resume_pending` and `capacity_wait` overrides form a
journal-backed resume queue. Resumable workers continue on the same ticket,
branch and PR, oldest request first, within the fleet and pressure limits.

Capacity waits remain visible with `resume_reason: capacity` and survive restart.
A newer override supersedes the earlier pending actions; only its text is used.

Each resumed or continuation turn starts with “Operator override — this replaces
your earlier instruction for Command …” until acknowledgement. A confirmed
provider turn start marks prompt delivery; starting a worker alone does not.

Explicit parked or paused labels stay in place, and a worker paused with
`aiur pause N` stays paused, including while its pause request is pending.
Aiur raises an Executor Command,
“Resume #N to apply the override?”; the operator uses the normal resume control
to authorize resumption. Capacity-only waits need no approval.

Unknown PR observations never authorize automatic resumption. Closed targets
are checked for a merged PR asynchronously, as described above. The resume
scheduler requires a freshly confirmed live ticket.

After three failed non-capacity resumes, or evidence of a missing workspace or
unrecoverable worker, Aiur starts a fresh session on the same ticket and PR head.
Its first instruction is the override plus “The previous session ended; continue
PR #N from its head.” Capacity refusals never count toward replacement.

If the branch is deleted or the PR closed unmerged, Aiur creates one parked
successor with the original Command and answer history, closes the old PR with
“superseded by #M”, parks the old ticket with its reason, then releases the
successor for normal dispatch.

Failure keeps the override queued and opens an
Executor Command. The override records its recovery path and reason.
Overrides never rewrite merged work. Direct legacy supersede calls retain their pre-delivery
guard.

Answer attribution records `actor_source`, the entry point that accepted it,
such as `executor_cli` or `supervisor_api`.

An already-answered supervisor API
conflict includes a `winner` summary with the actor, source, accepted time,
answer summary, delivery state and whether that caller can replace it.

Older records and calls without a recorded surface use `rpc`, meaning
“no surface recorded.” Attribution is separate from authentication:
`human_required` does not stop a same-user process with the distribution cookie.

Native requests can contain several questions. The dashboard records all answers
in a single submission; a partial answer leaves the Command open. Multi-select
questions retain a list of choices, and Other is available when the requester
allows it.

Command details show recorded escalation causes and timestamps;
missing audit history is explicitly unavailable rather than an empty timeline.

<span id="held-native-questions"></span>

## Native questions

Codex native capture is on by default; set `decisions.native_capture.codex` to
`false` to opt out. It turns the worker's native question into a Command
using the same routing and authority rules.

Claude capture is on by default; set `decisions.native_capture.claude` to `false`
to opt out. It requires aiur-claude 1.3.0 or newer. Questions are deferred
until answered. Questions the sibling cannot defer are recorded and released
immediately; their answers arrive as messages.
See the [configuration reference](/reference/configuration-daemon#decisions).

Capture never collects secrets through Commands. Secret questions are released
with an explanation and an alert. Approval requests keep their existing approval
policy; enabling native capture does not grant approval authority.

With Codex native capture enabled, Aiur holds the native question while its
Command awaits an answer. Answering the Command returns every question's
structured answer to that same request. The queue records provider delivery
through the normal Command delivery path.

An idle timeout, pause, explicit operator interrupt, or turn ending releases
the hold. Aiur tells the agent the Command ID and that the answer will arrive
as a readable queued message. Ordinary queue notifications wait while a
native question is held.

If the session has exited, Aiur records the release without writing to the
closed session.

With Claude capture enabled, a replacement thread attempts to
release open deferred Commands from the previous thread before starting work.
Cleanup failures are logged without preventing the worker from starting.
Answered Commands are unchanged. Releasing a hold leaves the Command open and
answerable.

## The Executor asks you

The Executor can create its own Command with
`aiur command request 'Ship today?' --option yes=Ship --option no=Wait`.
It appears as **From Executor** and goes directly to you.

Its answer wakes the
Executor through `aiur executor-wait --json`, never a worker, even when the
request includes ticket context. See [Asking the human](/concepts/executor#asking-the-human)
and the [CLI request reference](/reference/cli-operations).
