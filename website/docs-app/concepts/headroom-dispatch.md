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
   candidate. Within that backend, unknown usage gets one exploration, then
   known usage with more than 10% left ranks first, followed by recently
   explored unknown and known usage with 10% or less left. Exhausted candidates
   are never picked. Ties keep configured account order.

If Codex is first in `agent.priority`, Claude's higher headroom does not make
Claude win while Codex has an available route. When Codex is unavailable or
all its candidates are exhausted, dispatch falls through to Claude and chooses
the Claude account with the most headroom.

An account with no current reading is unknown, not full. It gets one
exploration so usage can be observed.

For 120 seconds after dispatch, its unknown reading ranks below every known
account with more than 10% remaining. This window also applies to stale
readings, which may be near their limit. A fresh observation clears the window.
Otherwise, another exploration is allowed when the window ends.

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

## Usage floor

`agent.usage_floor_percent` (default `5`, `0` turns it off) lets you leave every
login enabled and still have Aiur stop *starting* work on one whose allowance is
nearly gone. It applies under `priority`, `balance` and `headroom` selection.

```yaml
agent:
  usage_floor_percent: 5      # 0 = never floor a route
  priority: [claude, codex, openrouter]
  accounts:
    claude: [default, everdred]
  backend_configs:
    openrouter:
      usage_floor_percent: 15  # this backend rests earlier than the others
```

At dispatch, a backend or account whose freshest reading shows this much or
less remaining **in any rate window** is skipped, and the next allowed route in
`agent.priority` and the ticket's routing list takes the work. A weekly window
at 3% floors the route even while its 5-hour window has 80% left, because the
tightest window is the one that runs out first.

Three cases never floor a route:

- **Unknown or stale readings.** Aiur keeps its existing behaviour rather than
  invent a shortage it never observed, and the dispatch record shows the
  reading's age.
- **A credit-based key without a known limit.** OpenRouter and other API keys
  use remaining credit against the key's limit when a reading exists (with the
  management key where one is needed); a key whose limit is unknown is never
  floored.
- **A pinned route.** A `model:` label and a backend the rate-limit fallback
  already chose are intent, and keep their route exactly as they ignore
  exhaustion today.

Recovery needs no config edit: when the reading shows the window reset, the next
dispatch uses the route again. `agent.backend_configs.<backend>.usage_floor_percent`
overrides the floor for one backend. The key hot-reloads like the rest of
`agent`.

The floor affects only new dispatches and turn handoffs. **An agent already
running is not stopped when its account crosses the floor**: it finishes its
current turn on the account it started on. A turn handoff re-chooses an account
on the backend dispatch already selected, so it skips floored accounts; when
every account on that backend is floored it falls back to the least-used one,
because a handoff cannot re-route to a different backend. `aiur status` and
`aiur usage` list each held route (`held: 3% left ≤ 5% floor, resets in 2h`),
and an alert fires when a route starts being floored and when it recovers. If
every route is floored, the ticket waits for a reset instead of failing its
dispatch.

See also [`agent.account_selection`](/reference/configuration) and
[Accounts by backend](/guide/claude-accounts).
