## Command decision loop

Handle each Command when the daemon listener delivers it (via the
needs-attention alert) or when you read it with `aiur commands <decision-id>`.
The listener remains the primary command path. As a backstop, sweep decisions
every `executor-wait` cycle; use [`open-decisions-sweep.sh`](open-decisions-sweep.sh)
to list open decisions and report new ones or blockers at least 15 minutes old.

Use contextual judgment for every Command, never a rules table or a hardcoded
allowlist of command types. Answer directly only when the requested choice is
already established by recorded facts or an earlier answer, or is an obvious,
reversible operational action within the authority envelope. Repeated forms of
the same settled question should reuse the settled answer instead of waking the
operator again. Make every direct answer through `"$AIUR_CMD" executor-answer`;
that command records an Executor actor, which must remain distinguishable from
an operator actor in the durable decision record and dashboard. The operator
can find these decisions in dashboard history and revise or supersede them
later. Never answer through an operator-attributed API or imply Executor
attribution only in free-form rationale. Never run `aiur answer`; it is human-only and requires an interactive terminal.

```bash
"$AIUR_CMD" executor-answer <decision-id> --expected-version <n> \
  --option <id> --rationale <text> \
  --idempotency-key <key> [--executor-id <id>]
```

Use `--custom-response <text>` instead of `--option <id>` when the established
answer is not one of the offered options; exactly one is required.
Use a stable Executor identity for the run when supplying `--executor-id`; it
defaults to `aiur-cli`. The expected version prevents a stale listener event
from overwriting a later answer, while the idempotency key makes event replay
safe.

When the operator has already answered a human-only Command in this attended
conversation, record their answer through the opt-in relay path:

```bash
"$AIUR_CMD" operator-relay-answer <decision-id> --expected-version <n> \
  --option <id> --quote <verbatim-operator-words> --relayed-by <executor-id> \
  --idempotency-key <key>
```

Use `--custom-response` instead of `--option` for free text. The operator must
enable `executor.relay_operator_answers`; do not enable it on their behalf.
This records `operator_relayed` attribution and raises an info alert. It
records a human's decision, never permission for the Executor to decide.
Use `--supersede` to relay a corrected answer before delivery; the operator can
also revise or moot it through the dashboard. If the gate is disabled, report
"human answered; relay recording disabled" and direct the operator to the
Command dashboard. A comment or worker message does not close the Command.

An answer is addressed to the ticket, not to the worker that asked. Until an
agent receives it, Aiur delivers it to any worker that runs the ticket, also a
new worker after a requeue or a daemon restart. If the operator changes
direction before the answer is delivered, do not carry the new direction only
in an issue comment. Withdraw or replace the answer:

```bash
"$AIUR_CMD" executor-moot <decision-id> --expected-version <n> \
  --reason-class operator_changed_direction --reason <text>
"$AIUR_CMD" executor-answer <decision-id> --expected-version <n> \
  --custom-response <text> --rationale <text> --idempotency-key <key> --supersede
```

A mooted answer is never delivered, and only the newest answer is delivered
after `--supersede`. While a worker is sending the answer, both commands are
refused ("answer in flight"); after a failed send they work again. You may moot only an answer that an
Executor recorded or could have recorded; otherwise escalate.

When the choice is uncertain, irreversible, scope-changing, or depends on an
Executor guess rather than a known fact, leave the Command unanswered and run
`"$AIUR_CMD" executor-escalate`. That explicit escalation uses the existing
operator-notification path; record the concrete uncertainty and the decision
the operator must make. Direct Executor answers do not notify. Escalated
Commands do notify and remain open until the operator answers them.

The store enforces this floor independently of your judgement: it accepts an
Executor answer only for a Command declaring a delegable authority
(`supervisor_allowed` or `supervisor_preferred`) and `reversibility:
reversible`. Everything else is refused and must be escalated.

```bash
"$AIUR_CMD" executor-escalate <decision-id> --expected-version <n> \
  --reason <text> [--executor-id <id>]
```

The timer and alert path are additive: an urgent alert is handled immediately,
while the cadence still provides a quiet-state floor. Do not depend on PR or
agent-completion events as the only wake-up mechanism.

Every run arms the daemon-resident Executor listener (`Aiur.ExecutorListener`)
as part of launch; there is no separate subscription step to forget. An
`--executor` launch additionally registers and renews its roster principal,
without acknowledging wakes or advancing the shared cursor. The run supervises
and restarts the listener, it subscribes to
`executor.decision.requested` / `executor.decision.deferred`, and it replays
from its own durable watermark so a restart re-delivers only what was missed.
Each Command surfaces as a needs-attention alert in `aiur watch` / `aiur
alerts --needs-attention`; read the Command's payload with `aiur commands
<decision-id>`. This listener is the command inbox: do not discover new
Commands by polling or sweeping the decision store. Periodic monitoring remains
necessary for runtime health, but it is not a parallel decision-discovery
mechanism. The listener runs on every run, so `LISTENER absent` is always a fault, not a
mode. Verify it is live with `aiur status` (`LISTENER present (executor.#)`) and report the subscription to the human at launch ("Listening
for Executor events on `executor.#`."), and again if it is later confirmed dead
or restarted.

Evaluate each Command in its current run, ticket, and decision-history context.
This is a judgment call, not a rules engine: do not encode a table of command
types that may be answered automatically. A direct answer is appropriate when
it repeats a settled answer, follows from an established fact, or chooses an
obvious reversible operation already inside the authority envelope. Submit it
only through the `executor-answer` command so the durable answer actor is the
Executor, not the operator. The dashboard must expose that attribution and
history so the operator can find, revise, or supersede every Executor-made
decision later; explanatory prose is not a substitute for actor attribution.
Pass the event's current decision version, exactly one option or custom answer,
a rationale, and an idempotency key. Use a stable `--executor-id` for the run
when available (the CLI otherwise records `aiur-cli`), so replay stays
idempotent and stale events cannot overwrite a later answer.

If the human has already answered in the attended conversation, use
`operator-relay-answer` with the current version, one choice, a verbatim
`--quote`, stable `--relayed-by` identity and an idempotency key. The operator
must first enable `executor.relay_operator_answers`. The distinct
`operator_relayed` actor and info alert preserve who decided and who recorded.
Never enable this policy yourself or substitute an operator-attributed API.
If disabled, report that relay recording is disabled and direct the operator
to the dashboard. Use its revision/moot flow to correct a relay, or relay a
corrected answer with `--supersede` before delivery.

A decided answer that no agent has received yet can still be changed. It is
addressed to the ticket, so a later worker of the same ticket receives it.
Withdraw it with `executor-moot`, or replace it with `executor-answer
--supersede`; the store never delivers a mooted or replaced answer. While a
worker is sending the answer it is in flight and cannot be changed; after a
failed send it can. Moot only an answer that an Executor recorded or could have recorded;
otherwise escalate.

If the Command is uncertain, irreversible, changes feature scope or product
direction, exceeds the authority envelope, or requires the Executor to guess,
do not answer it. Use the `executor-escalate` command to invoke the existing
operator-notification path with the concrete question and uncertainty, and
leave the decision open for the operator. Auto-answered Commands do not notify;
explicitly escalated Commands do. Escalation also carries the current decision
version and Executor identity, so stale escalation attempts are rejected and
the operator-facing alert remains attributable.

This judgement sits on top of a floor the store enforces, not in place of it.
`DecisionStore` refuses an Executor-attributed answer unless the Command itself
declares `authority: supervisor_allowed | supervisor_preferred` **and**
`reversibility: reversible`; anything else — `human_required`, irreversible or
partially reversible work — is rejected with
`{:executor_scope, …}` and must be escalated. (A request that omits those
fields is normalized to `supervisor_allowed` + `reversible`, so an omitted
declaration lands inside the floor rather than being refused; a genuinely
irreversible or operator-scoped Command carries its `human_required` /
non-reversible declaration explicitly.) Treat that rejection as the
Command telling you it was always the operator's. Escalations are appended to
the Decision's durable event log as an attributed `executor_escalated` event,
so "the Executor deferred to the human" is as recoverable later as "the
Executor decided".
