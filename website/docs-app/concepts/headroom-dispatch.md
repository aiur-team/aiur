# Headroom dispatch

`agent.account_selection: headroom` moves new work to whichever backend and
account has the most usage left, instead of following a fixed order.

```yaml
agent:
  priority: [claude, codex]
  accounts:
    claude: [default, everdred]
  account_selection: headroom
  routing:
    1: ["claude:sonnet", "codex"]
    3: ["claude:sonnet", "codex:gpt-5.5:high"]
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
5. Picks the best candidate. Known usage with more than 10% left ranks first,
   then unknown usage, then known usage with 10% or less left. An exhausted
   candidate is never picked. Ties keep `agent.priority` order.

When every candidate is exhausted, the ticket waits for a reset, as an
exhausted `agent.priority` chain does. A `model:` label still pins the
backend; headroom then picks only the account. A ticket that hits a usage
limit pauses as before, and its next dispatch is scored again.

Usage comes from the daemon's per-account meters for Claude, and from the
usage ledger (`model-usage.json`) for Codex. Codex writes the ledger when a
session starts or reports its limits; the background probe runs only while
every candidate is limited. So a backend that gets no work keeps an old
reading.

A reading older than `agent.headroom_reading_max_age_seconds` (default 1800)
scores as unknown and is shown with its age, for example
`codex=unknown (stale, 3d old)`. A current reading older than a minute shows
its age too (`codex=40% (12m old)`).

The ledger is per backend, so two or more accounts on one backend without a
per-account meter read as unknown. Unknown is never shown as a number.

Each dispatch records the chosen backend and account and every alternative's
score: in the daemon log (`headroom_dispatch`), in the ticket's agent event
stream (`dispatch_selection`), in the `dispatch` telemetry point, and as the
account reason in `aiur status` and `aiur agents`. `aiur accounts` shows the
remaining percent for every backend it can read.

See also [`agent.account_selection`](/reference/configuration) and
[Accounts by backend](/guide/claude-accounts).
