# Experiments

Experiments record a hypothesis, comparison design, metrics and expected directions.
A **before/after** experiment names a change line (`type`, `ref`, UTC `time`);
an **A/B** experiment names at least two cohorts and a control cohort.

Cohort predicates use `eq`, `neq`, `in`, `prefix`, `exists`, `all`, `any` and `not`
over recorded attributes such as backend, model, complexity or `tags.team`.

Load the consumer pack below, then create and inspect experiments through the daemon:

```bash
aiur experiments create --title "Delivery change" \
  --line manual:delivery@2026-10-09T00:00:00Z \
  --metric app/deploy_latency:decrease --draft
aiur experiments list --json
aiur experiments show <id> --json
aiur experiments create --from spec.json
cat spec.json | aiur experiments create --from -
```

Specs include owner, hypothesis, origin, metrics, minimum sample counts,
windows, filters, stratification keys, tags and notes. Before/after windows
default to 14 days before the change and an open-ended window after it.
The default minimum is 15 samples per arm.

Creation and metric amendments reject references absent from the catalog. Stored
specs remain readable if a pack disappears; evaluation reports those metrics as
`unavailable`.

Before/after creation freezes the before window immediately;
`--no-freeze` opts out. Creation prints its window, observation count and
per-metric coverage; JSON includes `frozen_snapshot`. A refused baseline leaves
no new experiment, so the same ID can be retried.

Stored statuses are `draft`, `active`, `report_due`, `reported`, `cancelled`,
`concluded` and `abandoned`. Drafts do
not register automatically when the change time passes.

The phase is derived from the change time and window end: `awaiting_change`,
`collecting` or `window_closed`. A deterministic optional `key` makes repeated
creation return the existing experiment.

The state node at `~/.aiur/repo/<owner>/<repo>/experiments/<id>/` holds
`spec.json`, append-only `journal.ndjson`, `annotations.ndjson` and `report/`.
The root `index.json` is a rebuildable cache. One daemon process serializes
writes; reads access the files directly. Corrupt specs appear as unreadable
rows without hiding other experiments.

Evaluation runs separately, with one
job at a time and a two-minute deadline. Concurrent evaluations return
`evaluation_busy`; retry after the current job finishes. Amendments remain
available, but invalidate any prepared evidence based on the old spec.

Files carry `schema_version`. Readers upgrade the previous version; specs from
a newer version remain readable and all edits are refused. `registered_at`
records pre-registration. Later edits remain allowed and journal their field
diff with `post_registration: true`; annotations preserve deploys, confounders,
excluded units and notes.

Set [`experiments.enabled`](../reference/configuration#experiments) to false
to disable the writer. The capability report exposes `experiments` and
`experiments.metric_packs`. Invalid pack files report `degraded/pack_invalid`;
other packs remain usable. Disabling experiments reports `unavailable/disabled`.

Store failures leave the daemon running and report the experiments store as
unavailable; writes return the storage failure while disk reads remain usable.
An automatic-worker startup failure is logged; automatic creation remains
unavailable while the daemon continues.


## Baselines and retention

Frozen windows preserve raw per-unit observations, coverage, summaries and pack
definition hashes in `snapshots/<window>.r<N>.json`, independently of telemetry
retention and regenerable run summaries. Files are read-only and journaled;
reads verify their SHA-256. Tampered evidence is refused without live fallback.

`aiur experiments freeze <id>` defaults to `before` for before/after and
`observation` for A/B. Use `--window after` to freeze the after window, or
`--reason "updated baseline"` to add a revision; previous revisions remain.

The observation limit (50,000 by default) refuses excess data without truncation.
Open duration units are censored observations with their elapsed value.

The hourly checkpointer preserves finished after-window units idempotently.
For a future change it re-freezes the baseline at the change time, and freezes
the after window when it closes. Checkpoints refuse excess observations, record
`checkpoint_limit_reached` once, and stop evaluating that window.
`show` lists revisions, counts and coverage.

Arm assignment prefers frozen data, then checkpoints, then live evaluation.
Before/after straddlers are excluded by default; `assign_by: finish` assigns
by finish time. Cohort assignment counts filtered and ambiguous units.

`export_analysis_input/1` writes `report/analysis-input.json` with assigned
per-unit rows and a stable `input_sha256`; this is the statistics engine's input.


## Metric packs

Run `aiur experiments metrics --json` to inspect definitions and pack problems.
Built-in packs implement `Aiur.Experiments.MetricPack` and are registered with
`:experiment_metric_packs`.

The built-in `delivery-speed` pack is enabled by default. Disable it with
`experiments.disabled_packs: [delivery-speed]`; its definitions then disappear
from the catalog. Consumer packs can supply application-specific metrics.

Consumer packs are tracked JSON files under
`.aiur/experiments/packs/` in the default-branch base checkout. An agent branch
cannot alter the catalog.

Pack ids cannot shadow built-ins, including
`delivery-speed`. `experiments.pack_dirs` changes the directories and
`experiments.disabled_packs` removes packs from the catalog.

Each metric declares its label, unit, unit of analysis, kind (`duration`,
`count`, `binary`, `rate` or `bucketed`), preferred direction, group and
required capture facts.

Sources are `event_interval` (first start and first
subsequent end per unit), `event_count` (matches per unit or hour/day),
`ndjson` (observation lines in a contained path), or `script` (an argv command).

NDJSON lines use `unit_id`, numeric `value`, ISO-8601 `at` and optional `attrs`.
A `state:` path resolves inside the repository state node; other paths resolve
inside the base checkout.

The following consumer pack measures deployment duration and invokes the
application's own measurement script. Save it as `.aiur/experiments/packs/app.json`:

<!-- consumer-pack-example -->
```json
{
  "schema_version": 1,
  "id": "app",
  "version": "1",
  "metrics": [
    {
      "id": "deploy_latency",
      "label": "Deployment latency",
      "description": "Time from deployment start to completion",
      "unit": "ms",
      "unit_of_analysis": "deployment",
      "kind": "duration",
      "better": "lower",
      "default_direction": "decrease",
      "group": "Deployments",
      "requires": [],
      "source": {
        "kind": "event_interval",
        "start": "executor.app.deploy.started",
        "end": "executor.app.deploy.finished",
        "unit_key": "/deployment_id",
        "attrs": {"branch": "/branch"}
      }
    },
    {
      "id": "request_latency",
      "label": "Request latency",
      "description": "Application request latency from its own measurement script",
      "unit": "ms",
      "unit_of_analysis": "request",
      "kind": "duration",
      "better": "lower",
      "default_direction": "decrease",
      "group": "Requests",
      "requires": [],
      "source": {
        "kind": "script",
        "argv": ["/bin/sh", "bin/latency.sh"],
        "cwd": "repo"
      }
    }
  ]
}
```
<!-- /consumer-pack-example -->

Save this measurement script as `bin/latency.sh` in the same base checkout:

```sh
#!/bin/sh
set -eu
printf '{"unit_id":"request-1","value":42,"at":"%s","attrs":{}}\n' "$AIUR_EXPERIMENT_WINDOW_START"
printf '{"unit_id":"request-2","value":57,"at":"%s","attrs":{}}\n' "$AIUR_EXPERIMENT_WINDOW_START"
```

Register the pack before publishing events with the existing Executor command:

```bash
aiur executor-emit executor.app.deploy.started --payload '{"deployment_id":"deploy-1","branch":"main"}'
aiur executor-emit executor.app.deploy.finished --payload '{"deployment_id":"deploy-1","branch":"main"}'
aiur experiments metrics --json
aiur experiments create --title "Deployment change" --line manual:deployment@2026-10-09T00:00:00Z --metric app/deploy_latency:decrease --draft
```

Capture journals only each metric's declared unit and scalar attributes, never
whole event payloads. Monthly journals live in `experiments/capture/` and keep
at least 365 days plus the history needed by active experiment windows.
Packs reload within a minute; changing an event metric or restarting capture
begins a new conservative coverage interval.

When Capture has 1,024 queued messages, it drops incoming events and marks
matching metrics `unavailable` with `capture_overloaded`. Those metrics stop
appending until Capture restarts or the metric is removed and registered again.

Journal failures also stop further appends for the affected metric. Metadata
is written only when its state changes, including one attempt per failure state.
An Exchange outage reports `unavailable`; after the Exchange recovers, the next
pack reload resubscribes and begins a new coverage interval.

Evaluation reads only the journal months overlapping its window. An invalid
line (including a torn final write after a crash) makes overlapping windows
`unavailable/capture_corrupt`; other months remain usable.

To repair a journal, stop Aiur, back up the affected `events-YYYY-MM.ndjson`, and restore the damaged
line from its source. If the observation cannot be recovered, retain the damaged
file: deleting the line would turn missing evidence into apparently complete
capture. Restart Aiur after repair.

Coverage is separate from sample count: `captured` permits zero observations;
`partial` reports `covered_from`; `not_captured` identifies missing capture or
required facts; `unavailable` identifies failed sources. Missing data is never
reported as zero. Hour/day counts fill empty buckets only with full capture.

Scripts run from the base checkout with argv and no implicit shell, a default
60-second timeout (`experiments.script_timeout_ms`) and an 8 MB output limit.
They receive `AIUR_EXPERIMENT_WINDOW_START`, `AIUR_EXPERIMENT_WINDOW_END` and
`AIUR_EXPERIMENT_METRIC`.

GitHub, provider and supervisor credentials are
removed from their environment. Timeout, nonzero exit and excess output report
`unavailable` with a reason.

Repository-owned scripts have the same trust level
as hooks; they are not sandboxed against filesystem access.

Stdout and stderr share the bounded script stream. A nonzero exit reports the
first non-JSON diagnostic line; this can be a stdout diagnostic if one precedes
stderr.

## When the report is written

The window manager evaluates every active before/after experiment, manual or
automatic, hourly and once after a ten-minute burst of merged-PR events.
`active` is the collecting state. Cohort experiments are left to the analyst.
This manager runs even when automatic line creation is disabled.

After at least `experiments.auto.after_days` (14 by default), a met X4 sample
guard moves the experiment to `report_due` with `report_reason: guard_met`.

If the guard is unmet at the window end, the end extends by `after_step_days`
(7), clamped to `after_max_days` (42). At that maximum it becomes `report_due`
with `insufficient_data`.

A missing or unavailable X4 guard counts as unmet;
no statistical result is invented. Open-ended manual windows use the same limits.

Line sources call `Aiur.Experiments.Auto.truncate(id, at, reason)` on a newer
line or rollback. Truncation closes the after window at that time (never
lengthening it), with reason `guard_met` if the guard is met, otherwise
`truncated`. The caller's cause is kept in the journal.

Terminal experiments
are left unchanged. The analyst owns writing the report and marking it `reported`.

The Executor receives `system.experiment.<id>.preregister`, `.report_due` and
`.cancelled` wakes under `experiments:auto`. Payloads contain only the experiment
identifier, reason and line source. Dots in a topic's experiment identifier are
encoded as `%2E`; the payload keeps the original ID.

`experiments/auto-latches.json` is persisted before publication: a crash can
miss a wake, but cannot repeat one. A failed latch write publishes nothing and
is retried on evaluation. Corrupt latches disable notifications and report
`degraded` through the notifier status; the file is preserved for recovery.

## Automatic experiments

`experiments.auto` configures version, release and feature lines. The deploy
ledger records each recording daemon boot at `experiments/deploys.ndjson` under
the repository state node. It retains the latest 5,000 boots, including version,
base semver, boot time and build-stamp SHA and dirty flag when available.

Missing build evidence stays null. Deploys alone never create experiments.
Automatic line creation uses the experiment store's baseline-freezing transaction.
Repeated keys create neither another experiment nor another baseline; completion
receipts survive restarts. Concurrent lines annotate other open windows once.

Read-only experiments are left unchanged and log one warning per Creator lifetime while new lines still complete.

With telemetry disabled, a line creates nothing and logs its skip once per key.
If automatic experiment storage cannot start, Aiur logs its unavailability and
continues running.

The default auto pack name `delivery` refers to the built-in `delivery-speed`
pack. Other names select consumer packs. Missing or disabled packs return an
availability error rather than creating an experiment without metrics.

### Measuring a feature
Tag a parent with `experiment:feature` (`experiments.auto.feature_label`). Hourly
polls and webhook deposits arm `auto:feature:<number>`, freeze its baseline, and
request pre-registration. Leaves report `not_an_epic`. Armed experiments stay draft.
The first merge ends and refreezes the baseline; late tagging marks it `partial`.
Rollout from first merge to live is excluded. All members must close, at least one
must merge, and nothing may change for `feature_quiet_hours` (6). Members refresh
hourly or sooner after merges, bounded to five minutes. The first 100 are supported
(`member_limit`); cross-repo and completed members without merged PRs are excluded.
`feature_live_signal: auto` uses a containing daemon build for the managed repo,
otherwise merge time. Explicit `daemon_boot` rejects unknown SHAs; `release` waits
for a containing tag. After `live_signal_max_wait_hours` (72), merge-time fallback
carries `live_signal_fallback`. All-excluded members or label removal cancel once
before the line. After it, the line stays fixed. State and latches survive restarts.
### Version and release lines

At boot, after recording the deploy ledger, Aiur compares base semver with the
previous boot. A higher version creates `auto:version:<x.y.z>` at boot time and
freezes its baseline immediately, clipped at the start of the previous version.

Repeated restarts, nightly suffix changes, unknown versions and the first boot
create nothing. A downgrade truncates the open version experiment's after
window and adds a rollback annotation.

Failed version creation retries during the boot and after later same-version
restarts, preserving the original line time. Telemetry-skipped lines stay skipped.

Release detection runs at boot and hourly using `git ls-remote --tags --refs
origin` in the warm clone, with the same credentials as its fetch. The first
successful census marks existing tags seen without creating experiments.

New
semver tags matching `experiments.auto.release_tag_pattern` are fetched; the
line uses the tagger date, or commit date for a lightweight tag. Prereleases
are skipped unless `release_include_prereleases` is true, and tags older than
14 days at detection are ignored.

Failed remote reads leave seen state unchanged
and retry on the next tick; a missing warm clone reports unavailable.

Tags less than `release_min_interval_days` (default 7) after a release line
annotate that experiment.

A version and tag with the same base semver within
14 days share one experiment, in either detection order; the second source is
attached as evidence. These receipts and seen tags survive daemon restarts.

`version_line: false` or `release_line: false` disables the corresponding source.
Release lines also select consumer packs with top-level `"auto": true` in their
pack JSON, alongside the configured metric packs.

## Delivery-speed metrics

The pack exposes these delivery metrics.

| Group | Metric | Kind | Definition |
| --- | --- | --- | --- |
| flow | `start_to_pr_open` | duration | First dispatch to first source-timed PR open, in ms. |
| flow | `pr_open_to_merge` | duration | First source-timed PR open to merge, in ms. |
| flow | `start_to_merge` | duration | First dispatch to merge, in ms. |
| flow | `blocker_merge_to_dependent_start` | duration | Last blocker merge to first dependent dispatch, in ms. |
| flow | `gap_between_prs` | duration | Previous merge in the same epic to this ticket's merge, in ms. |
| review | `pr_ready_to_first_review` | duration | Source-timed PR open to first trusted review-thread comment, in ms. |
| review | `review_rounds` | count | Review-pause starts/points before merge. |
| review | `rework_time` | duration | Sum of rework starts to next PR open or merge, in ms. |
| review | `ci_wait` | duration | Sum of CI pending spans before merge, in ms; not captured yet. |
| throughput | `merged_per_hour` | bucketed | Merges in each hour with measured active agents, including zero merges. |
| throughput | `agents_vs_cap` | bucketed | Time-weighted running agents / configured cap in those hours. |
| throughput | `idle_slot_hours` | bucketed | Idle slots × hours while ready work exists; not captured yet. |
| throughput | `binding_gate` | rate | Dispatch-held share by gate; not captured yet. |
| cost_quality | `spend_per_merged_ticket` | count | Ticket-attributed provider-reported estimate in USD. |
| cost_quality | `tokens_per_merged_ticket` | count | Ticket-attributed input and output tokens, including cache/reasoning. |
| cost_quality | `main_red_events` | bucketed | Default-branch CI failures per day; not captured yet. |
| cost_quality | `reverts` | bucketed | Revert merges per day; not captured yet. |

Durations, counts and spend prefer lower values; throughput and utilization
prefer higher values. `binding_gate` has no preferred direction. Every metric
reference begins with `delivery-speed/`.

Ticket units are `ticket:<number>`, assigned at first dispatch, with complexity
and dispatch-time cohort attributes. Redispatch and restarts create no second
unit. Merge, review-round and cost metrics exclude unmerged tickets (`filtered`).

`finished_at` and `censored` are observation attributes. Open PR/review durations
are censored at window end. Missing PR-open evidence on merged tickets is
excluded and reports partial capture, never a censored open ticket.

`not_captured` means a required capture fact is absent, with no observations.
It never means zero. Legacy data may lack source PR times, dispatch blockers/epic
or review-thread evidence. CI wait, ready-queue depth, gate reason, main-red and
revert facts remain uncaptured; lifecycle labels are not substitutes.

Disabled telemetry reports `unavailable/telemetry_disabled`; missing telemetry
reports `unavailable/telemetry_missing`. Corrupt summaries and fleet sample gaps report `partial`.

Experiment telemetry uses one streaming reader for JSON summaries and live NDJSON.
Callers that supply known boot intervals can skip non-overlapping sources before
opening.

The delivery pack has no boot-range index and does not claim this
optimization: it reads retained summaries independently and caches each small
projection by path, size and modification time. Live data is not cached.

Earlier lifecycle and fleet evidence preserves first dispatch and prerequisite
merges. A large or incomplete boot cannot exhaust another boot's read budget.
Truncated boot prefixes remain usable within the memory bound and report `partial`;
complete summaries and live observations remain available.

Each retained summary has its own limits: 100,000 record envelopes, 32 MiB input
and a 4 MiB projection, plus 1 MiB tokens and 16 nesting levels. Derived actor/ticket maps are discarded after fleet samples are extracted.

The merged retained projection is also capped at 4 MiB; complete boot projections take precedence over truncated prefixes if the
memory bound is reached. Overflow omits excess data and marks coverage partial. The cache holds at most 64 entries and 24 MiB.

A truncated live read reports `unavailable/truncated` with no observations.
Bounds never turn an incomplete population into a measured zero.

Live and retained actor samples hold for at most five seconds. Only measured
hours with active agents produce period observations; `observed_ms` records
the measured portion of each hour. Thinned summary samples are not stretched
over gaps.

Cost evaluation resolves merged-ticket identities through the tracker and
queries the usage aggregate. Missing accounting, identities or measures report
`unavailable`, or `partial` when other tickets have observations.

Token totals use the pinned provider relationship registry to avoid counting
cache and reasoning subsets twice. Unknown revisions are unavailable. Missing
USD spend is not replaced with another currency or zero. Stale or unhealthy
accounting is unavailable; changing aggregate generations cannot be mixed.

## Confounder sources

`aiur experiments events <id> --json` collects window events, the gap between
windows and a 24-hour margin before each window. It freezes `events-1.ndjson`.
Later reads reuse it; `--refresh` appends a new file with stable event IDs.
Changing windows or source settings also starts a new snapshot.

Results include `events`, `snapshot_hash`, `snapshot` and `incomplete_sources`.
NDJSON starts with snapshot metadata followed by event rows. Titles are
untrusted data truncated to 200 characters. Analysts classify every event ID
and pin the snapshot hash.

The collector uses these sources:

| Event | Evidence |
| --- | --- |
| `merged_pr` | Base-branch merges, labels, first 50 changed paths and closing issues' parent epic IDs. |
| `release` | Published GitHub releases and dated tags. |
| `version_change`, `config_change` | Run-context transitions; config section hashes identify changed section names. |
| `incident` | Critical persisted alerts and incident-labelled issues, including overlapping open incidents. |
| `outage` | Consecutive boot records more than ten minutes apart; raw telemetry supplements summaries. |
| `main_red` | Required base-branch workflow failures through the next success, per workflow. |
| `capacity_change` | Max or effective cap changes held at least fifteen minutes; brief blips are ignored. |
| `global_pause` | Effective capacity dropping to zero through recovery. |

Boot gaps describe restart separation, not measured downtime. Capacity and
pause spans use sampler observations. Missing or expired telemetry cannot
prove a complete history and is marked incomplete when it does not cover the
start of the requested range.

Missing sources produce a stderr warning; the command exits zero with usable
evidence. Filesystem errors when freezing fail the command. GitHub reads are
capped at ten pages per connection; reaching the cap marks GitHub incomplete.
Frozen reads are local; refresh uses the [quota-accounted transport](../apis/github).

Consumer specs may include this optional object:

```json
"confounder_sources": {
  "base_branch": "main",
  "required_workflows": ["CI"],
  "incident_labels": ["incident", "outage"]
}
```

The branch defaults to the tracker's configured branch; incident labels default
to `incident` and `outage`. Set required workflow names explicitly; without a
selection, `main_red` is incomplete. An unresolved red span has null `to`.

Events carry `before`, `after`, `between`, `margin`, or `observation` for an A/B
observation window.

Collection runs in a supervised task with a two-minute timeout. Headers expose
`collected_at` and the collected `range` in human and JSON output. Open windows
remain frozen at that horizon until `--refresh`; collection time does not enter
the input hash, while the observed range does.

Each snapshot keeps at most 5,000 events and 4 MiB, marking capped sources
incomplete. An experiment permits 32 immutable event snapshots; further refreshes
are refused rather than deleting evidence pinned by reports. Existing oversized
snapshots are retained but refused by the bounded reader.

Alert collection streams at most 8 MiB and keeps at most 5,000 critical records.
Oversized lines (over 256 KiB), partial reads and caps mark alerts incomplete.

Telemetry uses the shared windowed reader: 32 MiB scanned, 10,000 records and
4 MiB retained across sources. Known outside ranges are skipped. Retained boots
without a range index remain eligible; missing, malformed or truncated evidence
marks telemetry incomplete instead of implying a complete history.
