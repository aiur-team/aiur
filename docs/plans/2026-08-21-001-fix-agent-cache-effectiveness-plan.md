---
title: "fix: Make agent cache effectiveness measurable"
date: 2026-08-21
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: "GitHub issue #2207"
---

# Fix Agent Cache Effectiveness Measurement

## Goal Capsule

- **Objective:** Make the durable agent `gh` cache hit/miss ratio visible and preserve a real-wrapper regression for exact-shape reuse.
- **Authority:** GitHub issue #2207 and the existing byte-replay correctness contract in `src/lib/aiur/github/agent_cache.ex`.
- **Tail owner:** This ticket owns implementation, documentation, scoped verification, PR review, and CI handoff.

## Product Contract

### Problem Frame

The agent cache records every cacheable invocation in per-workspace `agent-cache.tsv` files, but no product code reads those counters. Operators therefore cannot distinguish a healthy cache from one whose reuse rate has collapsed.

The reported sample can be reproduced exactly at 11 hits and 490 misses. Its
misses divide into 293 `issue`, 66 `pr`, and 131 repository REST `api` rows.
High-level CI verdict and merge-gating commands account for none of them: the
wrapper refuses those reads before it creates a cache event.

The REST rows retain endpoint SHA-256 ids rather than endpoint text, but agent
transcripts recover the endpoints for 120 of the 131 REST miss events. They
identify 75 unsafe CI, review, or Actions misses and six of the seven REST hits
as unsafe. Removing those rows leaves 404 safe misses and five safe hits, still
a 1.2% safe hit rate. Unsafe traffic therefore does not explain away the low
rate. A live store
snapshot contained 122 exact shapes for 47 resources, with 32 resources holding
multiple shapes and 72 shapes already invalidated. That snapshot shows
exact-shape diversity and invalidation are substantial current constraints; it
does not prove one historical cause or support changing the 60-second TTL or
byte-exact key.

The comparison with the daemon read-cache policy also exposes a correctness
gap: direct `gh api` reads of checks, statuses, reviews, requested reviewers,
merge state, and Actions run or job state entered the wrapper store even though
equivalent high-level reads are refused. Those paths must be denied on content
before reuse is measured or optimized.

### Requirements

- R1. The GitHub cache page reports a rolling 24-hour agent-cache hit/miss ratio from durable counters on the daemon host, including the covered interval and sample size.
- R2. Missing or unreadable counters render as unmeasured, not as a fabricated zero-percent hit rate.
- R3. Operator-facing documentation explains that the ratio measures exact stdout-shape reuse and that mutations retire cached shapes.
- R4. A real-wrapper regression proves repeated identical reads produce one miss followed by hits and fails if reuse collapses.
- R5. New miss rows classify why lookup failed so future cache changes can be evaluated without reconstructing causes from filesystem state.
- R6. REST reads carrying CI verdict, review, or merge-gating state are never served from the store, matching the daemon read-cache safety boundary.

### Scope Boundaries

- Keep the existing 60-second TTL, byte-exact shape key, and resource invalidation semantics.
- Do not include the daemon transport cache; it has separate metrics and transport behavior.
- Do not add a writable dashboard action or any GitHub request to the inspector path.
- Do not claim the historical low rate proves a TTL defect; classify recoverable command shapes first and keep byte-exact output identity.

## Planning Contract

### Key Technical Decisions

- KTD1. Read both active and rotated per-workspace TSVs for the preceding 24 hours using the workspace layout pattern already used by `Aiur.GitHub.Quota`; label the result as daemon-host coverage because SSH-worker files are not locally reachable. Malformed rows fail open and remain visible as partial coverage.
- KTD2. Treat only `hit` and `miss` as the hit/miss ratio denominator. `store` is a consequence of a miss, while `coalesced` measures simultaneous-request suppression rather than kept-answer reuse.
- KTD3. Preserve the exact argument/terminal/credential shape key. The stored artifact is `gh` stdout, so semantically broader keys cannot safely replay a different byte shape.

## Implementation Units

### U1. Durable agent-cache metrics and dashboard tile

**Requirements:** R1, R2, R5; KTD1, KTD2.

**Files:**

- `src/lib/aiur/github/agent_cache_metrics.ex`
- `src/lib/aiur_web/live/github_cache_live.ex`
- `src/priv/github_quota_guard.sh`
- `src/test/aiur/github/agent_cache_metrics_test.exs`
- `src/test/aiur_web/live/github_cache_live_test.exs`

**Approach:** Add a fail-open reader with a provider seam, load it with the existing cache projection, and render an overview tile that names the 24-hour interval, daemon-host coverage, measured counts, and ratio without implying that absent files equal zero activity. Re-read the counters on the existing quota-history sample notification so an open page advances without adding a poller. Show skipped sources or malformed rows as partial coverage rather than silently presenting an incomplete aggregate as authoritative. Extend miss rows with an optional reason column while preserving compatibility with existing five-column data.

**Test scenarios:**

- Active and rotated files aggregate valid hit, miss, store, and coalesced rows exactly once.
- Rows outside the rolling 24-hour window do not affect the ratio.
- Malformed rows are ignored but counted as partial coverage; absent files return an unmeasured snapshot.
- The overview renders a percentage and raw hit/miss counts without moving the GitHub quota meter.
- An unavailable metrics source renders “Not measured” rather than `0%`.
- A valid source containing no `hit` or `miss` rows also renders “Not measured,” and a history-sample notification refreshes the tile.
- Old five-column rows remain readable; new miss rows attribute absent, expired, invalidated, bypassed, clock-skewed, or corrupt entries.

### U2. Exact-shape reuse regression and operator explanation

**Requirements:** R3, R4; KTD3.

**Files:**

- `src/test/aiur/agent_github_guard_test.exs`
- `website/docs-app/apis/github.md`

**Approach:** Extend the existing real shell-wrapper harness with a repeated-read sample large enough to assert a high hit ratio, then document what the production ratio does and does not measure.

**Test scenarios:**

- Ten identical cacheable reads emit one miss and nine hits while making one upstream call.
- The regression derives its assertion from the same TSV rows the dashboard reader consumes.

### U3. Refuse unsafe direct REST reads

**Requirements:** R6.

**Files:**

- `src/priv/github_quota_guard.sh`
- `src/test/aiur/agent_github_guard_test.exs`

**Approach:** Apply the daemon `ReadCache.Policy` unsafe REST boundary to the
wrapper's normalized repository endpoint before it constructs a cache entry.
Keep stable resource metadata cacheable.

**Test scenarios:**

- Repeated direct REST reads of checks, check suites, statuses, reviews,
  requested reviewers, merge state, and Actions run or job state make two
  upstream calls.
- Existing stable REST metadata reuse remains covered by the wrapper tests.

## Verification Contract

- Compile with warnings as errors and format the touched Elixir files.
- Run the metrics, cache LiveView, agent cache, and real-wrapper affected tests with at most four cases.
- Confirm the affected-test mapper collects every added test file.
- Self-review the pushed draft PR against `main`, including the documentation threshold.

## Definition of Done

- The cache page exposes a durable, honestly labeled agent-store hit/miss ratio.
- The historical low rate is classified to the precision supported by counters plus retained transcripts, without an unsupported TTL claim.
- Unsafe REST verdict and merge-gating reads cannot produce cache hits.
- The real wrapper’s identical-read hit ratio is regression-tested.
- Scoped verification and adversarial review pass, and the draft PR is handed to CI against `main`.
