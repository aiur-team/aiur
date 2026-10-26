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
| Key | Type | Default | Controls | <!-- generated-reference:config-configuration-00 -->
| --- | --- | --- | --- |
| `debug` | boolean | false | Enables debug-level file logging without the CLI debug flag; background runs already retain normal-level logs. |
| `executor_takeover_continuous_alert_hours` | integer | 1 | Repeated takeover advisory cadence in hours after the first; `0` disables repeats. |
| `executor_takeover_first_alert_hours` | integer | 8 | First Executor takeover advisory threshold in hours; `0` disables. |
| `hooks_file` | file pointer | none | Sibling YAML file merged as the `hooks:` block. |
| `instance.deployment_kind` | string | `operator` | Selects credential owner. Hosted operators may use subscriptions; consumers use API keys only. |
| `instance.id` | string | host and state directory | Stable id used by the shared multi-instance coordination store; read once at boot. Set `AIUR_LEASE_DATABASE_URL` to the same TLS PostgreSQL URL on each instance to enable shared ticket claims, repository leader election, and live-instance heartbeats. Remote certificates must chain to system CA roots; configured-store failures block new dispatch and live-instance reads. |
| `instance.ignore.label_prefixes` | array of strings | `[]` | Label prefixes marking tickets another instance owns. A prefix such as `nuc` matches `nuc:*` state labels. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.ignore.labels` | array of strings | `[]` | Exact labels marking tickets another instance owns. If label data is unavailable, ticket-scoped observers skip conservatively. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.ignore.tickets` | array of integers | `[]` | Ticket numbers another instance owns. This daemon does not transition, land, withdraw, alert on, count, or wake its Executor for them; dispatch is unaffected. Hot-reloadable. |
| `instance.mode` | string | `local` | `hosted` adds static startup, reload, and dispatch checks for permission, network, credentials, the effective API-key-only fallback, Remote Control, local panes, and REPL isolation. Authentication for primary routes and account profiles is learned at runtime: unsafe first or later observations fail closed. Claude reauthorizes each action; Codex refuses an unsafe initial account read and later unsafe notifications before subsequent progress, tool calls, or success. Current production backends remain ineligible until #5701. Read once at daemon start; restart to change. |
| `instance.owns` | array of maps | `[]` | Ticket rules reserved for this live instance. Each entry has exactly one `label` or positive `ticket`; matching rules apply only while this instance is dispatching. Requires the shared lease store to coordinate live instances. Hot-reloadable. |
| `instance.pool` | boolean | `true` | Whether this instance may dispatch tickets that no live, dispatching instance reserves with `instance.owns`. Hot-reloadable. |
| `instance.role` | string | `primary` | `secondary` never claims the repository leader lease; `primary` is eligible to lead on equal terms with other eligible instances when `AIUR_LEASE_DATABASE_URL` is configured. Only the lease holder runs repository-wide landing, quarantine, merge-queue, and main-branch work. Label heals remain scoped to each instance's tracker view. Without a shared store, primary retains single-instance behavior. Read once at daemon start; change it with a restart. |
| `instance.roster_stale_retention_ms` | integer | 300000 | How long expired instance heartbeats remain in the dashboard and status roster, in milliseconds. |
| `max_log_history_mb` | integer | 1000 | Caps persistent log history in MB. |
| `max_vertical_panes` | integer | 3 | Caps visible agent chat panes. |
| `pre_warmed_sessions` | integer | 3 | Number of opencode sessions booted early; 0 disables pre-warm. |
| `prompt_file` | string | nil | Per-repository Liquid prompt template. |

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

[Read this section](./configuration-daemon#prewarm).

## pr_watch

[Read this section](./configuration-daemon#pr-watch).

## pr_health

[Read this section](./configuration-daemon#pr-health).

## events

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
Build queue configuration for GitHub workflows (Linear is unsupported); the daemon reconciles stored queue membership after tracker signals or on the configured interval, with a two-second debounce.
| Key | Type | Default | Description | <!-- generated-reference:config-configuration-21 -->
| --- | --- | --- | --- |
| `build_queue.enabled` | boolean | true | Enable build queue reconciliation. The server maintains dispatch hints, promotes ready items, and withdraws todo from unclaimed items whose prerequisites change. Disabling the queue removes its server and hints table on the next run. |
| `build_queue.max_active_sets` | integer or null | nil | Maximum sets with started, unfinished members (including CI/review waits); minimum 1. Null lets capacity decide. Held sets do not consume this cap; existing runners are never preempted. |
| `build_queue.max_writes_per_minute` | integer | 20 | Queue write budget per minute; 1..60. |
| `build_queue.merged_open_grace_seconds` | integer | 600 | Grace period in seconds for an `issue_closed` queue prerequisite whose PR merged but issue remains open; 60..86400. |
| `build_queue.observation_max_age_seconds` | integer or null | derived (2× polling.interval_seconds) | Maximum observation age in seconds; null derives twice the base poll interval (240 seconds by default); explicit values must be 10..3600. A non-empty queue whose open-issue snapshot is older than this lists open issues itself, at most once per this age. |
| `build_queue.optimistic_churn_attention_threshold` | integer | 3 | Conflicting integrations before an informational attention; 0 disables, 0..50. Never pauses work. |
| `build_queue.optimistic_failure_grace_seconds` | integer | 600 | Seconds to wait for a reopened or replacement blocker PR before parking optimistic dependents; 60..86400. |
| `build_queue.optimistic_slot_share` | float | 0.5 | Fleet-wide optimistic share, 0..1. Zero disables optimistic dispatch; otherwise the cap is max(1, floor(share × effective agent limit)). Ready work starts first; merged blockers free share on the next cycle. Running agents are never preempted. |
| `build_queue.reconcile_interval_seconds` | integer | 60 | Reconciliation interval in seconds; 10..3600. |
| `build_queue.set_order` | string | `none` | `none` preserves ordinary candidate ordering. Opt into `ranked` to prefer queue sets by persisted rank (creation order by default); ready members follow list position, while optimistic members retain deepest-first ordering within each set. Ready work always precedes optimistic work. With a cap or reserve configured, earlier unknown or stale readiness blocks ranked spill because it may have ready work. Held sets remain stopped. Main CI fixer tickets dispatch ahead of ranked sets. |
| `build_queue.spill_reserve_slots` | integer | 0 | Slots kept free for the earliest unfinished, unheld set before admitting later-set work; minimum 0. Reserve applies even while that set waits on review. Set-policy waits appear as `queue_set_order` in status and queue show. |
| `build_queue.start_trigger` | string | `pr_merged` | Prerequisite stage needed for queue promotion: `issue_closed`, `pr_merged`, `pr_approved`, `pr_ci_green`, or `pr_opened`. Also governs native dependency dispatch. Override with `queue add --start-on` or `queue set NAME --start-on`; `default` follows config. Missing or stale evidence never releases dependents. Optimistic stages combine lifecycle labels with retained per-PR progress. `pr_approved` adds one conditional review read per watched blocker. Linear dependency dispatch supports only `issue_closed` and `pr_merged`. See [Start trigger](/concepts/build-orders#start-trigger). |

[Read this section](./configuration-daemon#build-queue).

## Further sections

[Read this section](./configuration-daemon#further-sections).
