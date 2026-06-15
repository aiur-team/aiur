---
title: "feat: Logging & observability rework"
type: feat
status: active
date: 2026-06-14
origin: docs/brainstorms/2026-06-14-logging-observability-rework-requirements.md
---

# feat: Logging & Observability Rework

## Overview

aiur's debug logging defeats debugging: the per-run capture is the tee'd raw TUI
stdout (~60fps full-frame repaints — 15MB/6min, GB-scale over hours), and the
wrapper **deletes** it on clean exit. This plan makes logs small, persistent,
greppable, and bounded: unify all durable logs under `~/.aiur/logs/` with one
timestamped per-session dir, never delete on exit, move the heavy frame stream
behind a new `--record` flag, and add a `max-log-history` size cap enforced by a
5-minute background sweep.

---

## Problem Frame

See origin: `docs/brainstorms/2026-06-14-logging-observability-rework-requirements.md`.
Three concrete failures verified this session: (1) `scripts/aiurdev:1677` `rm -f`
wipes the full capture on clean exit; (2) the capture is the raw TUI frame stream
(`render_interval_ms: 16`), 64% box-border glyphs, drowning real `aiur_perf`/
structured lines; (3) no retention bound — `log_file.ex` dropped rotation and
explicitly left "disk fill … managed externally," which this plan now makes built-in.

---

## Requirements Trace

- R1. Normal (no-flag) runs produce no heavy artifacts (no full-session frame stream, no `aiur.log`); per-agent `IssueLog` stays always-on.
- R2. `--debug`/`--test`/`--test3` enable structured `aiur.log` (existing; `--test`/`--test3` already imply `--debug`).
- R3. All durable logs live under one root `~/.aiur/logs/` (override via `--logs-root`/`AIUR_LOGS_ROOT`).
- R4. Each session writes to its own timestamped per-session location; re-running `--test`/`--test3` never clobbers a prior session.
- R5. Logs are never deleted on exit (remove the wrapper exit-trap `rm`); cleanup only via the sweep or explicit `--clear`.
- R6. Default runs keep only a bounded boot-diagnostic capture (enough for the "Aiur exited during startup" replay), not the full frame stream.
- R7. New `--record` flag captures the main AgentList TUI pane into `record/screen.<…>.ansi` for flicker/visual debugging.
- R8. New `.aiurconfig` `max-log-history` (MB, default 1000) bounds the root; a 5-min sweep deletes oldest sessions first until under cap; runs regardless of flags.

**Origin actors:** A1 (operator/developer), A2 (debugging agent), A3 (aiur runtime).
**Origin acceptance examples:** AE1 (covers R1, R6), AE2 (covers R3, R4, R5), AE3 (covers R7), AE4 (covers R8).

---

## Scope Boundaries

- Not fixing the RC-claude opencode-delivery bug here (filed separately; this only makes it debuggable).
- Not changing which events/messages get logged — only where/whether they persist and how they're bounded.
- Not adding in-file rotation (per-session files + sweep replace it).
- Not building a log viewer/UI.
- Not folding the existing `--debug` chat-pane recorder (`aiur_record_session`) into `--record` — it stays as-is.
- Not changing codex / non-RC-claude logging semantics beyond relocation + gating.

### Deferred to Follow-Up Work

- File the RC-opencode bug as a GitHub issue, then push / update PR #256 / merge: handled as session-goal workflow steps after `/ce-code-review`, not as plan units.

---

## Context & Research

### Relevant Code and Patterns

- `scripts/aiurdev`: flag parse (~95-170), `debug_mode`→`AIUR_DEBUG=1` (~306), `log_path` build (~1788), chat recorder `aiur_record_session` (~1527) launched under `--debug` (~1981-1986), `startup_capture` mktemp (~1619), exit-trap delete (~1677, currently a stopgap `mv …last`), inline tee generation (~1900-1946), `print_startup_failure` (~1422).
- `src/lib/aiur/log_file.ex`: `AIUR_DEBUG`-gated `:logger_std_h` file handler; `default_log_file/0,1`; no rotation by design.
- `src/lib/aiur/issue_log.ex`: always-on per-agent writer to `<log_root>/<repo>.<id>.log` (`log_path/1`, `log_root_dir/0` via `Paths`).
- `src/lib/aiur/config/paths.ex`: `log_root_dir/0` = `dirname(:log_file)`, default `<cwd>/log`.
- `src/lib/aiur/cli.ex`: `--logs-root` → `Application.put_env(:aiur, :log_file, LogFile.default_log_file(logs_root))` (~219).
- `src/lib/aiur/config/schema.ex`: Ecto embedded schemas; top-level scalars (e.g. `max_vertical_panes`) are the pattern to mirror for a new typed field.
- `src/lib/aiur/perf.ex`: `event/2` already `Logger.info(format_line(...))` (line 49) → `aiur_perf` lines reach `aiur.log` when the file handler is on (resolves origin Q4). PubSub broadcast only feeds the debug TUI overlay (`agent_list/app.ex:850`).
- `src/lib/aiur.ex`: application supervision tree (add the sweep child here).
- `src/lib/aiur/events/ls_remote_ticker.ex` & `src/lib/aiur/progress_checkin/worker.ex`: supervised periodic-tick GenServer pattern (`init` schedules, `handle_info(:tick)` works + reschedules via `Process.send_after(self(), :tick, interval_ms)`).

### Institutional Learnings

- Perf logging convention: always-on `aiur_perf` lines for lifecycle (do not gate on `--debug` at the call site; gating happens at the handler). Keep new sweep/record diagnostics consistent.
- `--test`/`--test3` are the canonical manual-drive entry points and already imply `--debug --clear --force`.

---

## Key Technical Decisions

- **Unified root = `~/.aiur/logs/<session-id>/`.** Outside the repo tree (survives worktrees, no git noise). The wrapper mints the session dir and exports it as `AIUR_LOGS_ROOT`; the existing `${AIUR_LOGS_ROOT}/log/aiur.log` convention is preserved inside it (low churn). For raw `aiur` with no wrapper and no `--logs-root`, the app mints its own session dir at boot. Explicit `--logs-root`/`AIUR_LOGS_ROOT` is honored verbatim (caller controls the path).
- **Session-id format:** `<UTC timestamp>-<pid>` (e.g. `20260614T173702Z-304219`) to stay unique across same-second launches. GC unit = the direct child dir of the root.
- **Record-only frame capture.** Default runs do NOT tee the full-session TUI stdout. A bounded boot-diagnostic capture is retained only across the startup-grace window (enough for `print_startup_failure`). `--record` additionally runs an AgentList-pane recorder (reusing `_aiur_record_clean`/`_aiur_record_stitch`) → `<session>/log/record/screen.ansi`.
- **Sweep = supervised GenServer** `Aiur.Logs.Retention` on a 5-min tick; deletes oldest direct-child session dirs under `~/.aiur/logs/` until total bytes ≤ cap; never deletes the current session dir. Runs unconditionally (disk safety).
- **Config key `max_log_history_mb`** (snake_case to match `.aiurconfig` convention; surfaced to the user as "max-log-history"), top-level typed field default `1000`; `.aiurconfig` ships `1000`.

---

## Open Questions

### Resolved During Planning

- Origin Q4 (where do `aiur_perf` lines go): `Perf.event/2` logs via `Logger.info`; they land in `aiur.log` when the handler is on. Relocation carries them; no extra work.
- Origin Q3 (sweep shape): supervised GenServer, whole-session-dir granularity, byte sum over root.
- Origin Q4-layout (per-session separation): timestamped subdir, not timestamped filename — groups all of a session's artifacts and makes oldest-first deletion trivial.

### Deferred to Implementation

- R6 exact bash mechanism for the bounded boot capture (stop appending after first healthy attach vs a last-N-KB bounded writer). Decision is the *behavior* (no full-session frames; boot failures still replayable); the concrete shell realization is picked in `ce-work` and validated against AE1.
- Whether the nested `<session>/log/` level is flattened to `<session>/` — implementer may flatten if it's a trivial, contained change; default is to preserve the existing `log/` layout.

---

## Output Structure

    ~/.aiur/logs/
      20260614T173702Z-304219/        # one dir per session (GC unit)
        log/
          aiur.log                    # structured BEAM logger (only under --debug/--test/--test3)
          <repo>.<id>.log             # per-agent transcript (always-on)
          record/
            chat.<id>.ansi            # existing --debug chat-pane recorder
            screen.ansi               # NEW --record AgentList-pane recorder
        boot.capture                  # bounded boot-diagnostic (default runs)
      20260614T180210Z-309b…/         # next session, prior session intact

---

## High-Level Technical Design

> *Directional guidance for review, not implementation specification.*

Flag → capture behavior (decision matrix):

| Flag(s)                | structured aiur.log | per-agent IssueLog | boot capture | chat-pane record | screen-pane record |
|------------------------|---------------------|--------------------|--------------|------------------|--------------------|
| (none)                 | no                  | yes                | bounded      | no               | no                 |
| `--debug`              | yes                 | yes                | bounded      | yes              | no                 |
| `--test` / `--test3`   | yes (imply --debug) | yes                | bounded      | yes              | no                 |
| `--record` (+ above)   | per above           | yes                | bounded      | per above        | **yes**            |

Retention sweep:

    every 5 min:
      total = sum bytes under ~/.aiur/logs/
      while total > max_log_history_mb * 1MB:
        victim = oldest direct-child session dir, excluding current
        if none: break
        total -= du(victim); rm -rf victim

---

## Implementation Units

- [ ] U1. **Unified per-session log root under `~/.aiur/logs/`**

**Goal:** Make `~/.aiur/logs/<session-id>/` the default root for all durable logs, minted once per session and shared by wrapper and BEAM.

**Requirements:** R3, R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/paths.ex` (default `log_root_dir` → `~/.aiur/logs/<session>/log`)
- Modify: `src/lib/aiur/log_file.ex` (`default_log_file/0` honors the session root)
- Modify: `src/lib/aiur.ex` (mint a session id at boot when `AIUR_LOGS_ROOT` unset; put `:log_file` env)
- Modify: `scripts/aiurdev` (mint `<UTC>-<pid>` session dir; default `AIUR_LOGS_ROOT` to it unless an explicit logs_root is configured; create `~/.aiur/logs`)
- Test: `src/test/aiur/config/paths_test.exs`, `src/test/aiur/log_file_test.exs`

**Approach:**
- One session id, two minting sites: wrapper (normal path) exports `AIUR_LOGS_ROOT`; app mints only when env unset (raw `aiur`). Both honor an explicit value verbatim.
- Preserve the existing `${root}/log/aiur.log` layout inside the session dir to minimize churn.

**Patterns to follow:** existing `--logs-root` plumbing in `cli.ex:219`; `Paths.log_root_dir/0`.

**Test scenarios:**
- Happy path: with `AIUR_LOGS_ROOT` unset, `log_root_dir/0` resolves under `~/.aiur/logs/<session>/log` (session segment present).
- Covers AE2. Edge case: explicit `--logs-root /foo` → root is `/foo/...` verbatim, no `~/.aiur` injection.
- Edge case: two boots mint two distinct session ids (timestamp+pid uniqueness) — no collision on same-second launches.

**Verification:** a fresh run writes `aiur.log` and per-agent logs under a single timestamped `~/.aiur/logs/<session>/` dir; `--logs-root` still redirects the whole tree.

---

- [ ] U2. **Persist logs on exit; replace full-session tee with bounded boot capture**

**Goal:** Stop deleting the capture on exit and stop accumulating the ~60fps frame stream by default; retain only a bounded boot-diagnostic capture.

**Requirements:** R1, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `scripts/aiurdev` (remove exit-trap delete ~1677 incl. the stopgap `mv …last`; route capture into the session dir; bound it to the startup-grace window; keep `print_startup_failure` working)

**Approach:**
- Default (no `--record`): the launcher's combined stdout/stderr feeds a bounded boot capture used only for early-exit replay; once a healthy attach/render is observed the capture stops growing (mechanism deferred to implementation — see Open Questions).
- Persistence comes for free: the file lives in `~/.aiur/logs/<session>/` and is reaped only by the sweep (U5) or `--clear`.

**Patterns to follow:** existing `print_startup_failure` (`scripts/aiurdev:1422`) tails last 30 lines — boot capture must keep at least that.

**Test scenarios:**
- Covers AE1. Manual/script: a normal run left up several minutes leaves no multi-MB frame file (boot capture stays small).
- Covers AE2/AE5-persistence: after clean exit, the session dir and its logs still exist on disk (no `rm`).
- Error path: simulate a startup failure (BEAM exits during grace) → `print_startup_failure` still replays the captured pane output.

**Verification:** clean exit leaves logs on disk; default-run capture is KB-scale, not MB/GB; startup-failure replay is unchanged.

**Execution note:** validate the size claim against a real `--test3` run (AE1) before considering done — this is the core "kills the monster" check.

---

- [ ] U3. **`--record` flag: capture the AgentList TUI pane**

**Goal:** Add `--record` that records the main AgentList pane (where the `????`/box flicker lives) into a stitched ANSI file for offline visual debugging.

**Requirements:** R7

**Dependencies:** U1

**Files:**
- Modify: `scripts/aiurdev` (flag parse adds `--record`; usage text; launch an AgentList-pane recorder into `<session>/log/record/screen.ansi`; stop it on detach)

**Approach:**
- Reuse `aiur_record_session`'s capture/stitch building blocks (`_aiur_record_clean`, `_aiur_record_stitch`) but target the main AgentList pane (window 0 pane 0) rather than the `OC | <id>` chat panes.
- Additive and orthogonal to `--debug`'s chat-pane recorder; `--record` can combine with any other flag.

**Patterns to follow:** `aiur_record_session` (`scripts/aiurdev:1527`) and its launch/teardown (`~1981-2004`).

**Test scenarios:**
- Covers AE3. Manual: `aiurdev --test3 --record`, reproduce the divider flicker → `record/screen.ansi` contains AgentList frames with the `????`/box transitions, greppable after exit.
- Edge case: `--record` without `--debug` still produces `screen.ansi` (record is independent of debug).
- Test expectation: shell behavior — covered by the manual AE3 check plus a lightweight bats/script assertion that `--record` is parsed and the recorder pid is started/stopped.

**Verification:** a `--record` run yields a stitched `screen.ansi` of the AgentList pane that survives exit; absent `--record`, no `screen.ansi` is created.

---

- [ ] U4. **`max-log-history` config setting**

**Goal:** Add the typed, dev-configurable retention cap, defaulting to 1000 MB, and ship it in aiur's own `.aiurconfig`.

**Requirements:** R8

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` (top-level `field(:max_log_history_mb, :integer, default: 1000)` + cast/validate `greater_than: 0`)
- Modify: `src/lib/aiur/config.ex` (accessor if other scalars expose one)
- Modify: `.aiurconfig` (add `max_log_history_mb: 1000`)
- Test: `src/test/aiur/config_test.exs` (or the existing schema test)

**Approach:** mirror an existing top-level scalar (e.g. `max_vertical_panes`) for cast/default/validation; surface the value to the sweep via the normal config read path.

**Patterns to follow:** `max_vertical_panes` top-level field and its changeset in `config/schema.ex`.

**Test scenarios:**
- Happy path: `.aiurconfig` with `max_log_history_mb: 250` parses to 250.
- Edge case: omitted key → default 1000.
- Error path: non-positive / non-integer value is rejected by the changeset.

**Verification:** config round-trips the value; default is 1000 when unset.

---

- [ ] U5. **`Aiur.Logs.Retention` 5-minute sweep**

**Goal:** Bound `~/.aiur/logs/` to the configured cap by deleting oldest sessions first, every 5 minutes, regardless of flags.

**Requirements:** R8

**Dependencies:** U1, U4

**Files:**
- Create: `src/lib/aiur/logs/retention.ex`
- Modify: `src/lib/aiur.ex` (add to supervision tree)
- Test: `src/test/aiur/logs/retention_test.exs`

**Approach:**
- Supervised GenServer; `init` schedules first tick, `handle_info(:tick)` runs the sweep then reschedules (5 min). Mirror `ls_remote_ticker.ex`.
- Sweep: sum bytes under the root (parent of session dirs); while over cap, delete the oldest direct-child session dir by mtime, excluding the current session dir; stop when at/below cap or nothing left to delete.
- Resolve root as the parent of the active log root (`Paths.log_root_dir/0` → up to the `~/.aiur/logs` level); read cap from config (default 1000).

**Patterns to follow:** `src/lib/aiur/events/ls_remote_ticker.ex` (`schedule_tick`/`Process.send_after`).

**Test scenarios:**
- Covers AE4. Happy path: given a temp root with several session dirs summing > cap, one sweep deletes oldest-first until ≤ cap.
- Edge case: total ≤ cap → no deletions.
- Edge case: current session dir is never deleted even if it alone exceeds cap (guard holds; log a warning rather than self-delete).
- Edge case: empty/missing root → no crash, no-op.
- Integration: tick reschedules (process stays alive and sweeps again).

**Verification:** with logs over cap, the directory drops to ≤ cap within one tick; the active session's logs are preserved.

---

## System-Wide Impact

- **Interaction graph:** `Paths.log_root_dir/0` feeds `IssueLog`, `LogFile`, and the wrapper's `log_path`/`record_dir`; changing its default ripples to all three — all intended.
- **State lifecycle risks:** sweep deletes whole session dirs — the current-session guard plus oldest-first ordering prevent deleting live logs. `--clear` semantics in the wrapper still operate on the (now relocated) log dir.
- **API surface parity:** `--logs-root`/`AIUR_LOGS_ROOT` remains the single override; both app and wrapper must honor it identically (covered by U1 tests).
- **Unchanged invariants:** what gets logged, `IssueLog` always-on behavior, the existing `--debug` chat-pane recorder, and structured-log gating on `AIUR_DEBUG` are all unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Bounded boot capture loses startup-failure diagnostics | U2 keeps ≥ last 30 lines; error-path test asserts `print_startup_failure` still replays |
| Sweep deletes a live/just-started session | Exclude current session dir; oldest-first by mtime; unit test the guard |
| Relocating the default root breaks tooling expecting `src/log` | `--logs-root` override preserved; `--test`/`--test3` flows verified live before merge |
| Same-second launches collide on session id | id includes pid suffix; uniqueness test in U1 |

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-14-logging-observability-rework-requirements.md](docs/brainstorms/2026-06-14-logging-observability-rework-requirements.md)
- Related code: `scripts/aiurdev`, `src/lib/aiur/log_file.ex`, `src/lib/aiur/issue_log.ex`, `src/lib/aiur/config/paths.ex`, `src/lib/aiur/perf.ex`, `src/lib/aiur/events/ls_remote_ticker.ex`
- Related PR: #256 (kevin/repl-dualchat)
