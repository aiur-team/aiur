# CI test-path measurements — #1378

This record keeps the test-path optimization loop reproducible. Durations are
the full GitHub Actions test-path critical path: from the first test runner
starting until the aggregate `test` job completes tmux regression. Before
sharding this is the `test` job duration; after sharding it includes the longest
partition plus regression. The unchanged full-suite `coverage` job remains a
separate required PR gate and reports the repository-wide 85% threshold.

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
| Baseline 1 | [30560138566](https://github.com/its-everdred/aiur/actions/runs/30560138566) | Unchanged test path | 11m 44s | -32s | passed (85.01% coverage) |
| Baseline 2 | [30560153518](https://github.com/its-everdred/aiur/actions/runs/30560153518) | Unchanged test path | 13m 05s | +49s | passed (85.02% coverage) |
| Baseline 3 | [30560180283](https://github.com/its-everdred/aiur/actions/runs/30560180283) | Unchanged test path | 12m 16s | 0s | passed (85.02% coverage) |
| Sharding coverage 1 | [30560522121](https://github.com/its-everdred/aiur/actions/runs/30560522121) | 4-way partitioned coverage + aggregation | n/a | n/a | rejected: aggregate coverage below 85% |
| Sharding coverage 2 | [30561142819](https://github.com/its-everdred/aiur/actions/runs/30561142819) | Fail-closed export validation | n/a | n/a | rejected: aggregate coverage 84.97% |
| Sharding coverage 3 | [30562961337](https://github.com/its-everdred/aiur/actions/runs/30562961337) | Deterministic seed | n/a | n/a | rejected: aggregate coverage 84.96% |
| Sharding coverage 4 | [30563044432](https://github.com/its-everdred/aiur/actions/runs/30563044432) | Repeat deterministic seed | n/a | n/a | rejected: aggregate coverage 84.94% |
| Final stability 1 | pending | Final configuration | pending | pending | pending |
| Final stability 2 | pending | Final configuration | pending | pending | pending |

Baseline median: **12m 16s**.

## Interpretation notes

The historical row is context only, not a substitute for the three committed
baseline runs. The four rejected coverage-partition trials demonstrate that
the full suite's aggregate coverage is slightly lower when partitioned; the
threshold was not changed. A final run is accepted only when all four plain
test partitions and the aggregate regression job pass, and the separate full
coverage job reports the single repository-wide coverage threshold.
