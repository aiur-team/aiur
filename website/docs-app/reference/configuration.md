# Configuration reference

Choose a topic below. Existing section links lead to the same reference content.

- [Daemon configuration](./configuration-daemon)
- [Tracker and polling configuration](./configuration-tracker)
- [Integration configuration](./configuration-integrations)
- [Agent configuration](./configuration-agent)
- [Build Order configuration](./configuration-build-order)
- [Voice configuration](./configuration-voice)
- [Configuration notes](./configuration-notes)

## Environment variables

[Read this section](./configuration-daemon#environment-variables).

## Top-level

[Read this section](./configuration-daemon#top-level).

## executor

[Read this section](./configuration-daemon#executor).

## tracker

[Read this section](./configuration-tracker#tracker).

## polling

[Read this section](./configuration-tracker#polling).

## monitoring

[Read this section](./configuration-daemon#monitoring).

## webhooks

[Read this section](./configuration-tracker#webhooks).

## workspace

[Read this section](./configuration-daemon#workspace).

## worker

[Read this section](./configuration-daemon#worker).

## hooks

[Read this section](./configuration-daemon#hooks).

## prewarm

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-08 -->
| --- | --- | --- | --- |
| `prewarm.base_build` | string | none | One-time base build command. |
| `prewarm.base_build_file` | string | none | Sibling script loaded into `base_build`. |
| `prewarm.build_timeout_minutes` | integer | 60 | Total time allowed for a base clone, fetch, and build. |
| `prewarm.enabled` | boolean | false | Opts into one warm base checkout. |
| `prewarm.poll_seconds` | integer | 0 | Base-refresh interval; 0 disables polling. |

`poll_seconds: 0` disables periodic refreshes, not dispatch-time freshness checks.

A base refresh is bounded from clone/fetch start by `prewarm.build_timeout_minutes` (default 60); on expiry, Aiur terminates its process group and releases dispatch for cold-clone fallback. The independent idle watchdog releases a stalled dispatch hold after 10 minutes.

For the idle watchdog, "stalled" means the hold's worker is dead with no completion signal in flight. Timed-out builds are not retried automatically; restart Aiur to retry.

The `system.dispatch.prewarm_blocked` alert is not raised for a routine refresh: a freshness probe that self-clears in seconds holds dispatch too briefly to matter to an operator.

The alert fires only once a hold has persisted past the routine bound: a probe that fails or exceeds its own timeout, a build that genuinely holds the fleet, or a stalled hold the watchdog releases. Its `.resolved` fires when the gate clears.
[Read this section](./configuration-daemon#prewarm).

## pr_watch

[Read this section](./configuration-daemon#pr-watch).

## pr_health

Periodic scan of open pull requests for conditions that stall PRs silently: a PR authored by a configured human merger (unmergeable by construction, since GitHub blocks
self-approval), a non-draft PR older than `stale_hours` with no review, and a rework ticket whose PR's own contribution has genuinely changed since its blocking review.

Findings raise needs-attention alerts in the Executor's alert feed
(`system.pr_health.unmergeable_author` / `system.pr_health.stale_unreviewed` /
`system.pr_health.rework_merge_only`).

Enabling the scan enables the **rework re-queue**: a ticket in `agent:rework` whose PR's own contribution diff (`merge-base..head`) changed since the blocking `CHANGES_REQUESTED`
review is moved to `agent:human-review` for the second look — GitHub keeps `reviewDecision = CHANGES_REQUESTED` until a brand-new review, so nothing else re-queues it.

It also runs the **head-verdict router** on the same interval. At the open, non-draft PR's head, the configured
reviewer's `CHANGES_REQUESTED` moves `agent:human-review`, `agent:ci-wait` or `agent:error` to `agent:rework`.

An `APPROVED` that follows their same-head `CHANGES_REQUESTED` moves `agent:rework` to `agent:ci-wait`. An error ticket
moved to rework raises `system.pr_health.error_rework`. Each review routes once.

A PR whose head only moved via merges of the base branch (own contribution unchanged) is NOT re-queued; it raises
`system.pr_health.rework_merge_only` so the merge-only state is visible distinctly from genuine rework.

A re-queue that the thread-clearance gate refuses (the reworked PR still has unresolved review threads — the normal
state of a rework ticket) raises `system.pr_health.rework_requeue_failed`; the head is not throttled on a failed
write, so the re-queue retries on the next tick instead of silently stranding the ticket in rework.

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-10 -->
| --- | --- | --- | --- |
| `pr_health.enabled` | boolean | false | Enables the PR-health scan and the rework re-queue. |
| `pr_health.interval_seconds` | integer | 1800 | How often the scan lists open PRs. |
| `pr_health.stale_hours` | integer | 24 | A non-draft PR older than this with no review is flagged. |
[Read this section](./configuration-daemon#pr-health).

## events

[Read this section](./configuration-daemon#events).

## upgrade

[Read this section](./configuration-daemon#upgrade).

## alerts

[Read this section](./configuration-daemon#alerts).

## usage

[Read this section](./configuration-daemon#usage).

## netlify

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-24 -->
| --- | --- | --- | --- |
| `netlify.account_id` | string | nil | Netlify team/account ID to read. |
| `netlify.credit_alert_threshold` | integer | 0 | Emit a low-credit alert at or below this estimated balance; 0 disables the threshold. |
| `netlify.enabled` | boolean | false | Enable the read-only Netlify usage poller and dashboard card. |
| `netlify.poll_seconds` | integer | 900 | Netlify usage polling interval in seconds. |

## elevenlabs

[Read this section](./configuration-integrations#elevenlabs).

## compaction

[Read this section](./configuration-daemon#compaction).

## observability

[Read this section](./configuration-daemon#observability).

## decisions

[Read this section](./configuration-daemon#decisions).

## server

[Read this section](./configuration-daemon#server).

## dashboard_auth

[Read this section](./configuration-daemon#dashboard-auth).

## opencode

[Read this section](./configuration-integrations#opencode).

## experiments

[Read this section](./configuration-integrations#experiments).

## build_queue

[Read this section](./configuration-daemon#build-queue).

## Further sections

[Read this section](./configuration-daemon#further-sections).
