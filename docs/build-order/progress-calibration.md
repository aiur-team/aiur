# Build Order progress-estimate calibration capture

This run preserves the percentage estimates that BO agents report through
`progress` and `progress.checkin`. The capture is deliberately offline: it reads
the per-ticket `logs/agent.ndjson` transcript streams and the locally-owned
daemon run-log `log/event-publications.ndjson` outcome streams, writes an
operator-local dataset, and never calls GitHub, changes a ticket, or stores
surrounding prompts, commands, tool output, or transcript prose.

Run it periodically and once more before retiring the workspaces:

```bash
python3 docs/build-order/scripts/capture_progress_estimates.py
```

The defaults cover GitHub issue numbers 1085 through 1138 and write
`~/.aiur/analytics/build-order-progress/progress-estimates.ndjson`. Override the
source or destination without editing the script:

```bash
python3 docs/build-order/scripts/capture_progress_estimates.py \
  --workspace-root ~/code/aiur-workspaces/its-everdred/aiur \
  --publication-root ~/.aiur/logs \
  --output ~/.aiur/analytics/build-order-progress/progress-estimates.ndjson
```

The default publication root is `~/.aiur/logs`; the collector discovers each
run's `log/event-publications.ndjson` beneath it. Terminal publication outcomes
are accepted only from those daemon-owned roots; workspace transcript rows can
establish an attempted tool call but cannot assert its eventual delivery.

The collector streams each source file one line at a time, tolerates malformed
and unrelated source records, and merges repeat scans by the tool-call identity.
It retains previously captured samples even when a source workspace disappears.
Each output row contains only the ticket, normalized timestamp, event/tool-call
identity when available, estimate kind, percent, explicit progress label and
message, delivery status, and source-log path. `attempted` or `failed` rows are
kept so the later analysis can distinguish an agent estimate from one that
actually reached the Executor bar. A record is `emitted` only when the durable
bus event ID is present—either in the synchronous result, an explicit persisted
estimate event, or the call-correlated eventual-publication marker—not merely
because admission succeeded or the surrounding tool lifecycle completed.

## Phase-boundary calibration loop

GitHub's `phase:N` labels define analysis cohorts; they do not define runtime
barriers. After the final ticket in a phase merges:

1. Rerun the collector and freeze an operator-local, checksummed snapshot for
   that phase before any source workspace can disappear.
2. Query the durable GitHub issue-label, PR, review, and check-run timelines.
   Reconstruct at least implementing/local testing, CI wait, Executor code
   review, rework, and final merge wait. GitHub remains the lifecycle authority;
   do not add mutable GitHub facts to the raw estimate capture.
3. Compare every estimate timestamp with actual elapsed fractions against both
   **agent delivery** (ticket start through final CI-green / human-review
   readiness) and **full completion** (ticket start through merge / close).
   Measure calibration error and time held in each reported bucket, including
   review, rework, CI, and merge tails—for example, a ticket that reports 90%
   for half of its actual life.
4. Give the frozen cohort to a background research agent. Record its cohort
   report, evidence, and the exact guidance-version boundary used by the cohort.
5. Make at most one small, evidence-backed progress-guidance change for the
   phase, or explicitly record **no change** when the evidence is weak. Assess
   the change only on later tickets that had not started at the boundary.

Keep each frozen snapshot, checksum, normalized lifecycle evidence, research
report, and guidance-version record under the private operator-local directory
`~/.aiur/analytics/build-order-progress/cohorts/phase-N/`. None of those run
artifacts belongs in Git.

## Review-latency capture

Preserve review-cycle evidence in the same phase cohort. GitHub is the durable
lifecycle authority: capture PR open/merge times, commit heads, Actions/check
start and completion times, issue-label transitions, and the ordinary issue/PR
comments that carry Executor review packets. Formal GitHub Review objects are
not sufficient for this run because substantive review is normally delivered
through ordinary comments. Per-ticket agent logs and workpads supply
self-review start/end events and attestations; keep their normalized evidence
with the private cohort before retiring a workspace.

Use these stable measures:

- literal review dwell: `agent:human-review` onset through the next primary
  state transition;
- semantic review packet: one deduplicated set of actionable findings against
  one exact PR head, including packets delivered outside `human-review`;
- rework turnaround: packet delivery or `agent:rework` onset through the next
  pushed head and review-ready transition;
- CI correction episode: one or more contiguous failed heads before the next
  corrective push; and
- self-review freshness: whether the remote PR head has a completed worker
  review receipt and no later content-changing commit.

The 2026-07-14 baseline covered 19 Build Order/Ad Hoc PRs (eight merged and
eleven open after the merge-boundary snapshot). The seven fully audited merged
PRs had median human-review-to-rework latency of 9m39s and median PR lifetime of
2h16m37s, while 15 CI correction episodes took a median 34m59s to reach the
next attempt. All seven still received a semantic correction after reporting
self-review. The open long tail had median age 11h46m, 149 observed pushed
heads, 76 failed heads, 47 human-review entries, 42 literal
review-to-rework transitions, and at least 86 actionable Executor packets.
Only 34 packets were associated with `human-review`; label-only analytics
therefore materially undercount review. Across a representative freshness
audit, only two of seven long-running PRs had a completed worker review on
their current head, versus four of five short controls.

At the next phase boundary, test one minimal guidance change on tickets that
have not started: keep early draft PR creation and CI parallelism; require one
full `ce-code-review`, then require a focused delta review after every later
content-changing push before `ci-wait` or `human-review`. Record a compact
receipt such as `kind`, `base_sha`, `head_sha`, `result`, and
`changes_after=none`. A CI rerun without a new commit does not invalidate the
receipt. Compare current-head coverage, semantic packets, review/rework cycles,
CI correction episodes, and total delivery time with this baseline before
making another guidance change.

Never reinterpret already-running tickets under new guidance. Do not stop
already-running next-phase work, delay newly-ready dependencies, or serialize
the dependency graph for this experiment; analysis follows merge completion
without becoming a dispatch gate.

The effective progress rubric is delivered from
`src/prompts/shared-agent-instructions.md`; the `using-aiur` skill points agents
to that per-turn prompt rather than duplicating the protocol. Any phase-level
change must update that actual delivery source and its focused tests, then
record the resulting commit or content hash as the next guidance-version
boundary.

## Final synthesis

BO-015 synthesizes the phase reports, cross-version results, and remaining bias;
it is not the first calibration pass. File one final follow-up ticket only for
remaining work that could not be learned or applied safely during the run. The
synthesis may also decide whether this dataset shape is useful to a future
analytics page; analytics UI is not part of the current Build Order.
