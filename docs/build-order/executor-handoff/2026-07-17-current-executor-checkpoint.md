## Current Executor checkpoint (updated 2026-07-17 15:12 PDT)

The live Executor is Codex-only on the literal `develop` runtime checkout at
`/home/orangekid/github/aiur-runtime-develop`. It was force-built before launch
and is running detached with debug recording and `max-agents` 15. Preserve its
machine-local `.aiur/config` and `.aiur/model-usage.json` changes. Do not launch
Claude, restart the healthy daemon merely because a control RPC times out, or
run `watch --full` / `alerts --needs-attention` while #1231 remains open.
Publish the Build Order preview from both its source and served pack every
30 minutes; the current cadence anchor is 15:12 PDT on 2026-07-17.

The authoritative integration base is now exactly
`origin/develop@9229b48d`, the squash merge of #1240/PR #1242; current
`origin/main@ff06d53c` is an ancestor. The healthy daemon remains on its
previous `791ad6dc` runtime build and does not need a disruptive restart merely
for this base advance. The previously announced external setup
fix is no longer an integration hold. Exhaustive local session, branch, ref,
worktree, process, and GitHub reconciliation found no concrete owner, branch,
or actionable change. A session-historian pass over #1237/#1238/#1240 confirmed
those workers merely waited on the Executor announcement. Continue against
actual current `develop`; if a setup commit later appears, treat it as an
ordinary new base advance and inspect it before integration.

BO-012/#1099 is published as draft PR #1244 at `0ef359a3`. Its original exact
head passed the full GitHub test job, but CI exposed five Credo findings, a
too-narrow Dialyzer contract, inaccessible dependency-kind contrast, and a
route-shell test that rejected the fixture reaching its stable `ready` state
faster than the transient assertion. The bounded repairs pass focused Credo,
Dialyzer, affected LiveView tests, 4/4 browser smoke, and the complete
five-viewport route-shell test locally. Its replacement CI is useful diagnostic
evidence but became stale when #1240 landed. Merge exact `9229b48d`, requalify
the resulting head, and require a clean independent delta review before merge.

DASH-003/#1110 and DASH-009/#1115 remain direct sole-writer repairs. DASH-003
has 158 runner/dispatcher tests, 96 status/dashboard tests, and 24 new
regressions green; its long full suite is classifying two unrelated
timing/concurrency failures before final Dialyzer and commit. DASH-009 has 29
focused and 46 complete usage-ledger tests plus compile, format, specs, and
Credo green; its long full suite is classifying four unrelated shared-state
failures before Dialyzer and commit. Do not push either until an independent
exact-head review runs.

DASH-014/#1120 is now review-clean as draft PR #1239 at `900d7bf5`. The branch
contains current `develop`, all four delta findings are fixed, 26 targeted and
121 affected tests pass, and independent Executor review found no actionable
finding. First exact CI found one deterministic nesting warning; the extracted
broadcast helper passes focused Credo, format, and 15/15 projection tests.
Replacement build, lint, Dialyzer, browser, layout, and guards are green; only
the long test job was still in flight when #1240 advanced `develop`. Treat that
run as diagnostic, then merge exact `9229b48d` and requalify the new head.

The Executor's #1240 repair was independently review-clean and landed through
PR #1242 as `develop@9229b48d` from exact head `52207071`. Failing-before
regressions proved that stale boot
fences dropped durable follow-up repair and that serialized lifecycle state
grew from roughly 1 KiB to 14 KiB after 20 retries. Both complete DecisionStore
files pass 77/77 and the new pair passes six consecutive runs. All exact CI
jobs passed, the non-default-branch issue was explicitly marked `agent:done`
and closed, and every surviving feature head must now advance to this new exact
`develop` before final qualification.

The older Executor handoffs are fully reconciled. Of the four-PR shutdown
frontier, #1036, #1202, and #1213 merged and closed; #1217/#1130 is the only
survivor. It now has a direct sole writer: the previous exact
`develop@791ad6dc` was merged as `b934090d`, the three reproduced Credo findings
are repaired, full Credo and format pass, and focused runtime/security
validation plus Dialyzer are running. Commit that isolated repair, then merge
exact `9229b48d` and requalify it without rebase or force-push.
Of the abandoned Claude session's five lanes, four merged and closed; only
#1119/PR #1228 survives. Its source and CI are complete, and local
`aiur-claude --version` is 1.1.0, but npm still publishes only 1.0.0, so the
public distribution gate remains real. Keep #1119 and human-gated #1116 frozen.

The Aiur Codex provider remains exhausted until 2026-07-22 21:15 PDT; the three
daemon workers stay quota-paused and Claude fallback stays disabled. Three
direct repair writers plus the Executor qualification lane consume all
collaboration slots. Two long local full suites remain active but are making
steady progress; memory is healthy and one-minute load remains below the
12-core ceiling. Avoid redundant full-suite or shared-browser launches until
they drain.
#1237 and #1238 remain preserved `agent:rework + agent:paused`, but no longer
depend on a hypothetical setup fix; resume them in priority order after the
current repairs and #1130 are staffed. After any merge to non-default
`develop`, explicitly close the issue with `agent:done` and record the receipt.
