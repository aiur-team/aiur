# Executor handoff — Analytics + Streamdeck build order

Living document. A replacement Executor (Claude or Codex) resumes from here.
Branch `executor-handoff` off `origin/develop` is the research+handoff branch
for this build order; keep updating it as the run proceeds.
Last update: 2026-07-30. Build order root: #1363. Pack: docs/build-orders/analytics-streamdeck/ (validated, 0 errors). All 26 members carry model:codex.

## Role and authority envelope

You are the **Aiur Executor** per `.claude/skills/aiur-run` (+
`references/executor.md`). Operator: its-everdred (Kevin).

Recorded authority:
- **Scope**: the "Analytics + Streamdeck" build order (three independent
  branches: Analytics #991+#1338–#1341; Streamdeck #1342–#1356 + pending
  packaging/proof tickets; Security ~4 tickets TBD from
  `docs/research/security-trust-boundary.md`). Branches must never share a
  critical path.
- **Ticket creation**: YES — standing directive: "add tickets along the way
  to have agents resolve issues you find, unless they're truly preventing
  aiur agents completely then you own the ticket and unblock." Executor
  self-fixes ONLY fleet-blocking issues (#1313/#1231/#852-class, launch
  config); everything else becomes a ticket.
- **Review**: YES — `/ce-code-review` via background agents once base is
  current + CI green on the exact head.
- **Merge**: merge into `develop` under green CI + review (operator has
  repeatedly authorized merge-to-develop this session).
- **Models**: default every ticket to **Codex**; fall back to Claude only
  when Codex fails or stalls.
- **Concurrency**: maximize useful parallelism; serialize the dashboard-ui
  clique (`dashboard_live.ex`, `router.ex`, `route_registry.ex`,
  `dashboard.css`) and the monorepo scaffolding ticket #1343.
- **--debug**: YES (also required so the run records its own telemetry
  pre-#1338).
- **Cadences**: adaptive quiet audit + hard 10-min capacity audit + hourly
  retrospective, one stable run ID, via
  `<skill>/scripts/executor-retrospective.sh`.
- **Terminal condition**: all three branches implemented, reviewed, green
  on develop, merged, documented; end-to-end proof includes `/analytics`
  rendering real charts **of this very run**, and the streamdeck emulator
  (+ device if #1342 passes) driven by live fleet state.

## Launch

```bash
cd ~/github/everdred/aiur   # NOTE: verify branch state first (see Hazards)
AIUR_DASHBOARD_USERNAME=… AIUR_DASHBOARD_PASSWORD=…   # set in .env; report to operator
scripts/aiurdev run --bg --debug --host 0.0.0.0 --port 4000 --max-agents <n>
```

- Dashboard external URL (operator bookmark): **http://100.89.62.105:4000/**
- `.aiur/config` pins `server.host: 100.81.109.51` — a **stale tailnet IP**;
  that's why nothing was reachable. Use `--host 0.0.0.0` (survives tailnet
  IP changes) rather than editing the file.
- Non-loopback + writable requires BOTH dashboard env creds or the HTTP
  server refuses to start (`http_server.ex:102-122`).
- Usage endpoint floor: min 120 s between Claude usage polls (enforced in
  config schema); polling is watch-gated.

## Hazards / repo state

- `~/github/everdred/aiur` was shared with another agent (branch
  `croptracker`, then `build-order-improvements`) with uncommitted edits to
  `.aiur/prompt.md`, `src/config/config.exs`, `run_summary_strip.ex`,
  `dashboard.css`. **Do not clobber.** Verify `git status` before building;
  coordinate with operator if still dirty.
- Worktrees: `../aiur-worktrees/pre-warm-fix` (fix/pre-warm, clean),
  `../aiur-worktrees/executor-handoff` (this branch).
- `pkill -f`/`pgrep -f` self-match → exit 144; use `pgrep -x beam.smp`.
- `mix` project lives in `src/`; run via `mise exec --`. `mix lint` is
  stricter than credo. Coverage gate 85%.
- Sandbox fixture issue **#99 must stay open and never be dispatched**
  (test_reset.ex restores its file on every `aiur --test`).
- **Do NOT run the full `mix test --cover` suite locally** — it is
  processor-intensive and competes with the fleet. Let CI run it. Agents may
  run a single focused test file as a self-check, but coverage/full-suite
  verification is CI's job (push and read the check). Applies to Executor and
  every dispatched/spawned agent.

## Ticket state (as of last update)

Filed: #1338 #1339 #1340 #1341 (analytics) · #1342–#1356 (streamdeck, see
`docs/research/streamdeck-architecture.md` for the layer map). #1337
(prewarm) exists, deliberately not started.
Pending to file: streamdeck packaging/udev/systemd ticket + end-to-end
proof ticket; ~4 security tickets (research pack in
`docs/research/security-trust-boundary.md`, GitHub-side research re-running).
**#1342 needs a body update**: recommendation flipped from OpenDeck-first to
direct-HID Node sidecar first (see architecture doc §Decision + Spike
order); spike steps changed.

Backlog decisions awaiting operator: close #1084 (54/54 closed, proof gate
unverified), #1311 (8/8 closed), #963 (premise deleted), #1175 (already
fixed), #1315 (dup of #1325). Do-not-dispatch: #1067, #927, #928, #99.
Consolidation clusters: {1007,1016,1330} {1018,1059} {927,928,1337}
{1182,1245}.

## Dependency skeleton for /aiur-build

- Analytics: #991 → #1338 → {#1340, #1341}; #1339 ∥ after #991.
- Streamdeck: #1342 (gate) and #1343 (scaffold) first; then Elixir
  {#1344,#1345,#1346,#1347} ∥ core {#1348,#1349} → {#1350,#1351} →
  emulator #1352 → #1353; device {#1354 → #1355,#1356} blocked by #1342.
  #1345→#1350; #1347→#1351; #1346→#1356 (provider segments).
- Security: independent of both; file then wave by files touched.
- Cliques: dashboard-ui (#1352/#1353 + any dashboard ticket) — serialize;
  #1343 alone touches root/CI files — land before other streamdeck work.

## Pending operator event: org transfer

The operator intends to transfer its-everdred/aiur to an organization.
When it happens: (1) verify its-applekid has org access immediately or the
fleet token 404s; (2) sweep hardcoded `its-everdred/aiur` references
(.aiur/config tracker, build-order pack `repository`, scripts, docs);
(3) re-verify branch protection/rulesets (#1362); (4) the Executor trials the NATIVE merge queue directly —
#1381 is DEQUEUED by operator decision; write no code up front. Watch for
edge cases, especially flaky tests halting the queue (a flake in a
speculative batch ejects innocent PRs and stalls the line — the
{#1007,#1016,#1330} cluster is live) and queue depth at ~13-min CI cycles.
File tickets only for observed gaps. Prefer a quiet point in the run.

## Monitoring quick reference

```bash
AIUR_CMD=scripts/aiurdev
"$AIUR_CMD" status; "$AIUR_CMD" watch --full; "$AIUR_CMD" alerts --needs-attention
RETRO=".claude/skills/aiur-run/scripts/executor-retrospective.sh"
export AIUR_EXECUTOR_RUN_ID=analytics-streamdeck-2026-07   # keep stable
```

Wake immediately on needs-attention alerts / agent-state changes / PR-CI
results; otherwise adaptive quiet audit. Never satisfy the 10-min capacity
audit by waking ci-wait/blocked tickets.

**HARD RULE (postmortem 2026-07-30): every wake — timer tick, task
notification, or operator ping — starts with `watch --full` (read the
ACTIONABLE section first) + `alerts --needs-attention`, BEFORE the thing
that woke you.** Failure mode observed: the Executor spent ~5 ticks polling
one PR's CI check while 13 agents sat paused and 4 claims were released by
tracker 403s — the operator saw a red board the Executor called quiet.
A single in-flight blocker (merge-gate CI) does not make the fleet quiet;
polling one metric is not an audit. The 10-minute capacity audit is these
two commands, run unconditionally.

Known incident signatures:
- `orchestrator.retry_poll.exhausted` + HTTP 403 = GITHUB_TOKEN rate limit
  (5000/hr shared by daemon + all agents = #678 live). While GITHUB_TOKEN
  is set, aiur uses ONLY it — the keyring is not a fallback. Recovery:
  wait for the hourly reset (check `gh api rate_limit` AS the token), then
  `resume` every paused ticket. If it recurs in the same run, promote #678
  as a P1 fleet-blocker.
- Mass `ticket.*.agent.paused` after tracker failures: agents do not
  auto-resume when the tracker recovers — the Executor must `resume` each.
- Alerts persist across restarts and tokens (full-history scan, #1231):
  check the timestamp before acting; e.g. a push-blocked alert may predate
  a token fix and the push may have since succeeded (verify branch head vs
  PR head before intervening).

### Hourly meta-analysis (operator-directed)

**Organizing frame — perpetual bottleneck hunt (operator philosophy,
verbatim intent): there will always be a next bottleneck; this check is
never complete.** Each hour, name THE single thing currently costing the
most wall-clock across the run, quantify it, and propose one way to reduce
or eliminate it. When one falls, find the next. Observed chain so far:
red develop base → serial 1-by-1 merges (→ native merge queue, watching
for flake-halts) → likely next: test-suite runtime (#1378) or flaky-test
ejections ({#1007,#1016,#1330}) → possibly the Executor itself not keeping
up with 20+ agents (then: more background-agent delegation, or the
#1380 executor event bus replacing polling). Always answer: what is the
latest thing taking the most time, and how do we shrink it?

Every hourly retrospective must include a **meta-analysis note**: what
classes of problem recurred in the past hour, and a candidate systemic fix
so the next hour is smoother — not just per-incident firefighting. Look for
patterns, not one-offs. Examples:
- Repeated failing/flaky tests across tickets → file a larger test-fix /
  refactor ticket (or a shared-fixture/harness fix) rather than patching each.
- Repeated stale-base or merge thrash → tighten clique serialization or land
  a base-refresh cadence.
- Repeated same-file conflicts → re-partition write surfaces / split a ticket.
- Repeated token/scope/permission stalls → fix the credential once.
- Repeated model failures on a ticket class → adjust the codex→claude
  fallback trigger for that class.
Record the pattern, the proposed systemic fix, and whether it was filed or
deferred, in the retrospective log alongside the action/no-action counts.
File at most one or two evidence-backed systemic tickets per pattern under
normal issue authority; do not expand the active feature boundary with them.

### Daily skill-improvement review (operator-directed)

Once per day, review the accumulated hourly meta-analysis notes and ask
whether any Aiur skill would benefit from what we learned — most importantly
`.claude/skills/aiur-run` (SKILL.md + references/executor.md) and its
siblings (`aiur-build`, `aiur-monitor`, `aiur-agent`). The hourly notes catch
recurring run-level problems; this daily pass asks whether the *playbook that
governs future runs* should change so the next Executor never rediscovers the
same lesson. Examples: a recurring stale-base pattern → add a base-freshness
step to the run loop; a credential/scope stall → add a preflight scope check;
a flaky-test class → add a "quarantine + file refactor ticket" rung to the
recovery ladder. Capture each candidate as a concrete skill-doc edit (which
file, what change, why), and either file it as a skills-improvement ticket or
record it in the deferred ledger. These are process/tooling improvements
outside the active feature boundary — never let them expand this build
order's scope.

## Context you'd otherwise have to rediscover

- Analytics emptiness root cause + piping map:
  `docs/research/analytics-tickets.md`.
- Stream Deck architecture decision (direct-HID sidecar), full HID facts,
  failure modes, monorepo/CI facts: `docs/research/streamdeck-architecture.md`.
- Security trust-boundary map + planned 4 tickets:
  `docs/research/security-trust-boundary.md`.
- Design source: Claude Design project "Aiur Operator Control Center"
  (id 5e62b9a9-39c1-4ca2-9a76-6dff123a088c) — analytics.js + streamdeck
  panel JS/CSS already fully extracted into the research docs and tickets.
