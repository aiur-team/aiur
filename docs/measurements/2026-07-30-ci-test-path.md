# CI test-path measurements — #1378

This record keeps the test-path optimization loop reproducible. Durations are
the full GitHub Actions merge-blocking path: from the first coverage partition
starting until the `test` job completes tmux regression. The coverage gate
aggregates all four partition exports before the regression job can run, so it
still measures repository-wide coverage against the 85% threshold.

## Method

- Run the unchanged baseline three times in GitHub Actions; do not run the
  full suite locally.
- Change one lever at a time, then compare the same job path with the
  immediately preceding measurement.
- Keep the 85% coverage gate required for every pull request.
- Re-run the final configuration to check for flakes.

## Measurements

| Run | Ref | Lever | Test-path wall-clock | Delta vs. baseline median | Result |
| --- | --- | --- | ---: | ---: | --- |
| Historical context | `1ca020f8` | Pre-change successful develop run | 12m 59s | — | passed |
| Baseline 1 | [30560138566](https://github.com/aiur-team/aiur/actions/runs/30560138566) | Unchanged test path | 11m 44s | -32s | passed (85.01% coverage) |
| Baseline 2 | [30560153518](https://github.com/aiur-team/aiur/actions/runs/30560153518) | Unchanged test path | 13m 05s | +49s | passed (85.02% coverage) |
| Baseline 3 | [30560180283](https://github.com/aiur-team/aiur/actions/runs/30560180283) | Unchanged test path | 12m 16s | 0s | passed (85.02% coverage) |
| Sharding coverage 1 | [30560522121](https://github.com/aiur-team/aiur/actions/runs/30560522121) | 4-way partitioned coverage + aggregation | n/a | n/a | rejected: aggregate coverage below 85% |
| Sharding coverage 2 | [30561142819](https://github.com/aiur-team/aiur/actions/runs/30561142819) | Fail-closed export validation | n/a | n/a | rejected: aggregate coverage 84.97% |
| Sharding coverage 3 | [30562961337](https://github.com/aiur-team/aiur/actions/runs/30562961337) | Deterministic seed | n/a | n/a | rejected: aggregate coverage 84.96% |
| Sharding coverage 4 | [30563044432](https://github.com/aiur-team/aiur/actions/runs/30563044432) | Repeat deterministic seed | n/a | n/a | rejected: aggregate coverage 84.94% |
| Plain sharding + serial coverage | [30564536867](https://github.com/aiur-team/aiur/actions/runs/30564536867) | Plain partitions alongside a separate full coverage run | 5m 00s plain test path; 13m 15s coverage | n/a | rejected: merge-blocking coverage path stayed serial and the suite ran twice |
| Coverage margin validation | [30568674588](https://github.com/aiur-team/aiur/actions/runs/30568674588) | Add stable scheduled-path tests before retrying partitioned coverage | 12m 37s serial coverage | +21s | coverage passed at 85.09%; workflow invalid for stability because an unrelated AppServer partition flaked |
| Final configuration | [30569993184](https://github.com/aiur-team/aiur/actions/runs/30569993184) | 4-way coverage partitions + merged 85% gate | 7m 15s | -5m 01s | passed; 85% gate intact |
| Final stability 1 | pending | Repeat final configuration after setup deduplication | pending | pending | pending |
| Final stability 2 | pending | Repeat final configuration unchanged | pending | pending | pending |

Baseline median: **12m 16s**.

## Interpretation notes

The historical row is context only, not a substitute for the three committed
baseline runs. The four rejected coverage-partition trials demonstrate that
the full suite's aggregate coverage is slightly lower when partitioned; the
threshold was not changed. The rejected plain-sharding trial made only an
optional path faster, so the final configuration instead runs the suite once
with coverage enabled in four partitions, verifies every export is present, and
merges them before applying the single repository-wide threshold. A final run
is accepted only when all four coverage partitions, the merged 85% gate, and
the regression job pass.
