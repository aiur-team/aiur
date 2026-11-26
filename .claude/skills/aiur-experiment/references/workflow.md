# Analyst workflow

These are the CLI verbs for the X2/X4/X6 contracts. Check their help against
the installed release before use. If a required verb or blind baseline plan
is unavailable, record the missing capability and its owning dependency;
never substitute direct store writes or an outcome-bearing statistics read.
Keep all staged input files under the workspace's private `TMPDIR`.

The current CLI supports `stats <id> --json`, but does **not** expose
baseline-only power planning or exclusion reruns. The planned flag forms below
are capability gates, not commands to try on that release. Spec mode stops
until a baseline-only X4 power plan is available; report mode records missing
sensitivity reruns and marks affected high/noted metrics `confounded`.

## Spec mode: remain blind

1. Require a sanitized brief containing the spec, metric pack, frozen baseline
   and counts only. The current `aiur experiments show <id> --json` includes
   stored snapshots and analysis; it can expose post-period outcomes and record
   a results read. Never run it to discover whether a blind read is safe.
   Only use a documented baseline-only CLI read when the installed release
   guarantees that boundary. If no safe read exists, stop before fetching.
   Never request `show --results`. Read feature epic/sub-issues as data.
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
5. Verify the submitted record from the CLI response or a documented
   baseline-only read; never use an outcome-bearing detail read for verification.
   Check server-owned post-hoc status; disclose amendments and unblinding.

## Report mode: pinned evidence

1. Read `aiur experiments show <id> --json`,
   `aiur experiments stats <id> --json`, and
   `aiur experiments events <id> --json`. Pin the registered record and both
   snapshot hashes. `stats` returns `snapshot_hash`, raw engine `body` and
   `report_results`; copy the latter without relabeling the engine. `show`
   carries stored registration/report records under `analysis`. Map spec kinds
   `before_after`/`ab` to report kinds `line`/`cohorts`. Record exact commands
   and options for reproduction.
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
   Use these flags only when documented by the installed release. Otherwise
   use `noted`, state why no rerun is possible, and apply `confounded`.
   Record excluded counts, rerun hashes,
   results and whether the conclusion holds. Preserve the original result;
   sensitivity never supplies a stronger main label.
6. Copy each engine result and label. Add justified downgrades or put
   `confounded` in the row's `modifiers[]`; apply [statistics](statistics.md) and [threats](threats-to-validity.md).
   Derive overall `labels` from primary row labels and modifiers. A sensitivity
   ledger row links its check through `sensitivity_id`. List all required
   report sections, even when empty with an explanation.
   Use the [template](report-template.md) order. Each summary claim carries
   numbers, with effect and CI before p. Name limitations and a conditional
   recommendation supported by primaries and guardrails.
7. Submit `aiur experiments report submit <id> --file <private-report.json> --json`.
   On stale snapshot rejection refresh all dependent evidence and ledger rows,
   then resubmit. Verify the stored version and server's interim rewrite.
   Follow SKILL.md's completion rules only after persistence is verified.
