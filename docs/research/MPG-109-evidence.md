# MPG-109 evidence: two daemons, one repository

**Status: not run.** The three live runs need PC and Nook deployed with `instance.ownership: github` and a shared
Postgres, which an issue workspace cannot do. Nothing below is a result; fill each section from the Executor's run.
Runbook and pass criteria: [`MPG-109.md`](MPG-109.md). Counters: `scripts/acceptance/mpg-109-count-duplicates.sh`
(`bash scripts/acceptance/mpg-109-count-duplicates.test.sh` runs T1-T4).

Per run record: `T0`/`T1`/`T_stop` (UTC), the commands, `rows-*.tsv` line counts, the outputs of `overlaps`,
`same-overlaps`, `refs`, `prs`, the workload table, `aiur ticket owner` samples, verdict. Redact URLs, IPs, token ids,
`gateway_id` values and Postgres URLs. Pass = duplicates 0 by all counts and >= 6 tickets dispatched, >= 2 per gateway.

## A1: 30-minute simultaneous dispatch (R0, R1, R1b)
Not run.

## A5a: shared Postgres stopped mid-soak (R2, R2b)
Not run.

## A6: Nook daemon stopped (R3, R3b)
Not run.

Run the counters' test with `bash scripts/acceptance/mpg-109-count-duplicates.test.sh` (no CI job runs it).
