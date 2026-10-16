# GitHub webhooks and resource cache

## Comments arriving twice

A comment can reach Aiur down two paths: a webhook delivery, which is free and arrives first, and the comment sweep, which reads it back from the API.

Both must exist. Deliveries are genuinely lost — measured here, 9 of 100 returned `502` during a daemon restart, GitHub retried none, and none arrived later. A sweep that skipped webhook-backed repositories would drop those comments silently.

Aiur therefore records each comment it has processed by its identity, and both paths write to the same record.

| Situation | What happens |
| --- | --- |
| Delivery arrives | The comment is published once. The next sweep reads it, recognises it, and does not publish it again. |
| Delivery is lost | Nothing recorded it, so the next sweep publishes it. No delay beyond one poll interval. |
| Older comment lost, newer one delivered | The older one is still recovered. Suppression is per comment, not "everything before the newest thing I saw". |
| Daemon restarts | The record is on disk, so a comment handled before the restart is not re-published after it. |
| A comment is edited | The agent wakes again. The record stores the comment's `updated_at`, so an edit is a new state of that comment rather than a repeat of it. |
| No webhook installed | Nothing is ever recorded by a delivery, so nothing is ever suppressed. Polling behaves exactly as it did before. |

Inline review comments on a pull request coalesce per **review thread**, not per comment. A review thread is one finding plus its replies, so a reviewer adding several comments to one thread wakes the agent once.

The webhook resolves a delivered comment's thread from the comment's own node id, so both pipes key inline feedback the same way. A follow-up comment on an already-woken thread within the one-hour replay window does not wake a second time; it wakes once the thread is re-read after the window passes.

If the delivery cannot be resolved to a thread, it is keyed on its own comment id as before — a duplicate wake is recoverable, a dropped delivery is not.

If the record is unavailable or unreadable, Aiur behaves as though it were absent: it publishes, and the existing one-hour replay window catches short-range duplicates. A duplicate wake is recoverable; a dropped comment is not.


## One record for one resource

The record is not only a set of marks. Aiur keeps the resource GitHub returned — the comment, the issue, the pull request — addressed by what it is: type, owner, repository, id.

It is not addressed by which code path asked for it. So a resource read down one path answers every other path.

Each entry carries when it was recorded, which path recorded it, the resource's own `updated_at`, and an `ETag` where GitHub provides one.

When a path deposits the resource itself, that is written to disk alongside the marks, so a restart does not re-buy state the daemon already had. Keeping only the `ETag` would not achieve that: a validator sent for a resource Aiur no longer holds earns a `304 Not Modified` with no body — a spent request that returns nothing usable.

Every write that changes what a reader could see is announced, so anything watching that resource learns about it without asking GitHub. A change costs one API call at most, no matter how many things were watching.

A webhook delivery is the cheapest writer of all — GitHub has already paid for the round trip, and the delivery arrives before any sweep would have read the same object — so every delivery for a tracked repository deposits the state it carries, whether or not it also wakes an agent.

| Delivery | What it deposits |
| --- | --- |
| Any comment activity | The issue or pull request the comment hangs off, with its label set. |
| Comment created or edited | That comment as well. |
| Review submitted, edited or dismissed | The review, and the pull request. |
| Pull request, any action | The pull request — including a `synchronize` push, which wakes CI reconciliation rather than publishing. |
| Issue, any action | The issue and its label set, whether or not the action is one Aiur reacts to. |
| Check run | The matching run inside a complete CI-context snapshot already established for the same head. A lone delivery never invents the rest of the collection. |
| Review thread resolved | The matching thread inside a complete review-thread snapshot already established for the pull request. |
| A comment or issue is deleted | Nothing is deposited and the held body is discarded, because serving an object that no longer exists is worse than not holding one. |
| A delayed delivery carrying older state | Refused. A body cannot walk a resource backwards and then be reported as freshly fetched. |

A deposit records what Aiur is *holding*, never what it has *handled*. The two are separate facts: only a successful publish marks a comment processed, so caching a body can never suppress the event for it — including for a change Aiur made itself, where the body is cached and the self-loop stays filtered.

A cold, corrupt or stopped cache falls back to fetching. It costs throughput, never correctness. Timelines persist (at most 1,000 bodies per repository). After boot, single-page evidence is ETag-revalidated against the current allowlist. Multi-page timelines and a `304` reporting a new page require a full refetch.

Comment, CI, and review-thread pollers consult these complete snapshots before
building their GraphQL documents. A poll-written snapshot is only a baseline;
it does not suppress the next poll. When a verified delivery advances that
baseline, the matching collection is eligible for 30 seconds.

During that window Aiur omits `reviewThreads` or the delivered `CheckRun`
fields. Legacy commit statuses, `reviewDecision`, `mergeable`, and other strict
verdict state remain live reads.

Successful polls write complete selections back so the next delivery and poll
converge on the same state. Partial, stale, poll-only, head-mismatched, or
unavailable entries fall back to GitHub. A review-comment delivery invalidates
the complete thread snapshot because one comment cannot prove the collection.


## Optional webhook

The webhook shortens reaction time for repository events while polling continues as a reconciliation path.

| Setting | Value |
| --- | --- |
| Payload URL | `https://<your-host>/api/v1/github/webhook` |
| Content type | `application/json` |
| Secret | The same strong value exported as `AIUR_GITHUB_WEBHOOK_SECRET` to Aiur. |
| Signature | GitHub `X-Hub-Signature-256`, HMAC-SHA256 over the raw request body. |
| Events | `issues`, `issue_comment`, `pull_request`, `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread`, `check_run`, and `check_suite`. |

The hostname is yours to choose — `hooks.aiur.dev` is this operator's setup, not a requirement. Without a domain, a quick tunnel (`cloudflared tunnel --url`) exposes the daemon on a temporary public URL, fine for a single session.

`POST /api/v1/github/webhook` has no configuration keys and no bearer credential, authenticates every delivery by its `X-Hub-Signature-256` digest, and fails closed.

Select every event listed above so a `pull_request_review_thread` delivery reconciles resolved or reopened threads immediately while the scheduled comment sweep remains the loss-recovery path.

| Delivery | Result |
| --- | --- |
| Signature header absent, malformed, or mismatched | Rejected with `401`. |
| `AIUR_GITHUB_WEBHOOK_SECRET` unset or blank | Rejected with `401` and a needs-attention `system.github_webhook.secret_missing` alert; an unset secret never enables unsigned access. |
| Legacy SHA-1 `X-Hub-Signature` header | Ignored; never accepted as a fallback. |
| Body larger than 25 MB | Refused, matching GitHub's own delivery ceiling. |

| Webhook state | Polling behavior |
| --- | --- |
| Not configured | Polls at `polling.interval_seconds`. |
| Configured but never delivered | Polls at the full interval until a verified delivery proves the path works. |
| Delivering | Uses the configured `webhooks.poll_widen_factor` for slower reconciliation polls. |
| Silent past the threshold | Returns to full polling and raises an attention; a later delivery restores webhook mode. |

A proven webhook also lengthens the daemon's read-cache TTL: a delivering repo gets hour-long `ReadCache` TTLs, because a delivery retires the reads it makes stale — the TTL is only a backstop.

A repo that is not proven (or degraded back to full polling) keeps 30-second TTLs, and degradation collapses the TTL immediately.

Repository-configuration reads are the one exception: branch protection, rulesets and workflow-file reads (`:repo_config`) ride a five-minute TTL in polling mode and still rise to an hour under a proven webhook, because every delivery also retires a repository's config reads.

See [Configuration](/reference/configuration#webhooks) for the repository list, silence threshold, sweep interval, and widen factor.
