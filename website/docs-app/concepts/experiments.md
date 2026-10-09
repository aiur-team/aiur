# Experiments

Experiments record a hypothesis, comparison design, metrics and expected directions.
A **before/after** experiment names a change line (`type`, `ref`, UTC `time`);
an **A/B** experiment names at least two cohorts and a control cohort.

Cohort predicates use `eq`, `neq`, `in`, `prefix`, `exists`, `all`, `any` and `not`
over recorded attributes such as backend, model, complexity or `tags.team`.

Create and inspect experiments through the running daemon:

```bash
aiur experiments create --title "Delivery change" \
  --line manual:delivery@2026-10-09T00:00:00Z \
  --metric delivery-speed/start_to_merge:decrease --draft
aiur experiments list --json
aiur experiments show <id> --json
aiur experiments create --from spec.json
cat spec.json | aiur experiments create --from -
```

Specs include owner, hypothesis, origin, metrics, minimum sample counts,
windows, filters, stratification keys, tags and notes. Before/after windows
default to 14 days before the change and an open-ended window after it.
The default minimum is 15 samples per arm.

Metric references are checked for
syntax; metric packs and baseline freezing arrive separately. Creation reports
that the baseline was not frozen when freezing is unavailable in this build.

Stored statuses are `draft`, `active`, `concluded` and `abandoned`.
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
`experiments.metric_packs`; unsupported metric packs report `not_installed`.
