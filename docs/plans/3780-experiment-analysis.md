# Experiment analysis driver

Source: EXP-X4-2, `docs/research/experiments/x4/plan-analysis-driver.md` on
`research/refactor-findings`. Scope is the pure Python driver, schema, CLI and methods page.
Censoring, stratification and power remain separately owned follow-on paths.

1. Add strict input normalization, canonical serialization, per-kind inference,
   Holm/BH correction, deterministic labels and numeric summaries. Reuse the
   shipped primitives; orient all effects as B minus A or B/A. Preserve analyst
   annotations, exclusions and provenance. Undefined intervals remain null.
2. Add the atomic experiment-directory CLI, schema and documentation. Verify
   shift/guard/equivalence fixtures, binary/rate routing, multiplicity goldens,
   exclusions and annotations, determinism, tamper detection and invalid inputs
   in `analytics/tests/test_stats_analyze.py`, `test_stats_multiplicity.py`,
   `test_experiment_stats_cmd.py`, `test_experiment_schema.py`.

The current X2 export is flat and references pack metadata rather than embedding
metric kinds. Accept flat rows when explicit metric definitions are supplied;
never infer kinds from Aiur metric names. The CLI's frozen snapshot contract
carries kinds in its metric entries, as specified by the X4 source plan.

Validation: focused stdlib unittest suite; new-test production-revert checks in
an isolated worktree; docs build; required lint and structural gates. Review
zero baselines, ties, absent primaries, post-freeze additions and nonfinite JSON.
