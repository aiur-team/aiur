# Handoff — chat/control/lifecycle UX fixes: BUILD COMPLETE, awaiting operator verification

## 2026-06-12 LATE-SESSION ADDITIONS (post first operator test)

Operator test results: remote works both ways (RC harvest fix verified),
opencode messages consumed quickly (segmentation verified). Two follow-up
fixes landed after debugging the remaining reports:

1. **In-pane duplication (was 3-4x)** — TWO root causes, both fixed:
   - marker POST retry-on-timeout duplicated continuation markers
     (`Never retry turn markers on timeout`);
   - SessionWriter wrote a parallel SQL copy of every transcript/alert/
     ticker event that the TUI rendered after each segment close, on top
     of opencode's own stored copy of the streamed completion. Now skipped
     while a live aiur turn is `:active` in ActiveTurns
     (`live_stream_active?/1` in session_writer.ex); SQL writes resume
     between turns and when both marker posts failed (dark stream).
2. **Ctrl+Q / Ctrl+C-close killed the attach process → reopen prewarmed** —
   new hide path: `PaneManager.hide_by_pane_id/1` moves the pane to the
   hidden warm window WITHOUT `Slot.deselect`, so the slot keeps its
   binding and reopen hits `set_visible`'s fast path (same pane, instant).
   Exposed via `POST /api/v1/pane/hide`; `aiur-pane-ctrlc` close branch now
   hides-first (kill only as fallback) and accepts a third arg `hide` used
   by the C-q binding. Agent-list close (`close_conversation`) keeps its
   deselect semantics.

**Updated:** 2026-06-12 (build session, Fable). Branch `kevin/repl-dualchat`, PR #256.
**Plan of record:** `docs/plans/2026-06-12-002-fix-chat-control-lifecycle-ux-plan.md`
(origin: `docs/brainstorms/2026-06-12-chat-control-lifecycle-ux-requirements.md`).

## RULE IN EFFECT: do NOT run `aiurdev` until the operator says so.

The operator will run the verification themselves and report what works.
(There is no `--local3` flag; the test entry point is `--test3`.)

## What landed this session (all pushed)

| Commit | What |
|---|---|
| `0675e73` | Planning docs (brainstorm + plan) |
| `deab2c6` | U3: `{:pause_agent}` clause in REPL `await_turn/7` + `finish_turn` `{:paused}` clause; interrupt-then-park; deadline expiry parks (never errors); 3 new tests |
| `6b3f94d` | U8: 212 test-fixture rename (issue 212 closed + label-stripped on GitHub; stale log artifact deleted) |
| `c1a2ca5` | U4: `Aiur.ProcessReaper` (kind-ordered `:agent`→delete_all→`:serve`, cmdline pid-reuse guard, shutdown-scoped draining, reaps in own `terminate/2`, `prep_stop/1` SIGTERM hook); registrations in repl_agent/headless/codex/slot/server; 11 tests; registrations config-disabled in test env |
| `07d3a3f` | U5: tmux `C-q` binding — closes chat pane, NO state change; pane-0 = no-op (NOT kill-session) |
| (turn-markers commit) | `Aiur.Opencode.TurnMarkers` extraction (`post_all`/`post_continuation`/`post_marker`, parse) |
| `…alias variants` | `model:claude-remote-sonnet` now resolves alias+variant (claude-repl + sonnet + forced RC); **issue 101's label was switched to `model:claude-remote-sonnet`** |
| `…segment streams` | U1: bridge segmentation — suffix parse, originating-writer continuations, event/idle boundary fns, symmetric coalescing defenses; tests |
| `…atomic frames` | U9: DEC 2026 synchronized-update wrap around agent-list frames (probable `??????` fix) + renderer test |

## Live findings from the one allowed test run (2026-06-12 ~09:00)

1. **U1 gating experiment PASSED.** POST `/session/X/message` while that
   session's completion is in flight: held open (no 409, no concurrent
   completion), survives the HTTP client aborting, and fires its own
   completion IN ORDER once the in-flight one closes (logs:
   `turn_stream_close t1` → 550ms → `turn_stream_phantom texp99`). The
   segmentation design is sound.
2. **UPSTREAM BREAKAGE (claude CLI 2.1.175):** the interactive `claude`
   REPL no longer writes conversation records to
   `~/.claude/projects/<slug>/*.jsonl` — only an `ai-title` record, even
   across multiple turns, with aiur's exact launch flags, and nothing
   flushes on exit. Headless/sdk-cli sessions still write fine (issue
   101's headless transcript grew normally). **This breaks the whole
   claude-repl transcript-tailing path upstream**: turn-end detection,
   chat-pane mirroring, and remote-message attribution (U7) see nothing.
   The U3 pause degrades gracefully (parks on `pause_confirm_timeout`
   after 10s instead of hanging). Needs either a claude downgrade/pin, a
   new claude flag, or a rethink of REPL turn detection. **Surface this to
   the operator first.**
3. **RC did not attach this run** (no banner within budget) → 101 degraded
   to headless. RC-dependent verifications (AE4, dual-surface) need a run
   where RC attaches.
4. **Flicker (`??????`) never reproduced in captured bytes or screen
   cells** during a full boot under pipe-pane + 1s screen polling — no
   literal `?` anywhere. Conclusion: it's a partial-frame paint artifact
   on the operator's terminal; the DEC 2026 synchronized-update fix
   targets exactly that. Verify on the operator's terminal.
5. **TUI key-driving via tmux send-keys did not work this run** (Enter/
   Down/? all ignored by the input loop; cause unknown — worked 2026-06-10
   per prior handoff). Pane-interaction tests (Ctrl+C matrix, Ctrl+Q,
   close/reopen) are therefore UNVERIFIED-LIVE and fall to the operator.
6. Two codex process pairs from 07:43 and Jun-10 survive on the host
   (cwd `~/github/aiur`, predating the reaper) — pre-existing orphans,
   deliberately not killed; the reaper only covers processes registered
   after `c1a2ca5`.

## Operator verification checklist (when you run it)

Run `scripts/aiurdev --test3 --force`, then:
- [ ] AE1/R3-R5: type into a working agent's pane → QUEUED clears within
      ~20-30s (one segment boundary), renders as user turn, agent
      incorporates it; turn renders as multiple assistant bubbles; NO
      visible `__aiur_turn__` rows in the pane (theme-dependent — if
      visible, that's a U1 blocker); log shows
      `turn_stream_segment_close` lines.
- [ ] AE2/R8: Ctrl+C matrix — queued+working→drain+continue+open;
      idle→pause+open; paused→close+still-paused.
- [ ] R9: Ctrl+Q closes pane, agent keeps working; Ctrl+Q on agent list
      does nothing.
- [ ] R10: close then reopen a chat pane → same session resumes, no
      duplicate content, no `:repl_gone` re-dispatch line.
- [ ] AE3/R14-15: pause a claude-repl agent mid-turn → work actually
      stops (watch transcript/log); resume with Space. (Expect
      `pause_confirm_timeout` log if the upstream transcript bug is
      still present — pause still parks.)
- [ ] AE4/R6-7: send from Claude RC app while agent mid-turn AND idle →
      renders as user message in opencode; pane-typed msg visible in the
      app. (BLOCKED by upstream finding #2 until resolved.)
- [ ] AE5/R11: quit aiur with agents mid-work → two-pass check:
      `pgrep -af 'claude|codex|opencode' | grep aiur-workspaces` empty
      AND bare `pgrep -af opencode` diff vs pre-quit → empty. Repeat via
      SIGTERM.
- [ ] R2: watch initial load on your terminal — no `??????` flicker.
- [ ] R13/U10: `aiurdev --bg` then `aiurdev` attaches; foreground quit
      leaves bg agents alone; `aiurdev stop` kills everything.

## Not done / open

- U2/U10 latency + --bg matrices (need the operator-approved run).
- U7 idle-path attribution experiment (blocked by upstream finding #2).
- Segment threshold tuning (`config :aiur, :turn_segment_threshold_ms`,
  default 20_000ms) — adjust live if segments feel too chatty/slow.
- The `?` flicker fix is probabilistic until seen clean on the operator's
  terminal.

## Key invariants (unchanged)

R0 autonomy; never break codex/headless fallback; `:immediate` delivery
gated on claude-repl; RC URL never logged; `:interactive_cli` gates
workspace sweeps; backfill is display-only; never merge PR #256 without
explicit operator approval.

## How to run things (when permitted)

- Tests: `cd src && mise exec -- mix test [path]`
- Full gate: `make -C src MIX='mise exec -- mix' all`
- Manual run (OPERATOR ONLY for now): `scripts/aiurdev --test3 --force`
- Logs: `src/log/`; Ctrl+C breadcrumbs `/tmp/aiur-ctrlc.log`.
