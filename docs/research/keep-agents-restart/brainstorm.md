---
title: Keep-agents daemon restart - Plan
type: feat
date: 2026-10-09
topic: keep-agents-restart
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
base_main_sha: 9940eed44
---

# Keep-agents daemon restart - Plan

## Goal Capsule

- **Objective:** `aiur restart --keep-agents` replaces the daemon (new code,
  new config) while every local agent keeps running its turn. The new daemon
  re-attaches to each agent by a stable id. No ticket is re-dispatched and no
  claim is released.
- **Product authority:** Kevin, 2026-10-09: "previous executors and perhaps
  yourself have been hesitant to restart [aiur] while we're making improvements
  to avoid halting the entire fleet and having it regenerate use agents. I'd
  like you to research and add a ticket for a flag that we can add to restart
  that keeps the agents running and auto reconnects them to the new instance of
  [aiur]. That way we can be a lot more free and frequent when it comes to
  restarting [aiur] after all new features are added without halting the
  fleet."
- **Open blockers:** none for planning. Operator questions are at the end, each
  with a recommendation that the plans assume.

## Summary

Run each agent behind a small detached **agent relay** that owns the
provider's stdio and journals its output. Move Claude REPL panes to their own
tmux server. On `restart --keep-agents`, the old daemon quiesces, writes a
versioned **handoff record**, and exits without reaping agents. The new daemon
reads the record before its first tick, checks compatibility per agent, and
adopts each compatible agent mid-turn. An incompatible agent falls back to
today's path (stop, keep the claim, redispatch with resume).

## Problem Frame

Today `aiur restart` is stop + rebuild + start (`cmd_restart` in
`packaging/npm/aiur-cli/libexec/aiur-engine.sh`). Stop kills everything:

- **Headless agents** (Codex app-server, `aiur-claude`) are BEAM Ports
  (`Aiur.AppServer.Adapter.start_port/4`, own process group). Their stdio dies
  with the BEAM, and `Aiur.ProcessReaper` plus the engine's `reap_aiur_agents`
  and BEAM-death watchdog kill the trees on purpose.
- **Claude REPL agents** are panes on the same private tmux server as the BEAM
  pane. `cmd_stop` runs `kill-session` and then `kill-server`.

Measured costs from this run:

- Every in-flight turn is lost. The primary backend (`claude`, headless
  `aiur-claude`) is `resumable: false`: its thread map is in memory only
  (`src/lib/aiur/coding_agent/providers/claude.ex`), so each Claude agent
  starts a cold conversation and re-discovers its work.
- Orphan claims are released and tickets re-dispatched
  (`Aiur.Orchestrator.StartupClaimReconciler`; #3660, #3667, #3711).
- The first poll after boot takes 5-20+ minutes with zero dispatch on about
  130 open tickets. It does serial dispatch-authorization timeline reads, and
  that cache is ETS only (`Aiur.GitHub.DispatchAuthorization`).
- The AIMD dispatch envelope starts at 1 slot (#3768 open).
- Prewarmed sessions are rebuilt.

So Executors batch merges and delay restarts, and merged fixes stay inert
("merged code is inert until rebuilt").

## What already survives a restart (verified at 9940eed44)

| State | Where | Survives? |
|---|---|---|
| Session handle (thread id) | `Aiur.SessionHandle`, runtime state dir | yes |
| Event subscriptions | `Aiur.Events.SubscriptionStore`, per-issue JSON | yes |
| Dynamic-tool outcomes | `Aiur.AppServer.ToolCallLedger` (claim before run, uncertain tombstone) | yes |
| Build-gate holds | detached `build_gate_holder.py` | yes, independent of the BEAM |
| GitHub ETags, processed marks | `Aiur.GitHub.ResourceStore` | yes |
| DecisionStore, global pause, wake inbox | on disk | yes |
| Running map, workspace leases, retry timers | Orchestrator state, ETS registry | **no** |
| Dispatch-authorization timelines | ETS | **no** |
| Agent processes and their stdio | BEAM Ports, shared tmux server | **no** |

The gap is narrow: the agent processes, the running entries and leases, and
one cache.

## Approaches

**A. Agent host outside the BEAM, re-adopted by stable id (chosen).** A
per-agent relay process owns the provider's stdio, appends every output frame
to a journal, and serves one controller over a Unix socket. REPL panes move to
an agent-only tmux server. The daemon becomes a reconnectable client.
- Pros: agents never notice the restart except slower tool replies. Works for
  every local backend, including the non-resumable headless Claude.
- Cons: a new long-lived component and a new transport layer; adoption must
  rebuild turn state mid-turn.
- Risk: two daemons driving one agent; mitigated by generation fencing.

**B. Hot code reload in the running node.** Load changed modules into the
live BEAM.
- Rejected. The repo ships whole releases with no appups, relup or
  `code_change/3` (none found). About 119 files define GenServers whose state
  shapes change often; supervision-tree and config changes need restarts; a
  second reload purges old code and kills long-running turn-loop processes.
  MP-R1-C5-T01 and MP-R7-C3-T01 already record "aiur ships whole releases,
  not hot code upgrades". Every failure mode here is silent corruption, not a
  clean refusal.

**C. Drain, then native resume in the new instance.** Stop dispatch, let
turns end (or interrupt at a safe checkpoint), restart, resume sessions.
- Rejected as the primary path. It does not keep agents running. Turns can
  last up to the 60-minute stall timeout. The primary backend cannot resume.
  It is kept as the per-agent **fallback** for agents that fail the
  compatibility check, because it is today's path plus `SessionHandle` resume.

**Challenger considered: one shared host BEAM node** that owns all Ports and
talks to the daemon over Erlang distribution. Rejected for the per-agent
relay: one host node is a single point of failure for the whole fleet, needs
its own release lifecycle and cookie, and upgrading it is a full restart
anyway. A per-agent relay fails one agent at a time and upgrades naturally
(new agents get the new relay; the daemon reads relay protocol N and N-1).
Detached helpers already have a precedent: `build_gate_holder.py` exists so
"a running Mix command never depends on an Aiur BEAM staying alive".

## Product Contract

### Requirements

- R1. `aiur restart --keep-agents` (and `aiurdev restart --keep-agents`)
  replaces the daemon while local agents keep running.
- R2. An adopted agent continues the same turn, the same provider process and
  the same conversation. No new claim, no `agent:*` label change, no dispatch
  attempt is billed for it.
- R3. Frames the agent emits while no daemon is attached are delivered to the
  new daemon in order, with none lost and none duplicated.
- R4. A tool call or approval the agent sends during the gap is answered after
  adoption. A tool call that was running in the old daemon at quiesce is
  completed before the old daemon exits, or answered from the ToolCallLedger;
  it never runs twice.
- R5. Only one daemon controls an agent at any time. A newer controller fences
  out an older one.
- R6. The new daemon checks compatibility per agent before adopting it. A
  failed check stops that agent and takes today's path for its ticket (claim
  kept, redispatch with resume). The restart report names each fallback and
  its reason.
- R7. If the running daemon cannot hand off (old build, not up, no relays),
  `--keep-agents` aborts before it stops anything and says why.
- R8. If no daemon adopts the agents within a timeout (failed rebuild,
  operator walked away), relays stop their agents. Agents never run
  unsupervised for long.
- R9. Adopted tickets keep their workspace, lease, retry counters, turn
  counter, token totals and max-duration clock.
- R10. Claims of adopted tickets are protected before the startup claim
  reconciler and the orphaned-worker check first run.
- R11. Dispatch of new work resumes within one poll cycle of the new daemon's
  boot. The envelope starts at no less than the adopted count.
- R12. The first poll after any restart reuses the persisted
  dispatch-authorization cache instead of serial cold timeline reads.
- R13. New config applies to new dispatches. Adopted agents keep their
  launch-time model, effort and backend command.
- R14. `aiur status` and the restart output show the handoff: adopted count,
  fallback count with reasons, handoff id, gap duration.
- R15. Remote-worker (SSH) agents keep today's behaviour and are listed as
  fallbacks with reason `remote_worker`.

### Key Decisions

- **Per-agent relay, written in Python, in `src/priv/`.** Python is already a
  runtime dependency (`github_budget.py`, `build_gate_holder.py`,
  `pidfd_reap.py`), it handles Unix sockets and subprocess pipes well, and it
  needs no BEAM. An Elixir escript would start a VM per agent; a Rust or Go
  binary would add a build toolchain.
- **Journal on disk, not a memory ring.** Output frames go to an append-only
  per-agent file; the daemon acks byte offsets. A long gap (a slow rebuild)
  then costs disk, not lost frames, and the journal doubles as debug evidence.
  Rotation is bounded.
- **Generation fencing.** Each daemon boot gets a monotonic generation stored
  on disk. A relay accepts an attach only with a generation above its last
  one and closes the older connection. This, plus the existing node-name and
  launch-lock guards, gives R5.
- **Handoff record is an explicit versioned JSON document**, not a dump of
  Orchestrator state. Internal struct changes then never break adoption; only
  a `handoff_schema` change can, and that is a clean, reported refusal.
- **Build ordering unchanged.** The rebuild still runs after the stop, because
  it rewrites the release in place under a live BEAM. With agents kept alive,
  the gap costs delayed tool replies and delayed dispatch, not lost work.
  Staged release directories (build before stop) are a later improvement.
- **Pre-stop failure aborts; post-stop failure falls back per agent.** A
  silent full restart under `--keep-agents` would kill the fleet the operator
  asked to keep.
- **Relay orphan timeout: 30 minutes**, configurable. Long enough for a slow
  rebuild and one retry; short enough that a forgotten fleet stops.
- **Fallback is today's path plus resume**, not a new path, so it is already
  tested.

### Key Flows

- F1. **Keep-agents restart.**
  - **Trigger:** operator or Executor runs `aiurdev restart --keep-agents`.
  - **Steps:** preflight RPC confirms the daemon can hand off; daemon
    quiesces (holds dispatch, blocks new turn starts, waits up to 60 s for
    running tool calls, flushes the timeline cache); daemon writes the
    handoff record and acks every relay offset; engine stops only the BEAM
    (stop sentinel marked `handoff`, watchdog and reaper skip relays and the
    agent tmux server); rebuild; start; new daemon reads the record, checks
    each agent, adopts or falls back, deletes the record.
  - **Outcome:** report lists adopted and fallback agents and the gap
    duration; dispatch resumes on the first tick.
- F2. **Failed rebuild under keep-agents.**
  - **Steps:** relays keep agents running and journaling; the record stays;
    the next successful start within the orphan timeout adopts them; past the
    timeout relays stop their agents and the next start takes today's path.

### Acceptance Examples

- AE1. With N >= 4 local agents mid-turn (mixed Codex, headless Claude and
  REPL Claude), `aiurdev restart --keep-agents` ends with the same N provider
  pids alive, each turn completing in its original conversation, zero
  dispatch events and zero claim comments for those tickets, zero
  StartupClaimReconciler releases, and the first dispatch of new work within
  one poll interval of boot.
- AE2. A Codex agent calls a dynamic tool while no daemon is attached. After
  adoption the tool runs once and the agent receives the result.
- AE3. A handoff record with an unknown `handoff_schema` stops all relay
  agents, logs one alert, and each ticket redispatches with resume, exactly
  like today's restart.
- AE4. A second daemon process that attaches with an older generation is
  refused; the current controller keeps the agent.
- AE5. `--keep-agents` against a build without the handoff RPC exits non-zero
  before stopping anything.

### Scope Boundaries

- In scope: local Codex app-server, headless Claude (`aiur-claude`), Claude
  REPL; muse if it uses the same app-server adapter (planning checks).
- Out of scope: remote SSH workers (fallback only); hot code reload; staged
  release directories; keeping agents across a host reboot.

### Dependencies / Assumptions

- #3768 (persisted dispatch envelope) gives the "resume near last safe level"
  part of R11; keep-agents adds the adopted-count floor.
- MP-R7 (harness adapter package) moves the same adapter code. The relay
  transport must land through the backend seam, and the two lanes serialize on
  `src/lib/aiur/app_server/adapter.ex`. This is a conflict, not a dependency.
- Paseo (#2573, PSO-012 "restart re-attach") is an external agent host with
  its own re-attach. It is unreleased and opt-in; it does not replace this.
- Assumption: provider processes do not depend on their parent pid being the
  BEAM (true for Codex app-server and `aiur-claude`; planning verifies with
  a spike).

### Open questions for Kevin

1. **Default.** Should `--keep-agents` become the default for `restart` once
   it proves itself? Recommendation: yes, after two weeks with zero
   fallback-caused re-dispatch; keep `--full` for today's behaviour.
2. **Pre-stop failure.** Abort (assumed) or fall back to a full restart?
   Recommendation: abort; a flag that sometimes kills the fleet is not one
   Executors will trust.
3. **Orphan timeout.** 30 minutes assumed. Recommendation: keep 30.
4. **Config change semantics.** Adopted agents keep launch-time model and
   effort (assumed); a lowered `max_concurrent_agents` adopts all and only
   blocks new dispatch. Recommendation: accept.

## Sources / Research

- Restart path: `scripts/aiurdev` (`builds_after_stop`,
  `AIUR_RESTART_BUILD_CMD`), engine `cmd_stop`, `cmd_restart`,
  `reap_aiur_agents`, `start_beam_death_watchdog`.
- Agent spawn: `src/lib/aiur/app_server/adapter.ex` (`Port.open`, setsid),
  `src/lib/aiur/codex/app_server_port.ex`, `src/lib/aiur/claude/repl/launcher.ex`,
  `src/lib/aiur/claude/hook_settings.ex` (hook is `curl -m 2`, dropped when the
  dashboard is down).
- Ownership: `src/lib/aiur/process_reaper.ex`,
  `src/lib/aiur/orchestrator/orphaned_workers.ex` ("The runner is stopped, not
  adopted"), `src/lib/aiur/orchestrator/startup_claim_reconciler.ex`.
- Persistence: `src/lib/aiur/session_handle.ex`,
  `src/lib/aiur/events/subscription_store.ex`,
  `src/lib/aiur/app_server/tool_call_ledger.ex`, `src/lib/aiur/build_gate.ex`,
  `src/lib/aiur/github/resource_store.ex`,
  `src/lib/aiur/github/dispatch_authorization.ex`.
- Prior research: `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R7/plan.md`
  (harness seam, no supervisor split planned), MP-R1-C5-T01 (whole releases).

## Ticket split

| Plan | Ticket scope | Depends on |
|---|---|---|
| [plan-ka1-agent-relay.md](plan-ka1-agent-relay.md) | Relay process and daemon transport for app-server backends | - |
| [plan-ka2-repl-survives.md](plan-ka2-repl-survives.md) | REPL panes on an agent tmux server; hook spool | - |
| [plan-ka3-handoff-adopt.md](plan-ka3-handoff-adopt.md) | Quiesce, handoff record, adopt on boot, per-agent fallback | KA1, KA2 |
| [plan-ka4-cli-verify.md](plan-ka4-cli-verify.md) | `--keep-agents` CLI, engine stop path, status report, docs, e2e test | KA3 |
| [plan-ka5-warm-first-poll.md](plan-ka5-warm-first-poll.md) | Persist dispatch-authorization cache; envelope floor | #3768 |
