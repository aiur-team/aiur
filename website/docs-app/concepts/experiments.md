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
`unavailable`. Creation reports when baseline freezing is unavailable.

Stored statuses are `draft`, `active`, `concluded` and `abandoned`. Drafts do
not register automatically when the change time passes.
The phase is derived from the change time and window end: `awaiting_change`,
`collecting` or `window_closed`. A deterministic optional `key` makes repeated
creation return the existing experiment.

The state node at `~/.aiur/repo/<owner>/<repo>/experiments/<id>/` holds
`spec.json`, append-only `journal.ndjson`, `annotations.ndjson` and `report/`.
The root `index.json` is a rebuildable cache. One daemon process serializes
writes; reads access the files directly. Corrupt specs appear as unreadable
rows without hiding other experiments.

Files carry `schema_version`. Readers upgrade the previous version; specs from
a newer version remain readable and all edits are refused. `registered_at`
records pre-registration. Later edits remain allowed and journal their field
diff with `post_registration: true`; annotations preserve deploys, confounders,
excluded units and notes.

Set [`experiments.enabled`](../reference/configuration#experiments) to false
to disable the writer. The capability report exposes `experiments` and
`experiments.metric_packs`. Invalid pack files report `degraded/pack_invalid`;
other packs remain usable. Disabling experiments reports `unavailable/disabled`.

Storage failures leave the daemon running and report the experiments store as
unavailable; writes return the storage failure while disk reads remain usable.


## Metric packs

Run `aiur experiments metrics --json` to inspect definitions and pack problems.
Built-in packs implement `Aiur.Experiments.MetricPack` and are registered with
`:experiment_metric_packs`.

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
