# GitHub agent read cache

## Shared agent reads

Agents run `gh` through a wrapper that keeps the answers, so the next agent
asking the same question is served the first agent's answer — the exact output
the first call produced, replayed byte for byte.

These reads are shared:

| Read | Shared |
| --- | --- |
| `gh pr view`, `gh issue view` with `--json` and a number | Yes |
| `gh pr list`, `gh issue list` with `--json` | Yes |
| `gh api` GET of a repository endpoint | Yes |
| A CI or merge verdict — `gh pr checks`, or `--json` asking for `statusCheckRollup`, `mergeable`, `mergeStateStatus`, `state`, `reviewDecision` and their like | No; never shared, at any age |
| Anything else — no `--json`, `gh pr diff`, `gh api graphql`, every write | No; the call goes to GitHub as before |

A verdict is refused rather than kept briefly because a push and a completing
check run do not pass through the wrapper, so nothing could retire the answer
before an agent acted on it.

The same refusal applies to direct REST paths for check runs, check suites,
commit statuses, reviews, requested reviewers, the pull-request resource
itself, merge state, and Actions run or job state. Spelling a verdict read as
`gh api` does not make it safe to cache.

Stable Actions workflow *definitions* (`actions/workflows`) are still shared.

A workflow definition changes when its YAML is edited, which is a
wrapper-passing write that retires it, while a run's status is a verdict that
nothing retires. This is a deliberate divergence from the daemon's `ReadCache`
policy, which refuses every `/actions` path wholesale — the two stores serve
different callers with different invalidation reach.

Answers are kept for 60 seconds. **Conditional requests and 304s.** `gh api` reads carry a validator where the
store holds one: a re-read sends `If-None-Match` with the entry's stored `ETag`,
and an unchanged answer returns `304`, is served from the cache, and is
reconciled free — the same contract as the daemon's REST reads.

The high-level subcommand reads — `gh pr view`, `gh pr list`, `gh issue view`,
`gh issue list` — hit GitHub's GraphQL endpoint, which returns no `ETag` and no
`Last-Modified`, so there is no validator for the store to send. Those entries
stay TTL-cached with invalidation markers.

When a high-level read does return a `304` (an underlying REST read), the
wrapper reconciles the lease as free rather than billing it full-price.

The free share a TTL body cache cannot recover is GraphQL's — which no cache on
either side can recover.

The wrapper records hit and miss events in durable `agent-cache.tsv` files in
each agent workspace. These counters describe the agent `gh` cache on that
workspace's host; they do not include remote SSH workers in a local census.

The cache key includes the exact requested output shape. Different JSON fields, templates or queries miss independently to preserve `gh`’s output.

Likewise, a write or daemon delivery retires every shape of the changed
resource to protect correctness.

Different output requests cannot share bytes, and a changed resource cannot
safely reuse an older answer. The cache therefore keeps its byte-exact key,
correctness invalidation, and 60-second lifetime.

The wrapper now records a reason with every miss (`absent`, `expired`,
`invalidated`, `bypassed`, `clock-skewed`, `corrupt`, or `torn`).

That lets a later regression distinguish expected correctness misses from
entries expiring before reuse, and can tell a cold cache from a
store-integrity failure — a present stamp whose body has vanished is `torn`, never `absent`.

Editing a ticket or a pull request discards the kept answers for it at once, so
an agent never reads back what it just replaced.

So does anything the daemon learns about that resource — a webhook delivery, a
comment Aiur posted itself. That is what lets a free delivery stop sixteen agents
paying to discover the same change.

Agents that ask **at the same moment** are also one call, not many.

Thirteen agents opening the same pull request in the same second cannot be helped
by a kept answer, because none exists yet when they all look. One is admitted to
fetch and the rest wait behind it, then read what it wrote.

If the admitted one never answers, the others stop waiting and fetch. The cost is
the single call the waiting was meant to save, never a stall.

Sharing settings:

| Setting | Effect |
| --- | --- |
| `AIUR_GITHUB_STATE_CACHE_ENABLED=0` | Turns sharing off; every call goes to GitHub. |
| `AIUR_GITHUB_STATE_CACHE_BYPASS=1` | Makes one call ignore kept answers, for a decision that must not be stale. |
| `AIUR_GITHUB_STATE_CACHE_TTL_MS` | How long an answer is kept, in milliseconds, rounded down to whole seconds. Below 1000 keeps nothing. |
| `AIUR_GITHUB_STATE_CACHE_WAIT_MS` | How long an agent waits for another agent's identical call before making its own. |

If the store is missing or unwritable, every call behaves as it did before.

Sharing is between the agents on one host that use the same GitHub credential —
the same boundary the shared request budget draws. A second credential keeps its
own answers, because a response can depend on who asked.

A change made outside those agents — a merge from the web UI, a label set by
somebody else — is not seen by the wrapper. Aiur learns of it through the webhook
or the next poll and retires the affected answers then.

That gap is the exposure, and it is why a verdict is never kept at all.
