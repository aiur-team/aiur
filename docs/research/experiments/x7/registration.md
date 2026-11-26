# Register the optimistic-start experiment

The reviewed X2 fixtures are `.aiur/experiments/optimistic-start.json` (A/B)
and `.aiur/experiments/optimistic-start-default-path.json` (context line).
Both start as drafts with no enrolled queues. This preserves the decided
protocol without enrolling existing traffic or pretending an empty control
arm is a trial. No post-period results were read to author these fixtures.

The fixture's `notes` carry the complete protocol because X2 v1 has no fields
for metric roles beyond `primary`, stop rules, cluster bootstrap or a second
design. The companion is a real before/after spec; it does not replace the
A/B verdict. [Merge evidence](feature-line.json) resolves its line to
2026-10-14T07:39:25Z, the last sub-issue PR merge (#4368 for #3762), rather
than the later epic closure. While an epic is open, leave its marker pending
and do not create a line with an invented timestamp.

## Frozen source

`baseline-2026-10-09/baseline.json.gz` is a lossless gzip copy of the original
761-line `baseline.json` on `research/refactor-findings`. Compression preserves
the original bytes while respecting the repository's 500-line text-file gate.
The decompressed source SHA-256 is:

```text
e88e475b38f1abf9ec2f70016453129904b2357f668290b21fd8991da1cde4cb
```

The gap summary is n=27, median 0.775 hours (display 0.78 h). Import it as
summary-only evidence. Do not reconstruct rows from the median or recompute
from retained telemetry. The import keeps the entire original source and
verifies its hash; unavailable raw observations remain unavailable.

## Executor commands

Run after the consumer pack is available in the daemon's default-branch base
checkout. Check `aiur experiments metrics --json` for the `optimistic-start`
pack first. Use the running Executor instance; these are not instructions to
launch an agent sandbox or reset test tickets.

Stage the decompressed source in private scratch and verify its digest before
creating the two specs. If either ID already exists, reconcile its registration
and audit history first; do not overwrite it or silently re-import a revision.

```bash
gzip -dc docs/research/experiments/x7/baseline-2026-10-09/baseline.json.gz > "$TMPDIR/optimistic-start-baseline.json"
sha256sum "$TMPDIR/optimistic-start-baseline.json"
aiur experiments create --from .aiur/experiments/optimistic-start.json --no-freeze
aiur experiments create --from .aiur/experiments/optimistic-start-default-path.json --no-freeze
aiur experiments import-baseline optimistic-start --source "$TMPDIR/optimistic-start-baseline.json" --sha256 e88e475b38f1abf9ec2f70016453129904b2357f668290b21fd8991da1cde4cb --metric optimistic-start/blocker_merge_to_dependent_start
aiur experiments import-baseline optimistic-start-default-path --source "$TMPDIR/optimistic-start-baseline.json" --sha256 e88e475b38f1abf9ec2f70016453129904b2357f668290b21fd8991da1cde4cb --metric optimistic-start/blocker_merge_to_dependent_start
```

The import response shows `n=27, median=0.78 h` and the source SHA. It is a
baseline-only response, suitable for verification without opening post-period
results. Do not use the outcome-bearing `show` in a blind live registration.
Local integration tests may use `show` against their isolated synthetic store.

## Before enrollment

Follow [arm setup](arm-setup.md) on a future unstarted graph. The recorded
dry run has empty control and cannot enroll. Record actual queue IDs, seed,
generator version, graph revision and components in an audited amendment;
the empty `queue_id in []` selectors intentionally select nothing until then.

The consumer pack declares the missing derived metrics using NDJSON observation
sources. It does not invent a telemetry producer or create empty measurement
files. Missing source files report unavailable. Before enrollment, supply
observations with the pack's formulas, units and eligibility tags, including
`late_linked`, `gate_shape` and `graph_component`, plus queue identity and start
trigger. Period observations also need queue attribution; pooled fleet capacity
is context, not independent per-arm samples. All durations use hours and the
signed gap retains negative values. Built-in observations lack the eligibility
or queue attributes required here, and the built-in gap drops negative values.

The fixed 20 minimum / 40 target and one-third effect come from the original
decision and frozen power study. A full X6 analyst registration additionally
requires a baseline-only X4 power/readiness plan. The current analyst workflow
documents that capability as unavailable; do not manufacture a readiness date
or claim these draft X2 specs are an accepted X6 analyst registration.
