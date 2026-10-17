# Worked reports and frozen evidence

These synthetic examples adapt EXP-X6-3's `report.valid.json` golden fixture.
Numbers are copied from that fixture, never recomputed by the analyst. Each
`.evidence.json` is the separate frozen validator context; it is not generated
from the report during validation. Fixture hashes identify illustrative data,
not live runs. Metric ids and units belong to this fixture pack.

- `report.feature.json`: before/after feature comparison; a cap drop from 8
  to 4 is high/noted and forces the primary modifier `confounded`. The red
  interval is still in the ledger, with an explanation for no affected metric.
  Missing sensitivity capability leads to redesign, not a causal claim.
- `report.cohorts.json`: Claude/Codex comparison at 40 of 60 planned tickets
  per cohort. Backend is the treatment; missing model and size balance remains
  a selection threat. The interim report cannot justify a backend preference.

Both documents validate unchanged against their separate evidence snapshots.
The report renderer produces Markdown from each JSON document. To use their
shape, replace all fixture evidence with the current engine and event snapshots;
never submit these fixture values for a live experiment.
