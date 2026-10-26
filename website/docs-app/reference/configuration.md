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

[Read this section](./configuration-daemon#pr-health).

## events

| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-11 -->
| --- | --- | --- | --- |
| `events.block_state_debounce_seconds` | integer | 10 | Debounces blocked/unblocked transitions. |
| `events.codeowners_refresh_seconds` | integer | 3600 | CODEOWNERS refresh interval. |
| `events.custom_events_per_turn_max` | integer | 5 | Caps custom events per turn. |
| `events.export.enabled` | boolean | false | Enables the external event journal; restart to apply. Reserved for the exporter; no feed is installed yet. |
| `events.export.retention_days` | integer | 7 | Retention age in days (1..90); older records are trimmed. Read at boot. |
| `events.export.retention_max_events` | integer | 50000 | Maximum retained records (1000..1000000); the first retention bound reached applies. Read at boot. |
[Read this section](./configuration-daemon#events).

## upgrade

[Read this section](./configuration-daemon#upgrade).

## alerts

[Read this section](./configuration-daemon#alerts).

## usage

[Read this section](./configuration-daemon#usage).

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
