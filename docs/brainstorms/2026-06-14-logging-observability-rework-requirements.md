---
date: 2026-06-14
topic: logging-observability-rework
---

# Logging & Observability Rework

## Problem Frame

aiur's debug logging actively defeats debugging. Across 10+ debugging loops on the
RC-claude opencode-delivery bug, evidence kept vanishing or drowning:

- The per-run log (`/tmp/aiur-startup.*`) is **deleted on clean exit** by the
  wrapper's cleanup trap (`scripts/aiurdev:1677`), so the moment a run ends its
  full record is gone — only hard-crash/SIGKILL survivors remain.
- That "log" is not a log: it is the tee'd **raw TUI stdout** — a ~60fps full-frame
  repaint stream (`render_interval_ms: 16`). 64% of one 53MB sample is a single
  box-border glyph. Real `aiur_perf`/structured lines are buried or absent.
- The result: even when evidence survives, it is effectively ungreppable, and a
  glance at a transient pane gets mistaken for a verified fix.

This rework makes logs **small, persistent, greppable, and bounded**, and moves the
heavy screen-frame stream behind an explicit opt-in used only for visual debugging.

---

## Actors

- A1. Operator/developer: runs `aiurdev` / `--test` / `--test3`, later reads logs to debug.
- A2. Debugging agent (Claude Code): greps persisted logs to trace a failure path post-mortem.
- A3. aiur runtime (BEAM): emits structured + per-agent logs and runs the retention sweep.

---

## Requirements

**Gating & defaults**
- R1. A normal run (no `--debug`/`--test`/`--test3`) produces no heavy artifacts: no full-session TUI frame stream and no structured `aiur.log`. Per-agent transcripts (`IssueLog`) remain written (always-on, by decision).
- R2. `--debug`/`--test`/`--test3` enable the structured `aiur.log` (existing behavior; `--test`/`--test3` already imply `--debug`).

**Unified persistent location**
- R3. All durable log artifacts live under one root: `~/.aiur/logs/` by default, overridable via `--logs-root`/`AIUR_LOGS_ROOT`.
- R4. Each aiur session writes into its own timestamped per-session location under that root, so re-running `--test`/`--test3` on the same tickets never clobbers a prior session's logs.
- R5. Logs are never deleted on process exit. The wrapper's exit-trap `rm` is removed; cleanup happens only via the retention sweep (R8) or an explicit `--clear`.

**Volume reduction & `--record`**
- R6. Default runs do not retain the full-session ~60fps TUI frame stream. Only a bounded boot-diagnostic capture — enough for the existing "Aiur exited during startup" replay — is kept.
- R7. A new `--record` flag captures the **main AgentList TUI pane** into a separate, stitched, ANSI-preserved file under the session's `record/` dir, for debugging the `????`/box-glyph flicker and other visual bugs. This is distinct from, and additive to, the existing `--debug` chat-pane recorder.

**Retention cap**
- R8. A new `.aiurconfig` setting `max-log-history` (MB) bounds the total size of the unified log root. A background sweep runs every 5 minutes while aiur is running; when the total exceeds the cap it deletes oldest sessions first until under it. aiur's own `.aiurconfig` ships `1000`; the code default is also `1000` when unset. The sweep runs regardless of debug/test flags (it is the disk-safety mechanism).

---

## Acceptance Examples

- AE1. **Covers R1, R6.** Given a plain `aiurdev` run left up ~10 min, when it exits, `~/.aiur/logs/<session>/` holds per-agent transcripts but no multi-MB frame file and no `aiur.log` — orders of magnitude under the prior 15MB/6min.
- AE2. **Covers R3, R4, R5.** Given `--test3` run, quit, then `--test3` again, two distinct timestamped session dirs exist and the first session's logs are fully intact after the second run.
- AE3. **Covers R7.** Given `aiurdev --test3 --record` and the divider flicker reproduced on screen, when the run exits, `record/screen.<...>.ansi` contains the AgentList pane frames showing the `????`/box transitions, greppable after exit.
- AE4. **Covers R8.** Given `max-log-history: 1000` and ~1200MB already under the root, within 5 minutes the sweep deletes oldest sessions until the total is ≤1000MB.

---

## Success Criteria

- After any run — clean exit included — that session's full logs survive at a known path, and a normal run no longer generates GB-scale files.
- A future debugging session (human or agent) can grep one persisted, greppable structured file per session to trace a failure path, without wading through frame noise.
- The flicker/visual bugs are inspectable offline from `record/screen.ansi` instead of requiring a live eyeball.
- The log root self-bounds at the configured cap and never fills the disk.

---

## Scope Boundaries

- Not fixing the RC-claude opencode-delivery bug here — that is filed as a separate GitHub issue; this feature only makes it debuggable.
- Not changing which events/messages get logged, only where/whether they persist and how they're bounded.
- Not adding in-file log rotation (per-session files + the size-cap sweep replace rotation, consistent with `log_file.ex` dropping rotation deliberately).
- Not building a log viewer/UI.
- Not folding the existing `--debug` chat-pane recorder into `--record` (it stays as-is).
- Not changing codex / non-RC-claude logging semantics beyond the relocation + gating above.

---

## Key Decisions

- `~/.aiur/logs/` over reusing `src/log`: outside the repo tree, survives across worktrees, never risks git noise; `--logs-root` still overrides.
- Record-only frame capture: kills the ~60fps monster by default; flicker debugging is explicit opt-in via `--record`.
- `IssueLog` stays always-on: the per-agent transcript is small and genuinely useful in real runs; the sweep bounds it.
- 5-minute sweep, oldest-session-first deletion: a simple, predictable bound that makes `log_file.ex`'s "manage disk externally" note a built-in guarantee.

---

## Dependencies / Assumptions

- Reuses `AIUR_LOGS_ROOT`/`--logs-root` plumbing and `Aiur.Config.Paths.log_root_dir/0` as the single root anchor.
- Reuses the existing capture-pane stitch helpers (`_aiur_record_clean`, `_aiur_record_stitch`) for `--record`.
- `max-log-history` is added to the Ecto config schema (`src/lib/aiur/config/schema.ex`) as a typed field defaulting to 1000.
- Assumes `~/.aiur` is an acceptable home for logs (created if absent).

---

## Outstanding Questions

### Resolve Before Planning

- (none — all product decisions are made)

### Deferred to Planning

- [Affects R4][Technical] Per-session separation as a timestamped subdir (`<root>/<ts>/…`) vs timestamped filenames in a flat dir — pick the layout during planning.
- [Affects R6][Technical] Mechanism for the bounded boot-diagnostic capture (stop teeing after first successful render vs a bounded tail / `head -c`).
- [Affects R8][Technical] Sweep as a supervised GenServer vs periodic Task; deletion granularity (whole session dir vs individual files); exact byte-accounting of the root.
- [Affects R3][Needs research] Confirm the Perf PubSub → Logger path (which subscriber writes `aiur_perf` lines into `aiur.log`) so structured perf lines land in the per-session file.

---

## Next Steps

-> `/ce-plan` for structured implementation planning.

**Follow-on (outside this feature's behavior, tracked in the session goal):** file the RC-claude opencode-delivery bug as a new aiur GitHub issue (enriched from `docs/brainstorms/2026-06-14-operator-message-native-queue-requirements.md` and the related plan), then push, update PR #256, and merge.
