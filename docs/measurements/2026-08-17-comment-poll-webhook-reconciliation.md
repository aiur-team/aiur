# Comment poll: webhook reconciliation and transport inversion (2026-08-17)

Records the cost model after #2069. Supersedes the comment rows of
[2026-07-30-daemon-read-budget.md](2026-07-30-daemon-read-budget.md).

## The problem this measures

Every issue and review comment was fetched twice. Once free, over a webhook:
verified at `hooks.aiur.dev` and normalized by
`Aiur.Events.GitHubWebhook.Normalizer`, whose own moduledoc says its keys are
taken "one for one from `CommentPollBatch.normalize_comments/1`" so consumers
cannot tell the paths apart — which is the proof that both carry the same GitHub
event. Once expensively, over GraphQL, by `Aiur.GitHub.CommentPollBatch`, which
the poller reached for by default; conditional REST existed but was only the
error handler.

The poller had no idea webhooks existed. `comment_polling.ex` and
`comment_polling/*.ex` contained no reference to `Webhooks`, `DeliveryMode`, or
transport at all.

## GraphQL: priced by GitHub, not estimated

GitHub's GraphQL budget is scored on nodes *requested*. Both query shapes were
sent to the live API with `rateLimit { cost }` in the selection set, so these are
GitHub's own numbers rather than a node count of ours. Ten targets, two branch
candidates each, against `aiur-team/aiur`:

| Query shape | Cost (points) |
| --- | ---: |
| Before — comments + review threads on every branch candidate | **114** |
| After — identity-only candidates, no comments anywhere | **11** |
| After, plus one per-pull-request review-thread read | **1** each |

**10.4× lower** for discovery. Worst case, where every one of the ten targets has
a resolved pull request whose threads must be read separately, the cycle is
`11 + 10 = 21` points against the old `114` — still **5.4×** lower, and that is
the floor, not the expected case.

### Where the saving actually came from

Not from reading fewer comments for pull requests the poller cares about. From
no longer reading them for pull requests it had not identified yet. Each target
contributes up to two `headRefName` lookups asking for `first: 5` candidates, and
every candidate carried the full field set — `comments(last: 100)` plus
`reviewThreads(first: 100) { comments(last: 20) }`, roughly 2,100 nodes each. So
discovering *one* pull request bought the complete contents of up to *ten*.

Identity is now cheap and speculative; content is expensive and never
speculative. `reviewDecision` and the head commit date stay on the identity field
set, so the rework gate (#1756) keeps full review-freshness context.

## REST: what is free and what is not

Comments are now read with `Aiur.GitHub.Comments.fetch_issue_comments_conditional/2`
carrying `If-None-Match`. A 304 does not count against GitHub's primary REST
limit, so an unchanged comment read is free rather than merely cheap. Validators
live in `Aiur.GitHub.ResourceStore` and are checkpointed to disk, so a restart no
longer forces a full-price re-read of every watched ticket — which mattered,
because restarts here are routine.

**Made conditional since the first measurement (follow-up on #2069):**

- `fetch_pull_request_reviews/2` — the poller's review-submission sweep now
  reads `If-None-Match` from the `:pull_request_reviews` validator and reuses
  the held list on a `304`, so the last comment kind the sweep re-read at full
  price every cycle is free in steady state. Webhook-delivered reviews stay
  exactly-once via the per-review identity mark, and a lost delivery is still
  recovered because the read itself is never skipped.
- `fetch_open_pull_requests_by_label/2` — watch-target discovery now reads the
  open-pull-request collection conditionally under `:labelled_pull_requests`
  and serves the held list back on a `304`.

**Still unconditional in a cycle, named rather than rounded to zero:**

- `fetch_open_pull_request_for_branch/2` — one read per human-review target, in
  `TargetSelection.with_human_review_pr_updated_at/2`. This is a two-stage
  search (a per-head legacy-branch query plus a paginated fallback scan over
  all open pull requests), and the two stages have different validators, so no
  single stored ETag can validly cover both: a `304` against the legacy query
  proves nothing about a generated-branch result. `Aiur.GitHub.HumanReviewGate`
  already defers this exact read for the same reason. It stays a named cost
  until the freshness signal moves onto the GraphQL identity field set.
- `fetch_unaddressed_pr_review_thread_comments/2` — GraphQL, 1 point per pull
  request. GraphQL has no conditional-request mechanism, so this one cannot be
  made free; it was made *rare* instead, by paying it once per resolved pull
  request rather than once per speculative candidate.

A steady-state comment and review sweep over unchanged tickets is free, and so
is watch-target discovery. The cycle as a whole is still not zero where
human-review targets are present: the branch-freshness search above is the
remaining REST spend, and the GraphQL thread read the remaining points. Both are
named rather than rounded away.

## Suppress and recover, which pull against each other

A comment the webhook delivered must be processed exactly once. A comment whose
delivery was **lost** must still be recovered — this is not hypothetical: 9 of
the last 100 deliveries returned 502 during a daemon restart, GitHub retried
none, and none arrived later (2 `issue_comment`, 7 `check_run`).

"Skip polling when the repo is webhook-backed" satisfies the first and silently
loses the second. A *timestamp watermark* — "ignore anything older than the
newest thing I saw" — fails differently but just as badly: a delivered comment
advances the mark past an older sibling whose delivery was dropped, and that
sibling is discarded forever.

Suppression is therefore keyed by **resource identity**, `(resource_type, owner,
repo, id)`, in `Aiur.GitHub.ResourceStore`. Both pipes write to it; the webhook
writes first because it is free and arrives first. The sweep always runs and
always reads — that read is what makes recovery possible — and only the
individual comments some pipe already processed are held back. An older lost
comment is a different resource, not an earlier version of a newer one, so it
cannot be masked.

The store fails open everywhere: no state directory, unwritable file, corrupt
document, or dead process all answer as the pre-store code did — no validator,
nothing processed. A cache that cannot answer costs throughput, never
correctness, and the safe direction is a duplicate that the publisher's existing
one-hour window still catches, never a dropped event.

### Identity is not enough on its own: comments are mutable

A GitHub comment's id survives an edit; only `updated_at` moves. Since the
sweep's `?since=` filter is on `updated_at`, an edited comment comes back around
on the next cycle — and suppressing on identity alone would read that as a
redelivery of the original and swallow it for the full 72-hour window, across
restarts. Editing a ticket comment to correct an agent's instructions is a normal
workflow here, so that would be a real regression against today's behavior, where
the publisher's one-hour volatile window expires and the edit wakes the agent.

Each mark therefore records the `updated_at` it was made at, and a resource whose
version has moved reads as unprocessed. This is still not a watermark: nothing is
compared for order, only for equality against the version actually processed, so
an older lost comment recovers exactly as before.

Shortening the retention window was the alternative and it is the wrong trade —
72 hours is the envelope in which GitHub still retries a delivery, which is the
whole reason the window exists. The version is recorded instead, so both
properties hold at once: an unchanged re-fetch stays suppressed for three days,
and an edit at any point inside them still wakes the agent.

## Unchanged on purpose

- **`Webhooks.IntervalPolicy`'s invariant.** A repo that is not proven
  webhook-backed polls at the base interval, unchanged, always. Nothing here
  consults transport to decide whether to poll, so an unproven repo cannot be
  slowed down by this change — there is no code path that could.
- **A repo with no webhook.** Nothing ever marks its comments, so nothing is ever
  suppressed. It polls and publishes exactly as before.
- **The review-thread dedup granularity.** Inline review comments coalesce per
  *thread* on the GraphQL thread node id, and the webhook resolves that same id
  in the delivery path (`Aiur.Events.GithubWebhook.ThreadResolver`), so both
  pipes key the same event the same way and a single comment wakes the agent
  once (#2081). The tradeoff, chosen deliberately: a follow-up comment on an
  already-woken thread within the one-hour replay window does not wake a second
  time. The durable store names the thread resource for both pipes, so the
  suppression survives a restart. A delivery that cannot be resolved to a
  thread falls back to per-comment keying — the safe direction, a duplicate
  wake over a dropped delivery.

## How to re-measure

The daemon's own token is shared with the agent fleet, which shells out to `gh`
through `.aiur-runtime/bin/gh`, so an hourly `rate_limit` delta does **not**
isolate the poller — agents are currently the dominant consumer (`graphql 0/5000`
with REST at `4939/5000` was measured while 13 agents ran). To measure the poll
cycle specifically:

1. Price a query shape directly: send it with `rateLimit { cost }` in the
   selection set and read GitHub's answer. That is how the table above was built
   and it is immune to fleet noise.
2. Count requests at the call site: `GithubCommentsPoller.poll/2` accepts a
   `:request_fun`, so a cycle's requests can be recorded and asserted. See
   `test/aiur/events/webhook_poll_reconciliation_test.exs`.

Do not report a percentage as success. A steady-state cycle with no upstream
change should cost zero; where it does not, name the request that is still
unconditional — the four above are named for exactly that reason.
