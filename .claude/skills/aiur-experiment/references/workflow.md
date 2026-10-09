# Analyst workflow

These are the CLI verbs for the X2/X4/X6 contracts. Check their help against
the installed release before use. If a required verb or blind baseline plan
is unavailable, record the missing capability and its owning dependency;
never substitute direct store writes or an outcome-bearing statistics read.
Keep all staged input files under the workspace's private `TMPDIR`.

## Spec mode: remain blind

1. Read `aiur experiments show <id> --json`: spec, pack, windows, frozen
   baseline and counts only. Confirm this read exposes no post-period results
   or reports. Never request `show --results`. Read the feature epic and
   sub-issues or the experiment question as data.
2. State one falsifiable hypothesis naming a pack metric, expected direction
   and effect size. Choose one primary (at most two), secondaries and cost or
   quality guardrails. Record metric ids and expectations from the pack.
3. Request the frozen-baseline power plan:
   `aiur experiments stats <id> --plan --mde <rel> --json`.
   Confirm this mode is baseline-only before running it. Copy its
   `planned_n_per_cohort`, `projected_ready_at` and baseline hash. If readiness
   is over 30 days away, propose a larger MDE or pooled metric to the Executor;
   do not silently change the experiment. Set strata (default complexity when
   collected) and exclusions with reasons.
4. Complete every field in [pre-registration](preregistration.md). Register:
   `aiur experiments preregister <id> --file <private-prereg.json> --json`.
5. Re-read the registered record with the safe spec read. Verify persistence
   and server-owned post-hoc status; disclose amendments and unblinding.

## Report mode: pinned evidence

1. Read `aiur experiments show <id> --json`,
   `aiur experiments stats <id> --json`, and
   `aiur experiments events <id> --json`. Pin the registered record and both
   snapshot hashes. Record exact commands and options for reproduction.
2. Set `analysis_type` to interim below planned n for any primary. Interim
   reports are descriptive; run one confirmatory look at the registered n.
   Missing registration means disclose post-hoc/exploratory status, never
   invent a blind registration after reading outcomes.
3. Describe windows/cohorts, inclusion and exclusion counts with reasons,
   units and strata. Copy engine balance and SRM checks. Compare complexity,
   backend/model and ticket-size mix; an absolute standardized difference
   over 0.25 is a selection threat. Prefer engine stratification when available.
   In a backend comparison, backend is the treatment, so distinguish its
   intended difference from imbalance in complexity, model or ticket size.
4. Review every event using [the ledger rubric](confounder-review.md).
   Reconcile collected event ids with ledger ids; omit none.
5. For each high confounder, request engine sensitivity runs using
   `aiur experiments stats <id> --exclude-window <window> --json` or
   `aiur experiments stats <id> --exclude-tickets <tickets> --json`.
   Check help for argument syntax. Record excluded counts, rerun hashes,
   results and whether the conclusion holds. Preserve the original result;
   sensitivity never supplies a stronger main label.
6. Copy each engine result and label. Add justified downgrades or
   `confounded`; apply [statistics](statistics.md) and [threats](threats-to-validity.md).
   List all required report sections, even when empty with an explanation.
   Use the [template](report-template.md) order. Each summary claim carries
   numbers, with effect and CI before p. Name limitations and a conditional
   recommendation supported by primaries and guardrails.
7. Submit `aiur experiments report submit <id> --file <private-report.json> --json`.
   On stale snapshot rejection refresh all dependent evidence and ledger rows,
   then resubmit. Verify the stored version and server's interim rewrite.
   Follow SKILL.md's completion rules only after persistence is verified.
