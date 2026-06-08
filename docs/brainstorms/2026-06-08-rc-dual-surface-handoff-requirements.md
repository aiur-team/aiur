# Remote Control: read-only follow-along, lossless reverse handoff, default-mode config, handoff bug fixes

**Date:** 2026-06-08
**Status:** Requirements (ready for `/ce-plan`)
**Scope:** Deep — feature (existing RC + headless architecture anchors the work)

## Problem & framing

Simultaneous dual-**chat** (operator chats the same agent from aiur opencode AND the Claude app at once) is **proven impossible** — the `claude` binary binds each session's input queue to exactly one source (local stdin stream-json **or** cloud RC bridge), and `--remote-control` is silently inert in headless mode. See memory `rc-cloud-mediated` for the experiment.

So we keep the `r` toggle (switch which surface *chats*) and make the rest of the experience as good as the constraint allows:

1. **Read-only follow-along** — while RC is on, aiur's opencode view *mirrors* the live RC session (jsonl tail) instead of going blank.
2. **Lossless reverse handoff** — pressing `r` to turn RC off spins up a local agent that *resumes the actual RC transcript*, not a fresh dispatch.
3. **Default-mode config** — a dev setting to launch every agent in RC mode from the start, vs the current opencode/headless default.
4. **Fix the 5 RC handoff bugs**, especially the blocking orphaned-process bug.

## Users & value

- **Operator**: never loses sight of an agent after handing it to the Claude app (follow-along); can pull an agent back locally without losing the conversation (lossless reverse); can opt a whole workflow into phone/web-first driving (default-remote).
- **Dev/integrator**: one config knob to pick the default surface.

## Requirements

### R1 — Read-only follow-along when RC is on
- When an agent is in RC mode (`remote_control.status in [:launching, :on]`), the opencode/chat view shows the live RC session transcript, updating as it grows.
- Source: resolve workspace → encoded project dir → read `bridge-pointer.json` (`{sessionId, environmentId, source, pid, procStart}`) → tail `<sessionId>.jsonl`.
- The view is explicitly **read-only**: no input box / chat affordance while RC owns the queue (chatting happens in the Claude app). A clear indicator that this is a mirror.
- Works for both autonomous and RC sessions (both write the same jsonl), but only *activated* for RC-mode rows here.

### R2 — Lossless reverse handoff (RC → local), DECIDED: session resume
- On `r`-off (`remote_control_off`, orchestrator.ex:3765): before re-dispatch, read the RC session's `sessionId` from `bridge-pointer.json` for the workspace.
- Tear down the RC server cleanly (see R4), then dispatch a local headless agent **bound to that session id** so the app-server runs `claude --resume <sessionId>` and loads the full real transcript (conversation, tool calls, edits).
- **App-server change (we own `its-everdred/claude-app-server` = `symphony-claude`):** add a way to start a thread that resumes an externally-supplied `cliSessionId` (today `--resume` is only used for forks and same-thread continuation, server.ts:460-481). aiur passes `resume_session_id` through the driver launch.
- Fallback: if `bridge-pointer.json` / sessionId is missing, fall back to the current fresh re-dispatch (don't strand the issue).

### R3 — Default-mode config, DECIDED: auto-launch RC at start
- New `.aiurconfig` setting (Config.Schema) selecting the default surface: `opencode` (current behavior) | `remote`.
- When `remote`: as soon as a dispatched agent has a workspace, run the `r`-on path (`launch_remote_control`) automatically — same code path as the keybind.
- Documented tradeoff: in `remote` default, the agent does **not** progress autonomously; a human drives it from the Claude app while aiur shows R1 follow-along. This is the dev's explicit choice.
- `opencode` remains the default value (no behavior change unless set).

### R4 — Fix the 5 handoff bugs
- **#1 (blocking) Orphaned outgoing agent.** On handoff, the headless driver's `claude` OS process is not killed (`stop_port/1` only `Port.close`s, which doesn't kill a `:spawn_executable` child; coding_agent.ex:763). The orphan kept running ~2 min, posted a comment, opened a duplicate PR, flipped a label. Fix: plumb `claude_app_server_pid` (already emitted at coding_agent.ex:207, currently unconsumed) into the running entry and `graceful_kill` it (SIGTERM→wait→SIGKILL, reuse `RemoteControl.graceful_kill/1`) during handoff teardown. Verify the OS pid is gone before declaring handoff complete.
- **#2 (blocking) Empty inbox on receiving (forward) RC session.** RC has no `--prompt`/`--resume`, so forward handoff relies on the `CLAUDE.local.md` priming file. Ensure the receiving session reliably has an initial user-facing task message to act on.
- **#3 Stale "Recent progress".** The snippet is captured at write-time and goes stale; recompute from the newest transcript at read/handoff time.
- **#4 Missing "your role now" field.** Add an explicit role line to the forward handoff so the receiving agent knows its current responsibility.
- **#5 Workpad identity convention.** Establish a consistent workpad identity for the handoff session.

## Scope boundaries

**In:** the 4 requirements above; the one app-server feature (external session resume).

**Deferred / outside this product's identity:**
- Reverse-engineering Anthropic's cloud relay to achieve true dual-chat — out of scope, infeasible without it.
- A separate "attend" trigger for lazy RC switching (rejected in favor of auto-launch-at-start).
- Multi-machine RC (v1 is local-only; remote `worker_host` already gated out, orchestrator.ex:3679).

## Dependencies / assumptions

- `bridge-pointer.json` is written by the claude harness for live RC sessions and contains a resumable `sessionId` (verified format; resume-ability to be confirmed in planning).
- `claude --resume <id>` loads an RC-originated transcript into a headless session (the jsonl format is shared; to be verified manually in planning/work).
- `symphony-claude` is modifiable and shippable as our sibling repo.

## Success criteria

- Turning `r` on shows the live RC transcript read-only in opencode; no input box.
- Turning `r` off lands a local agent that continues the *actual* RC conversation (a follow-up references prior RC turns/edits).
- `default_mode=remote` launches agents straight into RC with follow-along.
- After any handoff, the previous driver's `claude` OS process is confirmed dead (no duplicate comments/PRs).
- Forward RC session starts with a clear task + role; progress snippet is fresh.
- Tests cover each path; manual CLI verification through `scripts/aiur` end-to-end.
