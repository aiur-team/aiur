# Daemon BEAM crash under sustained CPU saturation — root-cause analysis (#1429)

Follows from #852 (daemon BEAM crash at high concurrent agent load). This record
pins the diagnosis from the evidence available on the retained crash dumps, the
code, and the post-crash hardening that has since shipped. It does **not** claim
a captured crash under the current build — that confirmation is owned by the
controlled reproduction in [`scripts/aiur-saturation-repro.sh`](../../scripts/aiur-saturation-repro.sh)
and the saturation sentinel added here.

## Crash profile (#852)

- Daemon BEAM exited unexpectedly at **2026-07-09T15:00:14Z** (watchdog: no clean
  stop sentinel); whole fleet orphaned.
- Correlated with **total concurrency ≈ 16 mix-heavy processes**: 12 fleet agents
  + **4 external background PR-processors running uncapped `mix dialyzer`**,
  1-min load ~**48** on a **12-core** host. Stable at 12 fleet agents alone
  (idle 57–76%); fell over only after the external processors stacked load.
- Not OOM (24 GiB free), not FD/proc limits, not the ProcessReaper EXIT flood
  (fixed in #795), config fine (daemon kept last known good configuration).

## Measured ceiling (2026-07-31 capacity run)

The box saturates at **~19–20 concurrent agents** (load 14.09 of 16 cores). This
is the concurrency neighborhood the daemon destabilizes near.

## The only relevant retained crash dump (triaged in #1484)

| Field | Value |
| --- | --- |
| Slogan | `erl_child_setup: 104` (native port-spawn helper, `ECONNRESET`) |
| Timestamp | 2026-07-30 17:34:36 UTC |
| Runtime | OTP 28 / ERTS 16.4, **16 schedulers** |
| Processes | 964 |
| Crashing Erlang process / stack | **none reported**; scheduler 2 on `#Port<0.0>` |

The VM reports no crashing Erlang process or stack, so the dump establishes the
native port-spawn helper's connection reset but cannot identify the failed child
or distinguish churn from an exec/pipe failure. Per #1484, this is **explicit
insufficient evidence, not a confirmed ProcessReaper cause**. The two
`io:put_chars` dumps are excluded as daemon-instability evidence: they are
4-scheduler child BEAMs that inherited `ERL_CRASH_DUMP`.

**16 schedulers is the load-bearing fact**: the daemon that produced this dump
ran an *uncapped* scheduler set. Every agent BEAM did too (default = one
scheduler per logical core). The post-crash cap (#883, default 4) had not
shipped yet. This dump is a **pre-cap** artifact, and the pre-cap oversubscription
is exactly the regime the crash correlates with.

## Candidate-by-candidate analysis

### 1. Config hot-reload race under load — RULED OUT

`Aiur.WorkflowStore` caches the last known good workflow, retries reloads
(`@reload_attempts 3`, 50 ms backoff), tracks a `failed_stamp` so a failing path
is not repeatedly logged, and serves the last known good config on failure. The
#852 post-mortem independently confirmed "config was fine — daemon kept last
known good configuration." No race mechanism in the reload path can kill the
BEAM; at worst it serves a stale config.

### 2. Atom / ETS table limits — RULED OUT

- The only `:ets.new` call sites (6) create **fixed named tables at boot**
  (events exchange/publisher, operator wait log, tracked set, opencode active
  turns/token registry). No per-agent or per-run table is created, so table
  count does not grow with fleet size.
- `String.to_atom` / `binary_to_atom` uses are on validated, bounded keys
  (fixed field names), not on unbounded runtime strings.
- The crash dump shows **964 processes** — far below any `+Q`/atom/ETS ceiling.
  Nothing here is resource exhaustion.

### 3. Port/process churn beyond ProcessReaper capacity — NOT IMPLICATED

The dump's signature (native helper connection reset, no crashing Erlang
process, no stack) points at the **OS-level port-spawn path**, not at the BEAM's
reap registry:

- `Aiur.ProcessReaper` is a GenServer registry; it records and kills agent OS
  pids/panes. A **dead BEAM can reap nothing from inside itself**, so reaping
  capacity cannot be the BEAM's own death cause — the crash-pidfile + bash
  watchdog backstop (`AIUR_AGENT_TMPFILE`) exists precisely because the BEAM is
  dead at that point.
- The reaper's trapped-EXIT mailbox flood (a plausible churn amplifier) was
  fixed in #795 with a dedicated swallow clause.
- Process count 964 across ~16 agents is steady-state fleet footprint, not
  evidence of runaway spawn churn.

### 4. Scheduler thread exhaustion starving the native port-spawn helper — SURVIVING CANDIDATE

The pre-cap regime: **every BEAM (daemon + each agent + each external
`mix dialyzer` processor) defaulted to one scheduler per logical core.** On the
12-core crash host: 12 fleet agents × 12 + 4 external × 12 + daemon ≈
**200+ scheduler threads on 12 cores** (run-queue ~120, idle 0%, load 48). This
is the measured oversubscription profile from #840 (144 threads → load 73 at 12
agents uncapped; the same 12 agents capped at `+S 4:4` → 48 threads → load 7,
reaper held, no crash).

`erl_child_setup` is the ERTS **native** helper that forks/execs every OS
process the VM spawns. Under sustained total-CPU starvation the helper's
socket protocol to the VM can be reset (`ECONNRESET`, errno 104), and the VM
treats a dead port-spawn helper as **fatal** — it cannot spawn OS processes and
aborts. This exactly matches a dump with **no crashing Erlang process and no
stack**: the failure is in the native helper boundary, not in any Erlang
process.

**Conclusion: the daemon BEAM death under saturation is consistent with an ERTS
fatal abort on the native port-spawn helper (`erl_child_setup` ECONNRESET)
caused by extreme scheduler starvation in the pre-cap oversubscription regime.**
It is not a ProcessReaper, config, atom, or ETS defect. The trigger that pushes
the box past its ceiling is **external uncapped BEAM load** that the #465
dispatch gate does not count — the admission-side fix is owned by #1430
(measured-host-pressure admission), not this ticket.

## What has already shipped (and what this ticket adds)

| Item | Status | Owned by |
| --- | --- | --- |
| Crash-dump capture (`ERL_CRASH_DUMP` + `ERL_CRASH_DUMP_SECONDS=30`) | shipped | #856 |
| Agent scheduler cap (`agent.mix_scheduler_cap`, default 4) | shipped | #883 |
| Load-aware admission counting external load | queued | #1430 |
| Existing dump triage | shipped (analysis) | #1484 |
| **Root-cause document** | **this PR** | #1429 |
| **Controlled load reproduction** | **this PR** | #1429 |
| **Saturation sentinel (diagnosability)** | **this PR** | #1429 |

## How this gets confirmed

The pre-cap 2026-07-30 dump is the only daemon-instability capture and predates
the cap, so it narrows but cannot confirm. Confirmation requires a crash (or a
deliberate load run) **under the current build**, showing:

1. The daemon BEAM exits with an `erl_child_setup`-family slogan (`ECONNRESET`
   or `child_setup` fatal) and **no** Erlang process/stack — i.e., the native
   helper boundary again; or, alternatively,
2. The next dump shows a *different* failure mode than the pre-cap signature —
   which would reopen the analysis.

Two new mechanisms make that capture reliable and interpretable:

- **`scripts/aiur-saturation-repro.sh`** — an operator-run, bounded load
  reproduction that ramps the fleet to the measured ceiling and stacks external
  uncapped mix BEAM load (the exact #852 trigger) on top, watching the daemon
  BEAM and the `$AIUR_LOGS_ROOT/erl_crash.dump`. It converts "wait for the next
  crash" into "reproduce on demand."
- **`Aiur.SaturationSentinel`** — a small daemon-side worker that, as 1-min load
  crosses the dispatch hard gate (default 1.5× cores) toward the fatal zone,
  appends VM-internal + host diagnostics (schedulers, process/port/atom/ETS
  counts, load, memory) to a durable `saturation.log` beside the daemon log.
  Even a sparse `erl_child_setup` dump (no stack) becomes interpretable against
  the sentinel's tail: what the load, process, port, and atom/ETS counts were in
  the seconds before death, and whether the failure followed a spawn/exec burst.

If the sentinel's last record shows ports/processes climbing into the thousands
immediately before death, the churn hypothesis moves back into contention; if it
shows a flat steady-state fleet with load pegged at 3–4× cores, the starvation
hypothesis is confirmed. That distinction is exactly what the bare dump cannot
make today.

## Files

- `docs/measurements/2026-08-03-daemon-saturation-root-cause.md` — this record.
- `scripts/aiur-saturation-repro.sh` — controlled load reproduction (runbook in
  the script header and below).
- `src/lib/aiur/saturation_sentinel.ex` — daemon-side saturation diagnostics
  recorder (GenServer; writes `<logs-root>/log/saturation.log`).
- Supervision: `src/lib/aiur.ex`, config schema/accessor (`agent.saturation_log_enabled`).

## Runbook — controlled load reproduction (operator, dogfood host)

The reproduction is deliberately bounded and operator-initiated — it must **not**
be run inside an agent workspace or on the shared host by an agent. It ramps
*fleet* load through normal dispatch to the measured ceiling, then stacks
*external* uncapped mix BEAM load (the #852 trigger) on top, while watching the
daemon BEAM and the crash dump path. See the script header for usage, safety
guards, and cleanup.
