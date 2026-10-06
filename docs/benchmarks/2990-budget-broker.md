# Budget broker contention measurement — #2990

Measured 2026-10-06 with `scripts/benchmark-github-budget.py`, against the
one-shot broker at `55d52ea5e09e713029a075aa79246dba54a87715` and this change.
All state lived in temporary databases; no live credential or ledger was used.

Command (after extracting the baseline script into the ticket's private scratch):

```sh
python3 scripts/benchmark-github-budget.py --baseline "$TMPDIR/budget-baseline-2990.py"
```

Three concurrent writers shared one credential and database, while one CPU
worker ran. Each writer made 100 measured admission calls after two warm-ups,
for 300 observations per mode. Each resident writer represents an independent
daemon. The benchmark includes both grants and valid capacity/stagger waits:
these are admission decisions, not completed GitHub requests. Granted leases
were released between calls. Host load average at start was
19.42/21.08/19.41.

| Admission latency | One-shot baseline | Resident broker |
| --- | ---: | ---: |
| p50 | 112.14 ms | 6.22 ms |
| p99 | 175.89 ms | 143.24 ms |
| Maximum | 321.09 ms | 308.27 ms |
| Calls over 1,500 ms | 0 / 300 | 0 / 300 |

The resident p99 is below the transport's 1,500 ms admission deadline.
The baseline also stayed below the deadline in this bounded run: this does not
reproduce the incident's load 33–46 or establish a production p99 guarantee.
An externally held SQLite write lock can still exceed any finite deadline;
regression tests cover preserving claims and attempts when it does.

The resident path activates automatically in a running daemon after deployment;
shell guards retain one-shot execution and all processes share the existing
credential ledger. This measures synthetic admission latency, not production
quota or cost savings. Batched transactions are covered separately; this
three-daemon benchmark does not measure same-daemon fan-in batching gains.
