## Wind-down checkpoint — macbook-fable (2026-07-17 22:30 PDT)

This supersedes everything below for macbook-fable's scope (the DASH accounting /
Units / conversation stack). Orangekid's BO-graph spine and partition are
untouched; their checkpoints below still hold for their scope.

**Progress: 36/54 merged (~67%); 37 once DASH-025 lands.** Since the 20:10
handoff, macbook-fable merged DASH-010, DASH-026, DASH-024, DASH-003, DASH-014,
DASH-029 to `develop`, then ran a same-machine Aiur daemon (session
`aiur-kevinweaver-16e668d8e2`, opus, aiur-claude 1.1.0) to implement the rest
while acting as reviewer.

**Aiur is now STOPPED on macbook-fable** (clean stop; no node, 0 agent procs, 0
tmux sessions). Operator directive: wind down, finish the two in-flight tickets,
hold the queue, hand off.

### In-flight at stop
- **DASH-025 #1129 — PR #1250** (`aiur/1129-bo-dash-025-harden`, head
  `335d57f3`). The destructive retention/compaction seam. **Reviewed
  APPROVE-WITH-NITS** by a background review agent: all 9 safety invariants hold
  (no-delete-before-coverage, crash-safe manifest state machine, dimension
  preservation, query equivalence, containment); the coordinator is deliberately
  supervised BEFORE the aggregate (crash-safe — keep it). The daemon's rework
  already added the top nit (Floor fail-closed on a mid-flight destructive
  phase). **CI: only `dialyzer` + `lint` fail** (build/guard/layout/browser/test
  green). A macbook-fable fix agent is resolving those now → **merge on green**
  (required gates + 0 own-domain failures). Deferred non-blocking nits: read-back
  block validation before the point of no return; explicit `sync_fun` coupling in
  the coordinator; broaden compaction property-test dimensions.
- **DASH-005 #1112 — work LOST.** Its daemon agent never pushed a branch, so the
  in-progress implementation was discarded on stop. Label is a stale
  `agent:in-progress`. **Needs a fresh run.**

### Queue HELD (do not auto-start)
These 7 downstream tickets were dequeued (`agent:todo` removed) and left
dependency-ready but intentionally unstarted. Re-add `agent:todo` to resume:
**DASH-030 #1134, DASH-027 #1131, DASH-028 #1132, DASH-022 #1126,
DASH-032 #1136, DASH-034 #1138, DASH-031 #1135.**

### Ready frontier on resume
Dependency-ready now: **DASH-005, DASH-030, DASH-027, DASH-028, DASH-022,
DASH-032.** Then **DASH-034** (after DASH-032) and **DASH-031** (after
DASH-025 + DASH-030 + orangekid's **DASH-013 #1119** — the one cross-machine
join). Capstones last: DASH-023 #1127, DASH-033 #1137, BO-015 #1102.

### Restart recipe (macbook-fable)
1. `git -C /Users/kevinweaver/github.com/aiur-team/aiur checkout develop && git pull`
2. `scripts/aiurdev build` (rebuild on current develop — DASH-003/014/024/026/029
   are in the base).
3. Queue ONLY the intended set: `scripts/aiurdev --todo <ids>` (e.g. re-run
   DASH-005 first, then the frontier). Do NOT `--only` (it would strip
   orangekid's paused labels).
4. `scripts/aiurdev run --bg --debug --max-agents <n>` with Claude opus.
   **Sustainable concurrency on this M4 (10-core) is ~2–3 heavy Elixir agents**;
   AIMD + the load gate (holds dispatch ~load 18) will keep it there. Dispatch is
   serial-ish because each agent materializes a prewarm workspace and a 690-file
   compile is heavy. Don't set the ceiling high expecting 6 parallel — it thrashes.
5. Reviewer loop: for each daemon PR, review + merge under the proven policy, or
   route rework via `scripts/aiurdev message <id>`.

### Standing constraints
- **NEVER commit `.aiur/config`** (machine-local `writableRoots`) or
  `.aiur/model-usage.json`.
- Do not touch orangekid's **BO-012 #1099 / DASH-013 #1119** or the 5
  CI-stabilization flaky test files.
- Merge target `develop`; generic fixes → `main` then sync main→develop.
- Stale ADHOC alerts **#1030** (workspace-bootstrap; PR #1039 regression-guard
  decision, references old 0-file heads) and **#973** (paused since Jul 12) are
  OUTSIDE the 54 — parked, not resolved under the build-order goal.
