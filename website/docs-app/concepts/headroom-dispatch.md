# Headroom dispatch

`agent.account_selection: headroom` follows backend preference first, then
chooses the account with the most usage left on that backend.

```yaml
agent:
  priority: [codex, claude]
  accounts:
    claude: [default, everdred]
  account_selection: headroom
  routing:
    1: ["codex", "claude:sonnet"]
    3: ["codex:gpt-5.5:high", "claude:sonnet"]
    5: "claude:opus"            # one route: headroom only picks the Claude account
```

At each dispatch Aiur:

1. Takes the routes the ticket's complexity level allows (the `agent.routing`
   value, a list or one route). A level with no routing entry uses
   `agent.priority`.
2. Drops routes that the existing gates drop: a backend that is not
   dispatchable, a missing credential, or a peak-pricing window.
3. Expands each route into one candidate per account in
   `agent.accounts.<backend>`. A backend with no listed accounts is one
   implicit account.
4. Scores each candidate by the remaining fraction of its **binding window**:
   the most-used of its 5-hour and weekly windows.
5. Uses the first backend in `agent.priority` that has a non-exhausted
   candidate. Within that backend, unknown usage ranks first so an account
   without a reading can be used and observed; then known usage with more than
   10% left, then known usage with 10% or less left. An exhausted candidate is
   never picked. Ties keep configured account order.

If Codex is first in `agent.priority`, Claude's higher headroom does not make
Claude win while Codex has an available route. When Codex is unavailable or
all its candidates are exhausted, dispatch falls through to Claude and chooses
the Claude account with the most headroom.

A missing or stale reading is unknown, not full. Unknown ranks ahead of any
known reading so an unobserved account is not skipped indefinitely. This is an
exploration rule, not a claim that the account has more allowance: it may be
near its limit. The selected account's next usage observation replaces the
unknown score, and dispatch still never selects an account known to be
exhausted.

When every candidate is exhausted, the ticket waits for a reset, as an
exhausted `agent.priority` chain does. A `model:` label still pins the
backend; headroom then picks only the account. A ticket that hits a usage
limit pauses as before, and its next dispatch is scored again.

Usage comes from the daemon's per-account meters for Claude, and from the
usage ledger (`model-usage.json`) for Codex. Codex writes the ledger when a
session starts or reports its limits; the background probe runs only while
every candidate is limited. So a backend that gets no work keeps an old
reading.

While this policy is on, the daemon refreshes the Claude meters whether or not
a dashboard is open, so dispatch does not depend on someone watching.

It uses the shorter of `polling.usage_interval_seconds` and
`agent.headroom_reading_max_age_seconds`, without going below the provider's
120-second polling floor. A max age below that floor can become stale between
probes.

A reading older than `agent.headroom_reading_max_age_seconds` (default 1800)
scores as unknown and is shown with its age, for example
`codex=unknown (stale, 3d old)`. A current reading older than a minute shows
its age too (`codex=40% (12m old)`).

The ledger is per backend, so two or more accounts on one backend without a
per-account meter read as unknown. Unknown is never shown as a number.

Each dispatch records the chosen backend and account and every alternative's
score: in the daemon log (`headroom_dispatch`), in the ticket's agent event
stream (`dispatch_selection`), in the `dispatch` telemetry point, and as the
account reason in `aiur status` and `aiur agents`.

`aiur usage` shows the shared provider snapshot, including remaining
percentages and freshness where the backend exposes them. The `aiur accounts`
compatibility alias is deprecated and now prints that same provider summary.

See also [`agent.account_selection`](/reference/configuration) and
[Accounts by backend](/guide/claude-accounts).
