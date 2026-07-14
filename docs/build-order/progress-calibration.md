# Build Order progress-estimate calibration capture

This run preserves the percentage estimates that BO agents report through
`progress` and `progress.checkin`. The capture is deliberately offline: it reads
the per-ticket `logs/agent.ndjson` streams, writes an operator-local dataset,
and never calls GitHub, changes a ticket, or stores surrounding prompts,
commands, tool output, or transcript prose.

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
  --output ~/.aiur/analytics/build-order-progress/progress-estimates.ndjson
```

The collector streams each source file one line at a time, tolerates malformed
and unrelated source records, and merges repeat scans by the tool-call identity.
It retains previously captured samples even when a source workspace disappears.
Each output row contains only the ticket, normalized timestamp, event/tool-call
identity when available, estimate kind, percent, explicit progress label and
message, delivery status, and source-log path. `attempted` or `failed` rows are
kept so the later analysis can distinguish an agent estimate from one that
actually reached the Executor bar. A record is `emitted` only when the durable
bus event ID is present (or the source is an explicit persisted estimate event),
not merely because the surrounding tool lifecycle completed.

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
