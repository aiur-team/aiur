# Build Order Executor Handoff

> **Superseded:** the live, machine-local Executor handoff now belongs at
> `~/.aiur/repo/<owner>/<repo>/executor/handoff.md`. This tracked document is
> retained as historical context only; new handoffs must replace the state-node
> document rather than append here.

**Dashboard address (verified 2026-10-01):** The current Aiur operator dashboard
is [on the tailnet](https://orangekid.tailee0e71.ts.net:4001/build-orders).
It requires the configured dashboard Basic Auth credentials. The `<dashboard-host>`
addresses below are historical snapshots and time out on the current host. Before
using a saved address, run `scripts/aiurdev status` to confirm the listener and
`tailscale serve status` to confirm which tailnet URL proxies to that listener.
For the verified instance, port 4001 proxies to local port 4000. A 401 without
credentials confirms the listener is answering; an authenticated page and live
connection confirm the dashboard is usable.

## New-machine handoff — orangekid-opus (2026-07-18 ~22:40 PDT)

Supersedes all checkpoints below. Run is post-54: 54/54 core merged long ago;
this session did the Claude-prototype parity pass + adhoc/post-deploy saturation,
then hit a self-inflicted CI-baseline break now being repaired.

### ⛔ OPERATING RULE (operator directive, non-negotiable)
**Never merge anything to `develop` without opening a PR and letting CI run the
FULL test suite green first.** No direct branch→develop merges — not for agent
tickets, not for my own parity/adhoc batches, not for "verified locally" fixes.
Always: push branch → `gh pr create --base develop` → wait ALL required checks
green (`gh pr checks`) → merge on green. Local `mix compile`/`credo`/affected
`mix test` is a pre-filter, NOT a substitute for CI (it misses dialyzer +
browser-harness). This rule exists because I broke it (see blocker below).

### ⛔ CURRENT BLOCKER: develop CI baseline is RED
`develop` @ `37f337ea`, `ci` = FAILURE. I direct-merged the #1270 parity batches
(BO card-trim `ffc02764`, Units trim `dbc472d7`) running only partial local
checks, and they broke two required jobs:
- **dialyzer**: `pattern_match_cov` dead clauses in
  `build_order_graph.ex` (node_lane_label, label/1). **FIXED** on branch.
- **browser harness**: card-trim + Units-trim broke `build-order-route`,
  `ticket-context` (incl. a REAL 44px touch-target a11y regression on
  `.ticket-context-cta`), and `units` specs; `build-order-performance:153` is a
  load flake. The harness stops at first failure, which masked the later ones.

**Fix in flight:** branch `fix/develop-baseline-ci` (subagent, latest push
`93d12121`). dialyzer + build-order-route done; subagent is extending it to make
the FULL `cd src/browser && npm test` chain green (44px = product CSS fix in
`dashboard.css`; intended renames/status-chip = test updates; perf = confirm
load-flake). **Finish path:** when green → open PR → CI full-green → merge. Then
the 6 agent PRs below auto-rebase onto green (post-#720 develop push notifies
running agents) and get merged one-by-one on green.

### ⚠️ Backend quota — CODEX IS EXHAUSTED (stay on claude)
As of 2026-07-18, codex weekly quota is **99/100 used, resets in ~4 days**
(`reset_at` 1784780144 ≈ 2026-07-22). Config stays on `claude:opus` (working).
Operator decision this session: keep claude, note codex here. **Do NOT flip
routing to codex before the reset** — agents would stall on the first request.
After reset (or if claude gets constrained), flip `.aiur/config` routing tiers
1-5 → `codex:gpt-5.6-terra:high` (valid recent model) and `kind: codex`, then
rebuild the daemon. Check `.aiur/model-usage.json` `backends.codex.weekly` for
live quota before switching. The 6 agent PRs (below) need NO agent turns to
merge — they land via CI-green after `develop`'s baseline fix, so backend choice
does not block finishing the run.

### Aiur agents state (THIS machine, orangekid)
Daemon RUNNING: release 0.0.4 from `/home/orangekid/github/aiur-runtime-develop`
@ develop `37f337ea`, `--bg --debug --max-agents 15 --host <dashboard-host>`,
Tailscale dashboard `http://<dashboard-host>:4000` (basic-auth aiur / see `.env`),
tmux session `aiur-orangekid-0f62c25cdf-default`.
- 6 adhoc/post-deploy dispatched → all opened PRs, **all UNSTABLE (blocked on the
  red baseline, not their own fault):** #1274 (#1212 CodeownersTest flake),
  #1275 (#1251 price-partition dims), #1276 (#1142 adaptive monitoring),
  #1278 (#1152 aiur init bot), #1279 (#1210 effort labels), #1280 (#1273 teardown
  flake). Some agents still `running`/`paused`; #1030 is a stale idle leftover.
- Pre-existing unrelated open PRs: #1039 (draft, DIRTY), #1012 (DIRTY) — not mine.
- Prior adhoc #1259 + #1267 already merged.

### DONE + live this session (all at <dashboard-host>:4000)
- **Build Order graph RENDERS** (was totally broken — fell back to a text list).
  Three-layer bounds fix: MAX_COORDINATE 4095→65535 in worker+client, then
  protocol.js validCoordinate/validExtent/geometryBounds → same bound (kept
  MAX_DIMENSION for node sizes), then `direction: "RIGHT"→"DOWN"` in
  `measurement.js` for the design's top-down phase-row layout. 54 nodes, ~107
  edges, is-layout-ready. Regression test added at protocol level.
- **"Operator Control Center" rename** (was "Dashboard").
- **Units/Commands/Build Order** card parity: modal deps, header CTAs, Cx badges,
  progress bars, edge legend, filler trims, plain-language state messages.
- Preview `docs/build-order/plan-preview.html` refreshed (54/54) + served copy
  (`/tmp/aiur-pr1064-pack/...`) byte-identical.

### #1270 — Executor-owned findings ticket (STILL OPEN)
The dashboard functional-parity findings ticket. Biggest gap (graph render) is
CLOSED. Residual: minor parity items + an optional epic-column-alignment
refinement (current top-down layout is functional but not a strict matrix —
operator chose "match the design grid"; direction:DOWN got the phase-row
orientation; strict columns not pursued given real data has 15-19 nodes/wave).

### NEW-MACHINE bring-up (for the continuing agent)
The daemon runs on THIS machine only. On the new machine you must recreate:
1. **Runtime checkout**: clone/worktree the repo at branch `develop` as
   `~/github/aiur-runtime-develop` (separate from the working repo). Preserve
   machine-local `.aiur/config` (host/port/routing → claude:opus, aiur-claude) and
   `.aiur/model-usage.json`.
2. **Secrets**: `.env` with `AIUR_DASHBOARD_USERNAME=aiur` +
   `AIUR_DASHBOARD_PASSWORD` (32-char) — REQUIRED for the Tailscale bind + auth.
3. **Build+launch** (GATE-004 resolved via LOCAL build, no npm publish):
   `cd runtime && scripts/aiurdev stop` (reap orphans: kill leftover
   `opencode serve` PIDs), `scripts/aiurdev build`, then
   `set -a; . .env; set +a; scripts/aiurdev --bg --debug --max-agents 15 --host <tailscale-ip>`.
   Engine injects `--host 127.0.0.1` UNLESS `--host` is passed — must pass it for
   the Tailscale bind. Static assets (aiur-dom-svg-layout/*, measurement.js) are
   served by PATH (editable live, no rebuild); vendored elk worker/client are
   content-hashed (`manifest.json` sha256) — regen via `npm run vendor:elk`.
4. **Rebuild the daemon every few tickets** (#1191). Don't run
   `watch --full`/`alerts --needs-attention` (#1231).
5. **Screenshot/verify**: playwright 1.61.1 at
   `~/.npm/_npx/<hash>/node_modules` (run scripts FROM that dir so ESM resolves),
   chromium at `~/.cache/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`). Verify graph
   changes by RENDERED screenshot, not the data model — that mistake cost 3
   rebuild cycles this session.
6. **rpc into the node**: `RELEASE_DISTRIBUTION=name RELEASE_NODE=<node>@127.0.0.1
   RELEASE_COOKIE=<from /proc/<beam-pid>/environ> <release>/bin/aiur rpc '...'`.

### To FINISH the run (my remaining steps before handoff is clean)
1. Baseline fix fully green → PR → CI green → merge (rule above).
2. 6 agent PRs rebase onto green develop → merge each on green.
3. Rebuild daemon after the merges; refresh preview.
4. Close #1270 or hand it to the next agent with the residual list.

---

## Archived checkpoints

Everything below the current handoff moved to `executor-handoff/` unchanged (the private dashboard address is now `<dashboard-host>`). Heading text is preserved inside each file.

| Section | Date | Archive |
| --- | --- | --- |
| Wind-down checkpoint — macbook-fable | 2026-07-17 | [2026-07-17-wind-down-checkpoint.md](executor-handoff/2026-07-17-wind-down-checkpoint.md#wind-down-checkpoint--macbook-fable-2026-07-17-2230-pdt) |
| Takeover checkpoint | 2026-07-17 | [2026-07-17-takeover-checkpoint.md](executor-handoff/2026-07-17-takeover-checkpoint.md#takeover-checkpoint-updated-2026-07-17-2010-pdt) |
| Current Executor checkpoint | 2026-07-17 | [2026-07-17-current-executor-checkpoint.md](executor-handoff/2026-07-17-current-executor-checkpoint.md#current-executor-checkpoint-updated-2026-07-17-1512-pdt) |
| Recovery checkpoint | 2026-07-17 | [2026-07-17-recovery-checkpoint.md](executor-handoff/2026-07-17-recovery-checkpoint.md#recovery-checkpoint-updated-2026-07-17-0659-pdt) |
| Live Executor state | 2026-07-15 | [2026-07-15-live-executor-state-p1.md](executor-handoff/2026-07-15-live-executor-state-p1.md#live-executor-state-updated-2026-07-15-2057-pdt) |
| Live Executor state (part 2) | 2026-07-15 | [2026-07-15-live-executor-state-p2.md](executor-handoff/2026-07-15-live-executor-state-p2.md) |
| Live Executor state (part 3) | 2026-07-15 | [2026-07-15-live-executor-state-p3.md](executor-handoff/2026-07-15-live-executor-state-p3.md) |
| Live Executor state (part 4) | 2026-07-15 | [2026-07-15-live-executor-state-p4.md](executor-handoff/2026-07-15-live-executor-state-p4.md) |
| Live Executor state (part 5) | 2026-07-15 | [2026-07-15-live-executor-state-p5.md](executor-handoff/2026-07-15-live-executor-state-p5.md) |
| Live Executor state (part 6) | 2026-07-15 | [2026-07-15-live-executor-state-p6.md](executor-handoff/2026-07-15-live-executor-state-p6.md) |
| Start gate … Adjacent delivery that must not be lost (standing contract) | 2026-07-15 | [standing-contract.md](executor-handoff/standing-contract.md#start-gate-historical-contract-explicitly-overridden-for-this-run) |
