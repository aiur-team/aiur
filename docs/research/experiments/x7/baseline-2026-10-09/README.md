# Optimistic-start baseline (frozen 2026-10-09)

Frozen "before" data for experiment EXP-X7 (optimistic dependent start, epic #3755).
It was captured before BQ-G1-1 (#3763) merged. Every dependent in it started under
today's rule: a dependent starts only after each `blocked_by` blocker is closed.

- **Data cut:** 2026-10-09T17:55:20Z.
- **Window:** dependents whose first start is at or after 2026-10-06T00:00Z.
- **Population:** Platform program tickets, which means tickets with a `build-lane:*` label or an `MP-` title prefix.
- **Do not edit these files.** Later data goes into a new snapshot directory.

## Files

| File | Content |
| --- | --- |
| `dependents.csv` | One row per dependent (program ticket with at least one native `blocked_by` link, started in window). Blocker and dependent timestamps, flow times in hours, flags. |
| `edges.csv` | One row per blocker -> dependent edge. Blocker PR opened / ready / merged, blocker issue closed, dependent start, per-edge gaps. |
| `program-tickets-flow.csv` | Every program ticket started in window (dependents and roots). Reference flow times. |
| `baseline.json` | Population counts and medians / IQR / mean / min / max per metric, split by complexity and by hub-gated vs chain-gated. |
| `guardrails.json`, `guardrails-per-ticket.csv` | Rework rate, PRs closed unmerged, `agent:error`, and the main-branch CI failure rate. |
| `power.json` | Simulated Mann-Whitney power per arm size and effect, resampled from this baseline. |
| `sources.json` | Every telemetry file and run summary read, with sizes, plus the GitHub queries. |
| `method/*.py` | The read-only scripts that produced the files. Run them with `python3 -I`. |

## Definitions

- **Dependent start:** the first `agent:in-progress` label event on the issue (GitHub timeline). This is the primary source.
  - The first telemetry `dispatch` event is a cross-check (`start_telemetry_first_dispatch`). It exists for all 34 dependents.
  - Telemetry leads the label by a median of 1.3 min (range 0.9 to 4.1 min). The two sources agree.
- **Blocker PR:** the merged PR in `closedByPullRequestsReferences`. If no PR is merged, the newest PR is used.
  - **Opened:** PR `createdAt`.
  - **Ready:** the first `ReadyForReviewEvent`. If the PR was never a draft, ready is `createdAt`.
  - **Merged:** `mergedAt`.
- **Gap (primary):** the dependent's start minus the latest blocker PR merge across all its blockers. A gap is computed only when every blocker has a merged PR.
- **Close gap:** the same, measured from the latest blocker issue closed `completed`. In this window it equals the merge gap to within a second, because the merge closes the issue.
- **Chain lead time:** the latest blocker PR opened -> the dependent PR merged. This is the end-to-end time that optimistic start is meant to shorten.
- **Optimistic headroom:** the latest blocker PR opened -> the latest blocker PR merged. This is the most start time that `start_on: pr_opened` could gain.
- **Eligible for gap:** every blocker link was added before the dependent started (from `BlockedByAddedEvent`), and the dependent started at or after the last blocker merge.
- **Hub-gated:** at least one blocker blocks 10 or more issues.
  - In this window that blocker is #3255, "U0-T01 review gate", which blocks 73 issues.
  - The dependents released by one hub merge start together, so their gaps measure the dispatch ramp more than per-edge waiting.

## Sample counts

- 38 program tickets started in window. 34 of them are dependents with 49 edges.
- 7 dependents are **late-linked**: their `blocked_by` link was added after they started. They are excluded from every gap and dependent-flow metric.
- 27 dependents are eligible for the gap metric: 19 hub-gated and 8 chain-gated.
- 25 dependents merged. 24 of them are not late-linked.
- Complexity of the eligible dependents: c1 = 1, c2 = 17, c3 = 6, c4 = 3. No dependent lacks a complexity label.

## Results (hours; median [P25-P75], n)

| Metric | All | Hub-gated | Chain-gated |
| --- | --- | --- | --- |
| Blocker merge -> dependent start (primary) | 0.78 [0.69-3.63] n=27 | 0.76 [0.70-3.40] n=19 | 1.57 [0.27-6.53] n=8 |
| Dependent start -> merge (primary) | 1.00 [0.43-2.63] n=24 | 1.00 [0.40-2.90] n=16 | 0.96 [0.48-1.70] n=8 |
| Dependent start -> PR open | 0.20 [0.11-0.41] n=25 | 0.19 [0.10-0.24] n=17 | 0.28 [0.18-0.99] n=8 |
| Dependent PR open -> merge | 0.40 [0.31-1.29] n=24 | 0.44 [0.30-1.29] n=16 | 0.36 [0.32-0.87] n=8 |
| Latest blocker PR open -> dependent start | 2.10 [1.77-4.69] n=27 | 1.82 [1.76-4.46] n=19 | 3.68 [2.07-8.79] n=8 |
| Optimistic headroom (blocker PR open -> merge) | 1.06 n=27 (19 rows share one hub value) | 1.06 | 2.03 [0.95-4.24] n=8 |
| Chain lead time (blocker PR open -> dependent merged) | 4.68 [2.53-6.04] n=24 | | |

By complexity, the gap is c2 1.89 [0.71-3.75] n=17 and c3 2.17 [0.78-5.44] n=6. Start -> merge is c2 0.78 [0.43-2.40] n=15 and c3 1.40 [0.71-2.57] n=6. Strata c1 and c4 hold 1 to 3 rows each and are reported only in `baseline.json`.

Edge level (33 edges with a merged blocker, not late): gap 1.89 [0.70-3.99]. Blocker PR open -> merge over the 16 unique blockers: 2.03 [1.03-3.71].

**Guardrails:**

- Rework: 9 of 34 dependents (26.5%) and 11 of 38 program tickets (28.9%) had at least one `agent:rework` cycle.
- PRs closed unmerged: 0. Agent errors: 0.
- Main-branch `ci` push runs: 45 of 117 completed runs failed (38.5%). 133 cancelled runs are excluded.
  - By day: 10-06 11/49, 10-08 16/39, 10-09 18/28.

## Power (from `power.json`)

Each row is the arm size per arm needed for 80% power with a two-sided Mann-Whitney test at alpha 0.05. Treatment is the baseline multiplied by a factor.

| Metric | Effect x0.5 | Effect x0.67 |
| --- | --- | --- |
| Chain lead time | about 15 to 20 | about 40 |
| Dependent start -> merge | about 40 | more than 60 |

For the gap metric itself, a multiplicative effect is the wrong model. Under `pr_opened` the gap is expected to go below zero, because the dependent starts before its blocker merges. A shift of that size is detectable with about 10 per arm. That makes the gap a mechanism check, not the decision metric.

## Caveats

- **Small and clustered sample.** 19 of the 27 gap rows come from one hub release (#3255 merged 2026-10-08T18:49:35Z). They are not independent. Report the chain-gated stratum (n = 8) separately. Use a cluster bootstrap (cluster = the releasing blocker) for any interval.
- **Telemetry retention.**
  - Daemon telemetry on disk starts at 2026-10-08T02:00Z.
  - Oct 6 is covered only by the run summaries `mW4Waq0xw4pc6WIh`, `eyxoTC1UrARepOwL` and `NBbQ773diVYcL6B6`. The span 2026-10-06T18:16Z to 2026-10-08T02:00Z is mostly missing.
  - No program dependent started before 2026-10-08T06:41Z, so the GitHub-based metrics are complete for this population. Telemetry is only a cross-check.
  - This loss is the reason the baseline is frozen.
- **Start = first start.** Re-dispatches after rework or a restart are not new starts. Restart cold-poll delay (20+ minutes after a daemon restart) and capacity holds are inside the gap. 17 daemon boots wrote telemetry on 10-08 and 10-09. These are confounders, not noise to remove.
- **Capacity.**
  - The gap includes slot waiting: with `max_agents` at 12, a released wave of 19 dependents could not all start at once.
  - G5 (#3767 to #3769) changes slot priority and the ramp. Its effect overlaps the effect being measured.
- **Late links.** Blocker links added after a ticket started (7 dependents) are excluded. The link-add time comes from `BlockedByAddedEvent`. Removed links are not reconstructed. The current links are used.
- **Ready time.** Agents usually open non-draft PRs, so ready = opened for most blockers.
- **Untrusted inputs.** Telemetry and run summaries were parsed as data only. No line was unparseable in the files read. Older run summaries (August and September) were read but fall outside the window.
- **Known reducer bug not used.** `analytics/lib/analytics/reduce.py` takes a `pr.opened` time from `merged_at` first. This baseline uses GitHub `createdAt` and does not go through the reducer.
