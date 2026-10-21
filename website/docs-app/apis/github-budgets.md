# GitHub API budgets

## API budgets

Aiur's resident Python broker reuses one SQLite connection and batches commands per process. Shell `gh` guards share its database, so daemons using one credential share quota ledgers.

The request pacer may refuse a read as `:shared_budget` before GitHub. Dispatch retries these holds and escalates after `agent.dispatch_hold_attention_threshold` consecutive declines; `aiur status` reports their per-resource rate as `GITHUB HOLDS`.

A broker admission waits up to five seconds (1.5 seconds on the Orchestrator process) for transient shared-lease saturation before returning a **local hold**: Aiur backs off, keeps the claim, and keeps attempt counters. The network request deadline starts after admission.

Broker commands have a 1.5-second round-trip deadline; admission may wait up to 1.5 seconds in the Orchestrator and 5 seconds for other clients. These bounds keep an overloaded ledger from holding callers indefinitely; timeout handling preserves fresh cached dependency decisions.

Main-watch polling, and the base-branch fixer it drives, may hold one lease above the in-flight caps. Cooldowns, hourly ceilings and pacing still apply to it.

Startup claim reconciliation retries a release refused by a budget hold on every candidate poll without spending an attempt. It raises `startup_claim_reconciliation_failed` only if the hold lasts ten minutes.

Landing-watch observation and per-PR reads, plus issue-provenance timeline reads, wait out bounded local holds before reporting an unavailable poll or deferred dispatch authorization. Landing-watch does not retry a whole poll after processing starts, so a late hold cannot repeat earlier journal or PR actions.

`Errors.outcome/1` sorts results into `:complete`, `:held` (never sent), `:unknown` (may still apply) or `:failed`; an unknown review-thread reply is reconciled by reading the thread, never reposted.

Resident broker exits also back off as local holds; the next call restarts the
broker. Requests retain independent deadlines while sharing a transaction.
Expired work is rolled back before commit, with 50 ms reserved for commit and
reply delivery.

The resident broker disables WAL auto-checkpointing on request connections. A
background thread runs passive checkpoints outside the serialized request loop.
One-minute measurements report latency by command type, Python queue wait,
SQLite lock wait, execution, commit, and latest checkpoint duration and frames.

Sustained timeouts raise one `system.github.budget_broker_degraded` attention with duration; its `.resolved` clears it on recovery.

| Budget | Unit | Where to read it |
| --- | --- | --- |
| Core | REST requests | The Units meter, `aiur units`, or `aiur github-cost --budget core`. |
| GraphQL | Query points | The Units meter, `aiur units`, or `aiur github-cost`. |
| Anonymous core | REST requests made without a token | A `core:anonymous` row, present only once an anonymous read has been observed. |
| Secondary limit | Temporary abuse-control backoff | A separate Units row while the backoff is active. |
| Issue dependencies / sub-issues | Route-specific REST windows | Separate `core:issue_dependencies` and `core:sub_issues` observations in the quota snapshot; excluded from primary Core and dispatch. |

Broker command summaries include mailbox, Python queue, SQLite open, lock-wait,
SQL execution, and commit latency by request type so the slow stage can be
identified. Checkpoint duration and frame counts are reported separately.

Anonymous reads — a public `CODEOWNERS` fetch when no token is configured, for
instance — bill GitHub's 60/hour unauthenticated per-IP allowance rather than
the authenticated core budget, so they are metered in their own window. An
exhausted anonymous allowance holds further anonymous reads but never gates agent dispatch.

GitHub can return a separate `core` window on issue dependency and sub-issue
endpoints. Aiur retains those headers under route-specific resource names so
they cannot replace the primary Core window used by Units and dispatch.

The REST `/rate_limit` refresh updates Core from its `resources.core` value.
The GraphQL window comes from GraphQL response headers or `rateLimit` data; the
REST response's `resources.graphql` value does not update it.

### Where the budget went

The meters above say how much is left.

`aiur github-cost` says which code path spent it, ranked by points and by points per hour, for one budget at a time.

| Column | What it means |
| --- | --- |
| `CALLER` | The code path that issued the call, not the ticket it was issued for. A batch query naming 33 tickets is one poller, so it is one row. |
| `POINTS` | What the calls cost the budget in the current window. |
| `POINTS/HR` | The rate the caller is running at, extrapolated from the elapsed part of the window rather than a whole hour. `unknown` when too little of the window has elapsed to extrapolate from. |
| `SOURCE` | `reported` when GitHub priced the call itself through a `rateLimit { cost }` selection in the query, `estimated` when it did not and the call is counted at one point. GraphQL queries are instrumented automatically; mutations and REST calls are counted per request. |

Below the ranking, one reconciliation line per budget compares the sum of the
rows against `limit - remaining` on the credential's own window:

| Line | What to do |
| --- | --- |
| `reconciles` | The ranking accounts for the window's spend. |
| `N points unattributed (spend outside this process)` | Expected. Anything else using the same credential — a shell `gh` call, another Aiur instance — is spend this process never saw. It bounds how much of the window the ranking explains. |
| `DOES NOT reconcile — attributed more than was spent` | A double count in the accounting. Points cannot be spent twice, so this is a defect worth reporting. |
| `not measurable` | No window has been observed yet. Not the same as zero spend. |

The command reads the meter the daemon already keeps and issues no GitHub
request of its own, so checking it is free.

### Reading these numbers without fooling yourself

Three traps have each cost a run more than an hour. All three produce a figure
that looks like a leak and is not.

**A daemon restart invalidates reconciliation for the rest of the window.**

The daemon's attribution window restarts with the process; GitHub's does not.
Points spent before the restart stay in `limit - remaining` and appear in no row of the ranking.

So the unattributed figure is inflated by exactly that much until the GitHub
window rolls. Wait for the reset before comparing attribution against the credential's window.

**The unattributed figure is not a leak.**

As the table above says, it is expected. It counts anything sharing the
credential that this process did not issue: a shell `gh` call, a script minting
its own installation token, another Aiur instance.

A monitoring loop sampling the API on the same credential *is itself* unattributed spend, so an investigation can widen the gap it is measuring. Baseline with the fleet quiet and your own tooling stopped.

**Agent `gh` calls do not bill the daemon's credential.**

Agents hold the bot PAT; the daemon under App auth holds an installation token.
Separate budgets, separate windows.

An agent-driven `gh pr view` never appears in the daemon's GraphQL ranking and never spends the App pool. Agent activity correlating with App-pool spend means something else scales with the fleet.

Related: a low read-cache hit rate is not automatically a defect. See
[Shared agent reads](/apis/github-agent-cache#shared-agent-reads) for what the cache refuses on purpose
and why refusing is correct.

### Credential pooling

GitHub's budgets are per credential. An operator who holds more than one
credential can let the daemon spread read traffic across them instead of
exhausting one, by listing them under `tracker.github.credentials`:

```yaml
tracker:
  github:
    credentials:
      - id: app
        kind: app_installation
        identity: my-aiur[bot]
        writes: true
      - id: machine
        kind: machine_user
        identity: my-bot-account
        token_env: MACHINE_USER_TOKEN
        writes: true
      - id: operator
        kind: human
        identity: my-login
        token_env: OPERATOR_TOKEN
```

An empty list — the default — is the single-credential setup and is unchanged by any of this.

For each request the daemon picks the eligible credential with the most
remaining budget for that request's resource.

Core and GraphQL are chosen separately. They are separate budgets on separate
windows, so REST core sitting near-idle is not headroom a GraphQL query can spend.

Headroom comes from the `x-ratelimit-*` headers of calls the daemon was already
making, so selection costs no budget of its own.

The dashboard's primary GitHub window follows the daemon's primary credential.
Readiness checks that use the operator-only `AIUR_CI_READINESS_TOKEN` do not
replace it; other credential windows remain available in `aiur github-usage`.

Readiness requests carry an explicit non-primary identity. Requests without a
resolved credential identity are retained under their token fingerprint and
never update the primary window. The primary meter changes only for requests
identified as the primary credential.

A credential with no observation this window is treated as probably full rather
than as empty, and ties resolve to the primary credential.

`aiur github-usage` grows a per-credential section and a pool total. Both
commands show them only when more than one credential is configured.

#### Writes stay on their own identity

A `human` credential is read-only and cannot be configured otherwise.

Every write GitHub records against a person's token is attributed to that
person: their name on the comment, their account in the audit trail.

Aiur's merge policy also depends on agent pull requests and the reviewing human
being different identities. Pooling writes would break that at random.

Pool the reads, which is where the budget actually goes. Leave comments, labels,
merges and pull request creation where they belong.

#### What pooling is worth

Each credential carries its own hourly budget, so three credentials raise the ceiling roughly threefold.

That is headroom, not a fix. A fleet burning more than its combined ceiling
still exhausts it, just later.

The pool total is also a ceiling rather than a balance, because the credentials'
windows reset at different moments. Pooling buys margin while the burn itself is reduced.
