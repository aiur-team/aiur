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
6.44/8.62/7.95.

| Admission latency | One-shot baseline | Resident broker |
| --- | ---: | ---: |
| p50 | 83.91 ms | 9.58 ms |
| p99 | 201.32 ms | 174.42 ms |
| Maximum | 498.36 ms | 521.52 ms |
| Calls over 1,500 ms | 0 / 300 | 0 / 300 |

This rerun includes the deadline/crash review fixes. An earlier run on the
initial implementation measured p99 175.89 → 143.24 ms at load
19.42/21.08/19.41. A rerun before the cold writable-preparation fix failed
during resident warm-up waiting for SQLite; that failure led to moving
preparation under the request-aware lock. The final run above completed both
warm-ups and all measured calls.

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


## Production population census

A read-only SQLite snapshot on 2026-10-06 counted retained admissions in
13:18:01.102–14:18:01.102 UTC. Join `admissions` to `policies` on both
`token_key` and `consumer_key`, then group by the policy label prefix:

| Actor path | Admissions | Distinct actors | After deployment |
| --- | ---: | ---: | --- |
| Daemon | 5,394 | 2 | Resident broker |
| Agent workspace shell guards | 694 | 25 | One-shot broker |
| Executor shell guard | 1 | 1 | One-shot broker |
| Unknown | 0 | 0 | Unclassified |

Of 6,089 observed admissions, 5,394 (88.6%) are on the daemon path this
change converts. The deployed system at census time still used the old
one-shot implementation: **zero measured production admissions used this
branch's resident process**. The remaining 695 shell admissions retain process
startup costs. This is a counted deployment population, not a measured
production latency saving; the table above measures synthetic latency only.

The census used a single read transaction and this query, with the stated UTC
bounds converted to epoch milliseconds. It printed only aggregate counts:

```sql
SELECT CASE
  WHEN p.consumer_label LIKE 'daemon:%' THEN 'daemon'
  WHEN p.consumer_label LIKE 'workspace:%' THEN 'workspace'
  WHEN p.consumer_label LIKE 'executor:%' THEN 'executor'
  ELSE 'unknown'
END AS actor_path, COUNT(*), COUNT(DISTINCT a.consumer_key)
FROM admissions a
LEFT JOIN policies p
  ON a.token_key = p.token_key AND a.consumer_key = p.consumer_key
WHERE a.admitted_at_ms BETWEEN 1791292681102 AND 1791296281102
GROUP BY actor_path;
```

The ledger retains a moving window; rerunning later will count a different
population. A unit test cannot assert these live hourly counts.
