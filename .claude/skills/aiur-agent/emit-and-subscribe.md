# Aiur Events — Emit and subscribe

## `emit_event(name, message, payload?)`

```jsonc
{
  "name": "progress.tests-green",
  "message": "All 47 tests green on aiur/42",
  "payload": { "ticket": 42, "test_count": 47 }   // optional
}
```

Validates that `name` is in the allowlist (`event-taxonomy.md`). Returns:

```jsonc
{
  "ok": true,
  "name": "progress.tests-green",
  "message": "All 47 tests green on aiur/42",
  "result": {
    "status": "pending",
    "topic": "ticket.42.agent.progress.tests-green"
  }
}
```

`pending` means Aiur accepted the event for keyed background processing. No
event ID exists at admission time; publication assigns it later. A terminal
background failure is written to the daemon run log and does not rewrite
the already-returned tool response.

Legacy `attention.<slug>` events use the same pending admission. If the
attention needs a durable Decision contract, immediately follow it with
`decision.requested` carrying that `attention_slug`; Aiur serializes the
structured request behind the projection and returns its terminal
`decision_id`, `version`, and status.

### Requesting an operator decision

When work genuinely needs operator direction, emit `decision.requested` with
enough structure for the Commands dashboard to present the decision without
reconstructing context from the transcript:

**Assume the operator has zero context.** They may be answering several
Commands in a row and should not have to open the linked ticket, transcript,
file, test, or PR. A Command fails its purpose if the operator must reconstruct
the problem before choosing.

- The first line the operator reads is the `question`: ask for the decision,
  not a history lesson. Put only choice-relevant background after it.
- In every option's `description`, state what each option causes in the
  operator's system. Name the user-visible or operational effect, the risk or
  cost it accepts, and work it leaves for later; an implementation action alone
  is not a consequence. Use `benefits` and `drawbacks` for supporting detail.
- Name every referent on first use. A path, test, symbol, issue, or PR needs one
  short clause saying what it does and why it matters to this choice.
- Use `consequence_of_delay` to state the default explicitly. Start with
  **“No answer:”** and say whether the agent waits, the ticket stalls, a timeout
  chooses an option, or work continues with a named fallback. Never make the
  operator infer urgency from `blocking` alone.
- Keep the question, relevant context, options, recommendation, and no-answer
  behavior readable in under a minute. Remove chronology and investigation
  detail that do not change the choice.

Before emitting, perform a cold-read check: could someone answer from these
fields alone, without knowing the ticket title? If not, rewrite it.

If the question has two to five bounded alternatives, you **must** encode them
as `options` before emitting an `attention.*` or `pause.request` event. If you
can phrase the question as “A or B?”, A and B belong in `options` so the
Executor can answer with one click. An attention or operator-decision pause
does not replace `decision.requested`; never leave the alternatives only in an
attention message, pause question, workpad, or recommendation payload. Use a
free-text-only Decision only when predefined choices would genuinely be
misleading.

```jsonc
{
  "question": "Which outcome should the system use?",
  "blocking": true,
  "context": {
    "short_summary": "One sentence naming the system and why this choice exists.",
    "long_context_markdown": "Only the observed facts and constraints that change the choice; define every file, test, PR, issue, or symbol mentioned."
  },
  "options": [
    {
      "id": "a",
      "label": "Outcome-oriented label",
      "description": "What changes for the operator or system if this is chosen.",
      "benefits": "What becomes safer, faster, simpler, or complete.",
      "drawbacks": "What becomes riskier, slower, more complex, or deferred.",
      "risk": "low"
    },
    {
      "id": "b",
      "label": "Alternative outcome",
      "description": "The different system consequence this choice produces.",
      "benefits": "What this preserves or improves.",
      "drawbacks": "What this costs now or leaves for later.",
      "risk": "low"
    }
  ],
  "recommendation": {
    "option_id": "a",
    "reason": "Why this is the recommended option."
  },
  "authority": "human_required",
  "urgency": "normal",
  "reversibility": "reversible",
  "kind": "product",
  "consequence_of_delay": "No answer: state exactly what waits, stalls, times out, or proceeds by default."
}
```

Populate the summary, long context, options, and recommendation whenever they
apply; do not emit only a question and force the operator to infer the rest.
`context.long_context_markdown` must give the Executor enough evidence to make
the choice without opening the agent transcript: what triggered the decision,
relevant constraints and observed facts, tradeoffs, and what each outcome
changes. Avoid repeating the question or filling this field with generic prose.

#### Before and after: a real Command from sandbox issue #101

The repository's three-ticket event-flow sandbox asked its final agent how to
square an upstream result. The original payload is a useful example of an
internally clear Command that makes a cold operator reconstruct the ticket:

> **Before**
>
> Square the result with `x * x` or `Integer.pow(x, 2)`?
>
> `function_c/0` squares `function_b/0`'s value. Either is correct.
>
> - `x * x` — Direct multiplication.
> - `Integer.pow(x, 2)` — Standard-library power.
>
> Recommendation: `x * x`, because it is cheapest and clearest.

It never says what the functions are for, what either option changes for Aiur,
or what silence does. The same decision, rewritten for zero context, is:

```jsonc
{
  "question": "Should Aiur's event-flow demo square 43 with direct multiplication or the integer-power helper?",
  "blocking": true,
  "context": {
    "short_summary": "Choose the code style for the final step of Aiur's three-ticket event-delivery demo; both options return 1849.",
    "long_context_markdown": "Sandbox issue #101 defines `function_c/0`, the demo's final function. It receives 43 from `function_b/0`, the preceding ticket's function, and squares it. This choice affects readability and ease of later generalization, not output or meaningful runtime performance."
  },
  "options": [
    {
      "id": "multiply",
      "label": "Keep the square obvious",
      "description": "Use `x * x`; the demo stays immediately readable, but supporting powers other than two later would require changing the expression.",
      "benefits": "Smallest and clearest implementation for the only behavior the demo needs.",
      "drawbacks": "Does not generalize to other exponents without another edit.",
      "risk": "low"
    },
    {
      "id": "power",
      "label": "Make later powers easier",
      "description": "Use `Integer.pow(x, 2)`; changing the demo to another integer exponent later becomes a one-argument edit, but today's single square is less direct to read.",
      "benefits": "Generalizes to other integer powers with a smaller future edit.",
      "drawbacks": "Adds abstraction with no current behavior or performance benefit.",
      "risk": "low"
    }
  ],
  "recommendation": {
    "option_id": "multiply",
    "reason": "The demo only needs a square, so direct multiplication communicates its behavior fastest."
  },
  "authority": "human_required",
  "urgency": "normal",
  "reversibility": "reversible",
  "kind": "product",
  "consequence_of_delay": "No answer: issue #101's agent remains paused and the three-ticket event-flow demo cannot finish; no timeout chooses automatically. If the Command is dismissed, the agent uses direct multiplication."
}
```

This version is answerable cold: the decision is first, both option descriptions
state their system consequence, every symbol is defined, and silence has an
explicit outcome.

If the Executor message says the decision was dismissed and instructs you to
use your best judgement, proceed autonomously with the best supported option.
After completing that work, emit `decision.resolved` for the dismissed request
using the correlation supplied by Aiur when available; do not keep waiting for
another answer.

Or, on failure:

```jsonc
{ "error": { "message": "`emit_event.name` must match the agent vocabulary: ...", "examples": [...] } }
```

### Acknowledging a delivered Decision answer

A durable answer message includes a Decision ID, the request version it
answered, and an action ID. Treat the message as replayable and do not apply it
twice. Once observed, acknowledge that exact action:

```jsonc
{
  "name": "decision.acknowledged",
  "message": "Applying the selected option",
  "payload": {
    "decision_id": "dec_abc123",
    "action_id": "act_def456",
    "expected_version": 2
  }
}
```

After the governed work is complete, emit `decision.resolved` with the same
three fields. These two exact names go through the durable DecisionStore, not
the generic event publisher. An exact retry returns `duplicate`; a wrong
ticket, action, or version is rejected. Queue delivery or turn completion does
not acknowledge a Decision for you.

## `aiur_subscribe(topic_pattern)`

Persistent — the subscription survives BEAM restarts. Use AMQP topic-exchange wildcards:

- `*` — exactly one segment
- `#` — zero or more segments

Examples:

```jsonc
{ "topic_pattern": "ticket.42.#" }              // everything about ticket 42
{ "topic_pattern": "*.*.branch.push" }          // any push on any ticket
{ "topic_pattern": "ticket.42.agent.decision.*" } // every decision from ticket 42
```

Returns `{ "ok": true, "topic_pattern": "ticket.42.#" }`.

## `aiur_unsubscribe(topic_pattern)`

Exact-match removal. No-op if the pattern wasn't subscribed.

## Default subscriptions (you don't subscribe to these explicitly)

When you start working on a ticket, Aiur automatically subscribes you to:

- `system.<base-branch>.branch.push` — pushes to the repo's base branch
- `ticket.<self>.issue.commented` — comments on your own issue
- `ticket.<self>.pr.review_comment` — review comments and review threads on your own PR
- `ticket.<self>.ci.passed` / `ticket.<self>.ci.failed` — terminal CI outcome
- `ticket.<self>.operator.progress_request` — the periodic check-in ping
- (After `aiur_declare_blocker(N)`:) a useful subset of `ticket.N.*` events — the blocker's progress, decisions, branch pushes, and unblock signals

That set is deliberately narrow rather than a blanket `ticket.<self>.#`: you are
not auto-subscribed to your own `branch.push`, `pr.opened`, or `pr.merged` —
those are consumed by the orchestrator. Anything outside the table needs an
explicit `aiur_subscribe`.

For a declared blocker, `ticket.N.agent.unblocked` is the readiness signal that
resumes a parked consumer through the mid-turn checkpoint drain. Load
`stub-then-fetch.md`, then use the latest `ticket.N.branch.push` payload only to
fetch and inspect its validated ref (never a guessed `origin/aiur/N`; use
`scripts/resolve-ticket-branch N` when no event ref is available). Do not infer
readiness from `branch.push` alone. Record the concrete inspected reason if the
explicitly-unblocked dependency is still unusable; otherwise remove any
temporary stub and stack on the blocker branch.

`aiur_declare_blocker(N)` returns `pending` after the ordered declaration is
admitted, not after GitHub confirms the dependency. Background failures are
terminal in daemon diagnostics. If admission is indeterminate, inspect the
authoritative GitHub dependency state before deciding whether a retry is safe.

`blocked` and `unblocked` are required single-attempt, fire-and-forget emissions:
enqueue each once and continue without waiting, polling, or retrying.

So you only need explicit `aiur_subscribe` for **watch use cases** — e.g., tracking a sibling ticket that isn't a blocker.

## Don't do

- Don't bind a pattern just to read it once. Subscriptions are for ongoing watch; if you want a one-time read, `aiur --logs <id>` is the right tool.
- Don't bind `#` (everything) — you'll drown in noise.
- Don't pair `aiur_declare_blocker(N)` with `aiur_subscribe("ticket.N.#")` — the blocker declaration handles the auto-subscription already.
