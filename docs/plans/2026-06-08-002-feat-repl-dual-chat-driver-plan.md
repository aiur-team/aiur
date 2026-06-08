---
title: "feat: Persistent interactive-REPL driver for simultaneous dual-chat (opencode + Claude app RC)"
type: feat
status: active
date: 2026-06-08
origin: docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md
---

# feat: Persistent interactive-REPL driver for simultaneous dual-chat

## Overview

Replace aiur's one-shot-per-turn Claude driver (`claude --print` spawned fresh each turn by the symphony-claude app-server) with a **persistent interactive `claude` REPL** that aiur drives over a tmux pane via `send-keys`. Because the REPL stays alive, aiur can issue the runtime `/remote-control` slash command on it — which (proven end-to-end 2026-06-08, see memory `rc-dual-surface-state`) lets the operator drive the **same** agent from BOTH surfaces at once: aiur's opencode view in the TUI **and** the Claude app remote-control chat (phone / claude.ai/code). All turns land in one shared transcript; neither surface disables the other.

This unlocks three things the one-shot model could not:
1. True simultaneous dual-chat (the feature the prior plan declared impossible and fell back to an `r` toggle for).
2. Instant mid-turn operator messages (a persistent REPL accepts input while the agent is working, instead of waiting for a safe checkpoint).
3. A single pub/sub source of truth (the shared transcript jsonl) that keeps both surfaces in sync.

The existing toggle/handoff plan (`docs/plans/2026-06-08-001-feat-rc-dual-surface-handoff-plan.md`) stays on `kevin/remotecontrol` as the documented fallback. This work lives on `kevin/repl-dualchat`.

---

## Problem Frame

aiur's current Claude backend (`src/lib/aiur/claude/coding_agent.ex`) opens an Erlang Port running `bash -lc "aiur-claude"`. `aiur-claude` execs the symphony-claude node app-server, which spawns `claude --print --output-format stream-json …` **one-shot per turn** and speaks JSON-RPC 2.0 over stdio. Two consequences:

- **No persistent session to attach RC to.** `--remote-control` is silently inert in `--print`/stream-json mode (verified, memory `rc-cloud-mediated`), so the app-server can never expose a turn to the Claude app. RC today is a *separate, mutually-exclusive* `claude remote-control --spawn` process behind the `r` toggle.
- **Operator steering lands too late.** opencode operator messages go through `AgentChat.send(..., delivery_policy: :checkpoint)` (`src/lib/aiur/opencode/chat_completions.ex:491`), waiting for the next safe checkpoint. On a long autonomous turn that is effectively the end of the feature — steering almost never lands mid-work.

The interactive REPL + `/remote-control` path removes both limits at once. The cost is a real rewrite of the driver layer: the behaviour contract is the same, but the transport changes from "JSON-RPC notifications over a Port" to "send-keys into a tmux pane + tail the transcript jsonl for output."

---

## Requirements Trace

- R1. A persistent interactive-REPL driver hosts a long-lived `claude` process per agent session and implements the existing `Aiur.CodingAgent` behaviour (`start_session/2`, `run_turn/4`, `stop_session/1`, `normalize_event/1`, `send_operator_message/2`) so the orchestrator and `AgentRunner` integrate unchanged.
- R2. The driver issues `/remote-control` once at session start so the Claude app and opencode drive ONE agent / ONE transcript simultaneously.
- R3. Operator messages from opencode reach the live agent promptly (mid-turn), not gated on a safe checkpoint.
- R4. Both surfaces stay in sync via a single pub/sub source — the shared transcript jsonl — fanned out through the existing `broadcast_transcript` path.
- R5. Feature parity: any operator action available from opencode is available from the Claude app RC chat and vice versa.
- **R0 (load-bearing invariant — operator directive 2026-06-08). RC never disables autonomy.** The agent **drives the feature end-to-end by itself** (aiur's normal autonomous loop: dispatch → work turns → open PR) whether or not RC is attached. Remote-control is a **takeover channel, not a handoff** — it adds a second human-input channel so the dev *can* step in from phone/web, but absent dev intervention the agent keeps self-driving. A dev message (from either surface) lands in the same native queue and changes course; it does not need to arrive for the agent to make progress. This **corrects the origin requirements doc**, which wrongly assumed remote mode means "the agent does not progress autonomously; a human drives it." Autonomy = aiur send-keys-ing the work/continuation prompts (today's loop, preserved per R1); takeover = the dev send-keys-ing from the cloud side. Two input sources, one queue.
- R6. Two **independent** config settings govern surface selection (no agent is force-parked by default):
  - **Setting #1 — default backend/model** (existing, unchanged): when an issue has no `model:` label, this picks `codex` / `claude` / a specific model version. RC plays no part here.
  - **Setting #2 — remote-control opt-in** (new): consulted *only* when the resolved backend supports RC (claude). **Defaults to OFF.** The operator opts a session (or the global default) into RC; agents are not auto-parked into a human-driven cloud session by default.
  - **Transport vs. RC are decoupled.** The persistent interactive REPL is a *transport* that may improve chat UX (faster turns, mid-turn receipt) **even with RC off**. Whether interactive-REPL becomes the default transport for plain `claude` (no RC) is gated on the U0 spike proving a real UX win; until then the headless backend stays the claude default. RC is an opt-in layer *on top* of the interactive transport, never implied by it.
- R7. Clean teardown — on session end the `claude` REPL process and its tmux pane are confirmed dead (no orphan posting comments / opening duplicate PRs, the blocking bug #1 from origin).
- R8. **Operator-facing `model:claude-remote` label (redesign 2026-06-08).** A single label, `model:claude-remote`, selects the REPL transport **and** forces remote-control ON for that one issue, overriding the global Setting #2 default (which stays OFF). It is a *label-only alias* resolving to the internal `claude-repl` backend — the backend key is **not** renamed. This realizes "transport ≠ RC" at the label layer: `model:claude-repl` = transport only (RC follows the global default), `model:claude-remote` = transport + forced RC. The alias is auto-seeded as a GitHub label and must resolve as a whole (never mis-split into backend `claude` + variant `remote`).
- R9. **`r` key promotes a running agent to remote (redesign 2026-06-08).** Pressing `r` on any running non-remote agent (headless `claude` *or* `codex`) stops the current agent and **re-dispatches the same issue as `claude-remote`** (persistent REPL + RC), resuming the existing transcript/session by cwd. This replaces the old RC handoff toggle (`set_remote_control` → `launch_remote_control` → `do_launch_remote_control` spawning `claude remote-control --spawn`). Consistent with R0: the re-dispatched agent self-drives; RC is the takeover channel layered on.

**Origin actors:** Operator (drives agents from opencode and/or Claude app), Dev/integrator (sets the default surface).
**Origin flows:** F1 follow-along while RC on; F2 reverse handoff; F3 default-mode launch; F4 handoff-bug fixes. This plan reframes F1–F3 (dual-chat makes follow-along *also* chattable; no handoff needed because the agent never leaves aiur's process) and carries F4's orphan-kill into R7.
**Origin acceptance examples:** AE — "default_mode launches agents straight into RC" is satisfied via the R6 opt-in (when the operator enables the `remote_control` setting, agents launch straight into REPL+RC); we deliberately do NOT make this the unconditional default. AE — "after any handoff the previous driver's claude OS process is confirmed dead" → R7.

> **Origin supersession note:** the origin doc states dual-chat is "proven impossible." That verdict was for the `--print`/flag and `claude remote-control` subcommand paths only. The interactive-REPL `/remote-control` path is different and is now proven possible (memory `rc-dual-surface-state`, Q1-RESOLVED). This plan supersedes the origin's *approach* while preserving its still-valid sub-goals (orphan-kill, default-mode, keeping both surfaces useful).
>
> **In-plan redesign note (2026-06-08, after U0–U7 built):** the operator chose two refinements that postdate the original U0–U7 scope and are captured as R8/R9 + U8/U9. (1) The operator-facing way to force RC for a single issue is the `model:claude-remote` *label alias* (U8), not editing the global opt-in. (2) The `r` key no longer toggles the old `claude remote-control --spawn` handoff; it **promotes a running agent** by stopping it and re-dispatching the same issue as `claude-remote` (U9). The internal `claude-repl` backend key is unchanged; `claude-remote` is purely a label-layer alias.

---

## Scope Boundaries

- Not reverse-engineering Anthropic's cloud RC relay protocol — out of scope and disallowed. We only drive the local REPL and read local transcript files.
- Not removing the `codex` backend or its app-server path — this work targets the Claude backend.
- Not multi-machine / remote `worker_host` REPL — v1 is local-only (remote host already gated out, `orchestrator.ex:3679`).
- Not changing the cloud-side Claude app UI — parity is achieved by routing both surfaces through the one transcript, not by modifying the Claude app.

### Deferred to Follow-Up Work

- Retiring the symphony-claude app-server entirely: keep it available as the fallback backend (R6) until the REPL driver is proven in real use. A later PR can remove it if it becomes dead weight.
- Lossless RC→local reverse handoff (origin R2): no longer needed in the common case (the agent stays in aiur's process), so it drops out of v1. If a "detach to pure cloud RC" mode is ever wanted, plan it separately.
- **Headless `claude` OS-process orphan on brutal-kill teardown (found during U9 manual verification 2026-06-08):** `terminate_task/1` kills the BEAM AgentRunner task, but the headless backend's `claude.exe --print` grandchild (spawned under a `bash -lc` wrapper) reparents to init and survives. This affects every brutal-kill stop path (`terminate_running_issue`, `deactivate_running_issue`, and U9's `teardown_for_redispatch`), not U9 alone. REPL/RC agents are reaped correctly because their `repl_os_pid` is tracked and `kill_repl_session` → `RemoteControl.graceful_kill` handles it; headless agents track no os_pid. Fix: track the headless os_pid (or process-group) on the running entry and reap it in the shared teardown, under the R6 "never break headless fallback" guard.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/claude/coding_agent.ex` — the current one-shot JSON-RPC driver being replaced. Note the behaviour callbacks, the `receive_loop/2` turn state machine, `send_operator_message/2`, `interrupt_turn/2`, and `emit_message/4` (carries `claude_app_server_pid` metadata).
- `src/lib/aiur/coding_agent.ex` — the adapter registry/behaviour. New backend = one `backends/0` entry (modules + `can_interrupt` / `safe_checkpoints` / `remote_control` flags + `models`). Dispatch, routing (`backend_for/1`), and config validation all derive from it.
- `src/lib/aiur/tmux.ex` — the PTY mechanism. `split_pane/6`, `new_hidden_window/3`, `respawn_pane/3`, `send_keys_literal/3`, `join_pane`/`move_pane_*`, `list_panes/2`. Has a `{:mock, pid}` transport that records outbound command strings — the driver's unit tests use it. **Gap:** no `capture-pane` or `kill-pane` helper yet; add the ones this driver needs here.
- `src/lib/aiur/claude/remote_control.ex` — existing RC spawn + `graceful_kill/1` (SIGTERM→wait→SIGKILL), `resolve_transcript_path`/`newest_transcript` (cwd+mtime resolution), `build_handoff/1`. Reuse `graceful_kill/1` for R7 and the transcript-resolution helpers for the tailer.
- `src/lib/aiur/claude/transcript.ex` — `extract(message, fallback_turn_id) :: {:ok, event} | :skip`, today fed JSON-RPC notification shapes by `AgentRunner`. Must be extended (or paralleled) to map **on-disk transcript record shapes** into the same transcript events.
- `src/lib/aiur/agent_runner.ex` — `codex_message_handler` (220-228), `maybe_broadcast_transcript/4` (230-238) → `AgentPubSub.broadcast_transcript`, `run_turn` callsites (414, 669), `drain_operator_messages`. The `on_message` callback contract the driver must keep feeding.
- `src/lib/aiur/opencode/chat_completions.ex` — operator inbound at `send_operator`/`stream_turn` (491) using `delivery_policy: :checkpoint`; SSE render loop gating on `ActiveTurns.lookup`. The instant-delivery path (R3) hooks here.
- `src/lib/aiur/opencode/{pane_manager,slot,hidden_window}.ex` — existing tmux-pane lifecycle for opencode panes; mirror their hidden-window + monitoring conventions for the agent REPL pane.
- `src/lib/aiur/agent_pubsub.ex` / `src/lib/aiur/agent_chat.ex` — `broadcast_transcript/2` fan-out and delivery-policy plumbing.
- `src/lib/aiur/agent_directory.ex:34` — `get_transcript_tail/2` is currently a stub returning `[]`; a real implementation may belong with the tailer (U2).

### Institutional Learnings

- Memory `rc-dual-surface-state` (Q1-RESOLVED): dual-chat proven; the REPL path writes a `bridge-session` record **into the transcript jsonl** (`sessionId == filename UUID`), NOT a `bridge-pointer.json`. Resolve the transcript by **cwd + newest mtime**, never by the cloud bridge token.
- Memory `rc-cloud-mediated`: the "impossible" verdict is scoped to flag/subcommand paths; do not let it block this work.
- Memory `feedback-perf-logging`: emit always-on `aiur_perf` log lines for pane/REPL lifecycle (spawn, RC-activation, first-output, teardown); never gate on `--debug`.
- Memory `feedback-bug-fix-tdd` / `feedback-manual-cli-verification`: manual repro → failing test → fix → manual end-to-end through `scripts/aiur`.
- `src/AGENTS.md` and root `AGENTS.md` conventions apply (tmux manual-driver recipe for non-TTY verification).

### External References

None needed — tmux send-keys driving and transcript tailing are established local patterns (3+ in-repo examples), and the dual-chat mechanism was verified first-hand. External research skipped per ce-plan §1.2.

---

## Key Technical Decisions

- **New backend adapter, not an in-place rewrite of `claude`.** Add a `"claude-repl"` registry entry (`adapter: Aiur.Claude.ReplAgent`, `transcript: Aiur.Claude.Transcript`, `remote_control: true`, `can_interrupt: true`, `safe_checkpoints: []` since delivery is immediate). Rationale: keeps the proven headless `claude` backend intact as the R6 fallback and as the `codex`-parity reference; lets routing/labels select it; avoids a risky big-bang swap. **The backend is NOT the global default** — it is opt-in per R6 (see below).
- **Two decoupled settings, RC defaults OFF (R6).** Surface selection splits into two orthogonal knobs: (1) the existing default-backend/model setting (codex / claude / version) — untouched; (2) a new `remote_control` opt-in, consulted only when the backend supports RC, defaulting OFF. The interactive-REPL *transport* and *RC attachment* are separate concerns: `ReplAgent` can run with RC inactive (a faster local transport) or active (dual-chat). Rationale: honors "keep codex / claude-opencode / claude-RC all selectable"; never silently flips the existing `codex` default; never auto-parks an unattended agent into a human-driven cloud session. Whether interactive-REPL replaces headless `claude` as the default *transport* (RC still off) is decided after U0 proves a UX win — not assumed by this plan.
- **Transport = tmux pane + transcript tail.** `start_session` spawns interactive `claude` in a (hidden) tmux pane via `Aiur.Tmux`, activates `/remote-control`, resolves the transcript path by cwd+mtime, and starts a per-session transcript tailer. `run_turn` sends the prompt via `send_keys_literal` + `Enter` and derives `on_message` events from newly-appended transcript records. Rationale: reuses the exact mechanism proven in the spike and aiur's existing tmux infrastructure.
- **Output comes from the transcript jsonl, not pane scraping.** The transcript is structured JSON (assistant/text/tool/message/bridge-session records); pane capture is ANSI noise. The tailer reads appended records and maps them through the transcript module. Pane capture is used ONLY for coarse lifecycle signals (REPL ready / idle prompt) where the transcript has no explicit marker — see U0.
- **Turn-completion detection is the load-bearing unknown.** JSON-RPC gave an explicit `turn/completed`; the transcript jsonl does not obviously. U0 spikes the most reliable signal (candidate order: a transcript record type that marks turn end; else the REPL prompt returning to idle via debounced pane capture; else a quiescence timeout). The chosen signal is wired in U3.
- **Instant delivery = a new delivery policy.** Add `delivery_policy: :immediate` (or `:repl`) that, for REPL-backed sessions, sends the operator text straight to the pane via `send_operator_message/2` without waiting for a checkpoint. Rationale: the persistent REPL is the thing that makes R3 possible; gate it on the backend being REPL so other backends are unaffected.
- **Permission mode.** Interactive `claude` prompts for tool permissions by default, which would stall autonomous turns. The driver must launch the REPL in the same non-interactive permission posture the headless app-server uses (the configured `permission_mode`). Exact flag/affordance for the interactive REPL is an execution-time unknown (U0/U1) — verify whether `--permission-mode` on the interactive launch is honored, or whether a `/permissions` affordance is required.
- **One RC URL per agent.** Each REPL session has its own RC capability URL. It is a capability token: surface it only to the local operator, never log it (memory + origin constraint). Parity (R5) is about *capability* (both surfaces can act), not about auto-connecting the phone.
- **`claude-remote` is a label-only alias, not a backend (R8).** The registry key stays `claude-repl`; a small alias map (`claude-remote → claude-repl`) is consulted *before* the longest-prefix backend match so `model:claude-remote` resolves whole and never mis-splits into backend `claude` + variant `remote`. A separate "forced-RC" predicate detects the alias label on the issue and forces RC ON for that issue only, OR-ed with the global Setting #2 default. Rationale: gives the operator a one-label switch to force dual-chat per issue without renaming the backend everywhere or flipping the global default; keeps "transport ≠ RC" expressible at the label layer (`model:claude-repl` = transport only, `model:claude-remote` = transport + forced RC). The alias is added to the auto-seeded `model:*` label set.
- **`r` promotes by re-dispatch, not by toggling a separate RC process (R9).** The old `r`-key path attached a *separate* `claude remote-control --spawn` handoff process (mutually exclusive with the headless driver). The redesign makes `r` stop the running agent and re-dispatch the same issue as `claude-remote` (REPL + forced RC), resuming the transcript by cwd. Rationale: with the persistent-REPL backend there is no longer a reason to run a second, mutually-exclusive RC process — one agent, one transcript, RC attached at launch via the flag (U1). This unifies "follow + chat from both surfaces" under a single agent and retires the handoff toggle. Consistent with R0: the re-dispatched agent keeps self-driving; RC is the takeover channel.

---

## Open Questions

### Resolved During Planning

- *Which PTY mechanism?* tmux via `Aiur.Tmux` — already in the repo, already used for every opencode pane, proven in the spike. No new dependency.
- *New backend or rewrite?* New `claude-repl` backend adapter; keep headless `claude` as fallback.
- *Where does output come from?* The shared transcript jsonl tail, mapped through `Aiur.Claude.Transcript`.

### Resolved by U0 spike (2026-06-08, scratch REPL, claude 2.1.149, workspace `/tmp/aiur-spike-u0`)

- **Turn-completion signal — SOLVED, structured, in-transcript (no pane-scraping needed).** Every `assistant` record carries `message.stop_reason`. All intra-turn assistant records have `stop_reason: "tool_use"`; the final one has **`stop_reason: "end_turn"`**. So turn-end = an assistant record with `stop_reason: "end_turn"` (also handle `"stop_sequence"`/`"max_tokens"` as terminal). This is the clean `turn/completed` equivalent — wire it in U3; the idle-prompt capture fallback is unnecessary.
- **Mid-turn injection — DEFINITIVE PASS (the gating question).** A message typed during an actively-generating turn is accepted into claude's **native queue** (transcript `queue-operation: enqueue` the instant it's sent; `remove` ~5s later) and folded into the SAME turn at the next natural boundary, *without aborting in-flight work*. No interrupt-then-send needed; R3 is achievable by forwarding keystrokes only (see U4, and memory [[repl-native-message-ux]]).
- **Permission posture — honored interactively.** Launching with `--permission-mode bypassPermissions` showed `⏵⏵ bypass permissions on` in the REPL footer; the turn made 4 autonomous git commits + ran tests with NO blocking permission prompt. Carry the headless backend's `permission_mode` onto the interactive launch (U1).
- **On-disk transcript record types (for the U2 parser):** observed `assistant`, `user`, `attachment`, `permission-mode`, `file-history-snapshot`, `ai-title`, `last-prompt`, `queue-operation`, `system`. `sessionId` in every record == the filename UUID (confirms cwd+mtime resolution; no `bridge-pointer.json`). The `queue-operation` record (enqueue/remove + `content`) is a usable operator-message receipt signal for R4 pub/sub.
- **RC activation method — SOLVED, prefer the launch flag.** `claude --remote-control [name]` is a documented flag ("Start an interactive session with Remote Control enabled", `claude --help`). Verified in a scratch REPL (workspace `/tmp/aiur-spike-u0b`): `claude --remote-control <name> --permission-mode bypassPermissions --model claude-opus-4-8` boots a NORMAL interactive REPL with RC attached at boot (`/remote-control is active`, footer `Remote Control active`, `⏵⏵ bypass permissions on`) and writes a `bridge-session` record (`sessionId == filename UUID`, `bridgeSessionId: cse_…`, `lastSequenceNum: 0`) — identical to the slash path, but no fragile send-keys typing or `"Remote Control active"` string-match needed. The earlier "flag is silently inert" result was specific to `--input-format stream-json`; it does NOT apply to interactive launch. U1: attach RC via the launch flag, not the slash command.
- **R0 autopilot invariant — CONFIRMED in practice (the "autopilot change doesn't cause issues" check).** Drove an aiur-style task into the flag-launched RC REPL via `tmux send-keys` (simulating aiur's autonomous loop, NO human at the phone). The agent self-completed the turn end-to-end — `Write(autopilot.txt)` → reported `done` → returned to idle `❯` — with RC attached the whole time. So RC attachment does NOT park the agent or require human input to make progress; autonomy and RC coexist. This is the mechanical proof behind [[rc-autonomy-invariant]] (RC = takeover channel, not handoff).

### Deferred to Implementation
- Exact `Aiur.Claude.Transcript.extract` changes for the on-disk record shapes above — U2, against captured real records.
- Pane placement (hidden window vs visible) and how/whether the REPL pane is ever shown to the operator — U1; default hidden, mirror `HiddenWindow`.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
                       ┌─────────────────────────── aiur (BEAM) ───────────────────────────┐
 opencode pane ──POST──▶ chat_completions.ex ──:immediate──▶ AgentChat ──▶ AgentRunner       │
   (operator)          │                                                      │ run_turn      │
                       │                                                      ▼               │
                       │                                          Aiur.Claude.ReplAgent       │
                       │                                          │  send_keys_literal + Enter │
                       │                                          ▼                            │
                       │                                   ┌── tmux pane ──┐                   │
                       │                                   │ claude (REPL) │◀── cloud RC ───────┼──▶ Claude app
                       │                                   │ /remote-control│                   │   (phone / web)
                       │                                   └──────┬─────────┘                   │   (operator)
                       │                                          │ appends                     │
                       │                                          ▼                             │
                       │   transcript tailer ◀──reads── ~/.claude/projects/<slug>/<uuid>.jsonl  │
                       │        │ extract → broadcast_transcript                                │
                       │        ▼                                                               │
                       │   AgentPubSub ──▶ opencode SSE render (both surfaces' turns appear)    │
                       └────────────────────────────────────────────────────────────────────────┘
```

Decision matrix — input source vs. effect (the parity/sync model):

| Operator acts from… | How it reaches the agent | How the OTHER surface sees it |
|---|---|---|
| opencode (TUI) | `send_keys` into the REPL pane | transcript record appended → tailer → broadcast → (Claude app via cloud) |
| Claude app (phone/web) | cloud RC bridge → REPL | transcript record appended → tailer → broadcast → opencode SSE |

---

## Implementation Units

- [x] U0. **Spike (HARD GO/NO-GO GATE): turn-completion + mid-turn-injection + permission posture + transport-UX**

**This is a gate, not a step.** No production code in U1+ is written until U0 answers its questions. The make-or-break finding is (b): if a live REPL will NOT accept a message mid-turn (even via interrupt-then-send), then R3 (instant mid-turn receipt — the user's requirement #2) is not achievable as designed and the plan must change before building. The dual-chat spike only proved *sequential* turns land in one transcript; mid-turn injection during an actively-generating turn is **unproven** and is the highest-risk assumption in this plan.

**Goal:** Resolve four load-bearing unknowns before building the driver:
- (a) the most reliable turn-completion signal from a live REPL;
- (b) **[GATING]** whether `send_keys` injected *during* an active long turn is accepted clean, queued, or rejected — and if rejected, whether interrupt-then-send (e.g. `Esc`) works;
- (c) whether the interactive REPL honors a non-interactive permission mode for autonomous tool use;
- (d) **transport-UX (decoupling check):** does the interactive REPL transport, *with RC OFF*, measurably improve the chat UX (faster perceived turns, easier mid-turn receipt) vs the headless one-shot path? This answers whether interactive-REPL should become the default `claude` transport per R6, independent of RC.

**Requirements:** R1, R2, R3, R6

**Dependencies:** None

**Files:**
- Scratch only (tmux pane + a temp workspace). No production code. Findings recorded in the plan's "Deferred to Implementation" resolutions and in memory `rc-dual-surface-state`.

**Approach:**
- Drive a scratch interactive `claude` in a tmux pane (as in the proven spike). Issue a multi-step task that takes tens of seconds. While it runs, `send_keys` an operator message; observe whether it is consumed mid-turn, queued, or rejected. If rejected, try `Esc`-then-send and record behavior.
- Compare turn-completion signals: scan the transcript jsonl record types around a completed turn for an end-of-turn marker; in parallel sample `capture-pane` for the idle prompt (`❯`) returning. Pick the most reliable.
- Launch the REPL with the configured permission mode and confirm a tool-using turn proceeds without a blocking permission prompt; if it blocks, identify the affordance.
- Transport-UX: with RC off, run a couple of representative turns and qualitatively compare latency/mid-turn behavior to the headless path, enough to make the R6 default-transport call.

**Execution note:** Exploratory spike — no tests; the deliverable is decisions, recorded back into this plan and memory. Kill only scratch panes (never the operator's live workspace-99 RC session, pid 1319336).

**Test scenarios:** Test expectation: none — spike produces decisions, not shippable code.

**Verification / gate criteria:** All four questions have concrete answers written into the plan. **If (b) is "rejected even with interrupt-then-send," STOP and revisit R3 with the operator before U1.** Otherwise U1–U4 proceed without guessing, and R6's default-transport decision (d) is settled.

---

- [x] U1. **REPL session lifecycle: spawn pane, activate RC, resolve transcript**

**Goal:** New `Aiur.Claude.ReplAgent.start_session/2` and `stop_session/1`: spawn interactive `claude` in a (hidden) tmux pane, wait for REPL readiness, issue `/remote-control`, resolve the transcript path (cwd+mtime), and return a session map `%{backend: "claude-repl", pane_id, transcript_path, cwd, thread/uuid, model}`.

**Requirements:** R1, R2, R7

**Dependencies:** U0

**Files:**
- Create: `src/lib/aiur/claude/repl_agent.ex`
- Modify: `src/lib/aiur/tmux.ex` (add `capture_pane/2` and `kill_pane/2` helpers; both via `run_args`, mockable)
- Modify: `src/lib/aiur/claude/remote_control.ex` — `resolve_transcript_path/1` (297) and `newest_transcript/2` (312) are currently `defp`. Promote to public (or move the cwd+mtime resolution into a shared module both `RemoteControl` and `ReplAgent` call) so the REPL driver can reuse them rather than duplicating the logic.
- Test: `src/test/aiur/claude/repl_agent_test.exs`
- Test: `src/test/aiur/tmux_test.exs` (extend for the two new helpers)

**Approach:**
- Spawn via `Aiur.Tmux.new_hidden_window/3` (or `split_pane` into the hidden window) running `claude` with the workspace cwd, configured model, and permission posture from U0. When RC is opted in (Setting #2), launch with the `--remote-control <name>` flag so the bridge attaches at boot (resolved by U0 — no slash send-keys, no string-match). When RC is off, launch `claude` plain.
- Readiness: poll `capture_pane` for the prompt; bounded timeout → `{:error, :repl_not_ready}`.
- RC activation (RC opted in): confirm attachment via the `bridge-session` transcript record (`bridgeSessionId` present), not pane string-matching; surface (never log) the RC URL to the operator-facing layer only.
- **RC URL redaction contract (security):** the URL is a capability token. `Perf.event/2` (`perf.ex`) emits the full meta map to both `Logger.info` and a Phoenix.PubSub broadcast, and `renderer.ex` shows the RC URL in the TUI footer. So the URL must NEVER be placed in any `Perf.event` meta or any `Logger` call; pass it only through the dedicated operator-facing display path the renderer already uses for RC URLs. Add a test/guard that no perf/log line contains the token.
- Transcript resolution: reuse `RemoteControl.resolve_transcript_path/newest_transcript` (cwd+mtime). The transcript may not exist until the first turn — tolerate that and resolve lazily on first `run_turn`.
- `stop_session`: `kill_pane` + `RemoteControl.graceful_kill/1` on the `claude` OS pid; confirm dead (R7).

**Patterns to follow:** `src/lib/aiur/opencode/hidden_window.ex`, `src/lib/aiur/claude/remote_control.ex` (spawn + graceful_kill), `Aiur.Tmux` mock-transport tests.

**Test scenarios:**
- Happy path: `start_session` issues the expected tmux split/new-window command, then `send-keys "/remote-control"` + Enter (assert via `{:mock, pid}` outbound strings); returns a session map with `backend: "claude-repl"` and a `pane_id`.
- Edge case: REPL never reaches readiness within timeout → `{:error, :repl_not_ready}` and the pane is killed (no leak).
- Edge case: transcript file absent at session start → session still returns ok; path resolved lazily.
- Error path: `Aiur.Tmux` returns `{:error, :no_tmux}` → `start_session` returns `{:error, _}` cleanly.
- Integration (R7): `stop_session` issues `kill-pane` AND calls `graceful_kill` with the captured pid; after it, the pid is gone.

**Verification:** A real `start_session` against a scratch workspace yields a live REPL pane with RC active and a resolvable transcript; `stop_session` leaves no `claude` process or pane behind.

---

- [x] U2. **Transcript-jsonl tailer → transcript events**

**Goal:** A per-session tailer that watches the resolved transcript jsonl, reads newly-appended records, maps them through `Aiur.Claude.Transcript.extract/2` (extended for on-disk record shapes), and invokes the driver's `on_message` callback — the REPL-mode replacement for the JSON-RPC notification stream.

**Requirements:** R1, R4

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/claude/transcript_tailer.ex`
- Modify: `src/lib/aiur/claude/transcript.ex` — **scope warning:** `extract/2` today is gated on the JSON-RPC `item/created` notification envelope and returns `:skip` for on-disk record shapes, so this is a **new parser branch**, not a small tweak. Add on-disk handling (`text`/`assistant`/`message`/tool records) and ignore `bridge-session`/`system`/`file-history-snapshot`, keyed off the on-disk record structure. Budget this as real work and test it against captured real records.
- Modify: `src/lib/aiur/agent_directory.ex` (implement `get_transcript_tail/2` against the tailer instead of the `[]` stub, if it fits cleanly)
- Test: `src/test/aiur/claude/transcript_tailer_test.exs`
- Test: `src/test/aiur/claude/transcript_test.exs` (on-disk record extraction)

**Approach:**
- Track byte offset (or last-seen record index) per file; on change, read appended lines, `Jason.decode` each, map via `Transcript.extract`, emit. Use the same `tail -F`-friendly assumptions the repo already relies on (`log_file.ex` notes disk syncs).
- Distinguish records authored by either surface — both appear identically in the transcript, which is exactly what makes R4 parity work; the tailer does not care which surface produced a record.
- Decide poll vs filesystem-watch: prefer a simple debounced poll (matches the repo's 2s screen-grab cadence) unless U0 shows latency matters.

**Patterns to follow:** `RemoteControl.read_transcript/newest_transcript`, `Aiur.Codex.Transcript`/`Aiur.Claude.Transcript.extract` contract, `agent_runner.ex` `maybe_broadcast_transcript`.

**Test scenarios:**
- Happy path: appending an assistant `text` record to a temp jsonl makes the tailer emit one extracted event with the right body/turn id.
- Edge case: a partially-written final line (no trailing newline) is not emitted until complete.
- Edge case: `bridge-session`, `system`, and `file-history-snapshot` records are skipped (no spurious transcript events).
- Edge case: file truncation / rotation / replacement (new UUID file) is detected and re-resolved without crashing.
- Integration (R4): a record appended by the *cloud* surface (simulated by writing a record as the Claude app would) is emitted identically to a locally-authored one — proving surface-agnostic fan-out.

**Verification:** Writing representative real records (captured from a live REPL transcript) through the tailer yields the same transcript events the JSON-RPC path produced for equivalent turns.

---

- [x] U3. **`run_turn/4` over the REPL**

**Goal:** Implement `ReplAgent.run_turn/4`: send the prompt to the pane, stream transcript-tailer events to `on_message`, detect turn completion (U0 signal), and return `{:ok, result}` / `{:error, reason}` with the same shape the orchestrator expects. Preserve `session_id`/`thread_id`/`turn_id` semantics.

**Requirements:** R1, R4

**Dependencies:** U1, U2

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex`
- Test: `src/test/aiur/claude/repl_agent_test.exs`

**Approach:**
- Send prompt: `send_keys_literal <prompt>` then `Enter`. Multi-line prompts: send the body literally, then Enter once (verify newline handling against U0; bracketed-paste may be needed).
- Drive completion from the tailer using the U0-chosen signal; enforce `Config.agent_turn_timeout_ms()` as the backstop (mirror `coding_agent.ex` timeout semantics).
- Emit `:session_started` / `:turn_completed` analogues so `AgentRunner` and `ActiveTurns` see the same lifecycle events as the JSON-RPC path.
- Map a turn id stable for the duration of the turn (the transcript UUID + a per-turn counter, since there is no JSON-RPC `turn.id`).

**Execution note:** Implement against a recorded/fake tailer feed first (test-first for the lifecycle), then validate against a live REPL.

**Test scenarios:**
- Happy path: a prompt produces send-keys+Enter, tailer events flow to `on_message`, the completion signal returns `{:ok, %{session_id, turn_id, ...}}`.
- Edge case: no completion signal before `agent_turn_timeout_ms` → `{:error, :turn_timeout}`, session left usable for the next turn.
- Edge case: empty/whitespace prompt is rejected without sending stray keys.
- Error path: the REPL pane died mid-turn (kill) → `{:error, :repl_gone}` surfaced, not a hang.
- Integration: two sequential `run_turn` calls reuse the one persistent session (no respawn) and both turns land in the one transcript.

**Verification:** End-to-end through `scripts/aiur`, a dispatched issue runs a real turn in the REPL and the opencode view renders the agent's output via the tailer.

---

- [x] U4. **Instant mid-turn operator delivery (`send_operator_message` + `:immediate` policy)**

**Goal:** `ReplAgent.send_operator_message/2` injects operator text straight into the live REPL pane via `send_keys`, and opencode operator messages for REPL-backed sessions use a new `delivery_policy: :immediate` so they reach the agent mid-turn instead of waiting for a checkpoint (R3).

**Requirements:** R3, R4, R5

**Dependencies:** U1, U3, **U0's GATING mid-turn-injection finding** (if U0 found injection impossible, this unit's design must change before it starts)

> **Blocking-path note (the P0 the review surfaced):** R3 is not just a new policy value — it crosses two existing chokepoints that currently make mid-turn delivery impossible. Both MUST be addressed or `:immediate` is silently dropped:
> 1. **Orchestrator rejects unknown policies.** `orchestrator.ex` `accepted_delivery_policies/1` (~3641-3642) returns only `[:checkpoint]` / `[:checkpoint, :interrupt]`, and `normalize_delivery_request/3` (~3279-3296) has a catch-all returning `{:error, :invalid_message}`. `:immediate` dies here unless added for REPL-backed sessions.
> 2. **AgentRunner is synchronously blocked during a turn.** `agent_runner.ex` calls `CodingAgent.run_turn` synchronously (~413-421) and only drains operator messages *between* turns (`drain_operator_messages` with `after 0`). A turn in flight cannot currently receive an injected message at all. R3 needs a concurrent path: the operator message must reach `ReplAgent.send_operator_message` (which does the `send_keys`) WITHOUT waiting for `run_turn` to return — e.g. deliver straight to the driver/pane out-of-band of the run_turn loop. The exact mechanism is an execution decision, but the synchronous block is the load-bearing obstacle and this unit owns removing it for REPL sessions.

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (`send_operator_message/2`)
- Modify: `src/lib/aiur/orchestrator.ex` — `accepted_delivery_policies/1` (~3641) and `normalize_delivery_request/3` (~3279) must accept `:immediate` for REPL-backed sessions
- Modify: `src/lib/aiur/agent_runner.ex` — concurrent mid-turn delivery path so an `:immediate` message reaches the driver while `run_turn` is still blocked (today it only drains between turns)
- Modify: `src/lib/aiur/opencode/chat_completions.ex` (select `:immediate` for REPL-backed sessions at `send_operator`/`stream_turn`, ~491)
- Modify: `src/lib/aiur/agent_chat.ex` and/or `src/lib/aiur/agent_pubsub.ex` (define/route the `:immediate` delivery policy)
- Modify: `src/lib/aiur/coding_agent.ex` (registry: `claude-repl` advertises immediate delivery, e.g. `safe_checkpoints: []` + a delivery hint)
- Test: `src/test/aiur/claude/repl_agent_test.exs`, `src/test/aiur/opencode/chat_completions_test.exs`, `src/test/aiur/agent_chat_test.exs`, `src/test/aiur/orchestrator_test.exs`, `src/test/aiur/agent_runner_test.exs`

**Approach (settled by U0 — match native claude/codex UX, do NOT build bespoke delivery):**
- `send_operator_message` = `send_keys_literal <text>` + `Enter` into the live REPL pane. **That's it.** U0 proved the native claude queue handles the rest correctly: the message is `enqueue`d instantly (operator sees it land, can edit it), the agent finishes its current step, then folds it in at the next natural boundary — *without aborting in-flight work*. We inherit this for free; we do not implement interrupt-then-send or any custom mid-turn machinery as the default path.
- **Do NOT cut the agent off.** The `Esc`/abort affordance (cutting the agent off mid-step, then sending) is a SEPARATE, explicit operator action kept for parity (R5), never the normal message path.
- The `:immediate` "policy" is really just **pass-through, not a hold**: for REPL-backed sessions aiur must stop *holding* the message at its own `:checkpoint` gate and forward it to the live process. Instant *receipt* into the agent's native queue is the goal; mid-turn *consumption* is a bonus the native queue may grant, not something to force.
- **Sanitize operator text before `send_keys` (security):** operator/chat content is injected into a live PTY. Send it as literal data (`send_keys_literal` / bracketed-paste), never down a shell-interpreted path, and strip/escape control sequences so a crafted message cannot inject extra keystrokes or terminal escape codes into the REPL. Add a test with a hostile payload (embedded `Enter`, `Esc`, control chars).
- Route selection by backend: only `claude-repl` sessions get pass-through (`:immediate`); other backends keep `:checkpoint` (no regression).

**Test scenarios:**
- Happy path: an operator message on a REPL session sends keys to the pane immediately (assert mock outbound), no checkpoint wait.
- Edge case: operator message while no turn is active still delivers (starts a turn).
- Edge case: a non-REPL (headless `claude` / `codex`) session still uses `:checkpoint` — explicit regression guard.
- Integration (R4/R5): an operator message sent from opencode appears in the shared transcript and is therefore visible to the Claude app surface too.

**Verification:** During a long live REPL turn, a message typed in the opencode pane reaches the agent and influences the in-progress work (not just after completion).

---

- [x] U5. **Register the `claude-repl` backend + routing + parity wiring**

**Goal:** Add the `claude-repl` entry to the `Aiur.CodingAgent` registry so dispatch, transcript module, delivery defaults, RC-capability, routing labels, and config validation all resolve; verify feature parity (R5) across both surfaces through the shared transcript.

**Requirements:** R1, R5, R6

**Dependencies:** U2, U3, U4

**Files:**
- Modify: `src/lib/aiur/coding_agent.ex` (`backends/0` entry; ensure `known_backends`, `override_labels`, `remote_control?`, `transcript_module`, `safe_checkpoints` derive correctly)
- Modify: `src/lib/aiur/config/schema.ex` (accept `claude-repl` as a valid `agent.kind` / routing target)
- Modify: `src/lib/aiur/github/labels.ex` (auto-seeded `model:claude-repl[-variant]` labels, if variants apply)
- Test: `src/test/aiur/coding_agent_test.exs`, `src/test/aiur/config/schema_test.exs`

**Approach:**
- One registry entry per the Key Technical Decision. Confirm `backend_for/1` can select it via `model:claude-repl` label and via routing/global default.
- Parity check (R5): enumerate operator actions (send message, steer mid-turn, pause/interrupt) and confirm each is reachable from opencode (via U4) and from the Claude app (native RC), both landing in the transcript.
- **Backfill-on-attach is DISPLAY-ONLY — it must NEVER re-prompt the agent (operator directive 2026-06-08).** When opencode opens a mid-flight agent, replay the existing transcript so the operator sees full history (chat, thoughts, commands, tools, skills) from BOTH surfaces, then continue the live conversation. Implement backfill as a read-only `TranscriptTailer` opened `from: :start` whose events are broadcast for display only. The tailer holds no tmux handle and has no `send_keys` path, so it is structurally incapable of writing to the pane — preserve that property; do not route replayed events into any delivery/`send_operator_message` path. Phone-typed user *prompts* land on disk as a bare string and currently yield no transcript event (`extract_disk_record` "bare user prompt → []"), so the operator's own phone messages will not appear in replayed history until this unit maps user-text records to `:user` events.

**Test scenarios:**
- Happy path: `backend_for` resolves `claude-repl` from a `model:claude-repl` label; `adapter/1` returns `Aiur.Claude.ReplAgent`; `transcript_module/1` returns `Aiur.Claude.Transcript`.
- Edge case: `remote_control?("claude-repl")` is true; `safe_checkpoints("claude-repl")` reflects immediate delivery.
- Edge case: unknown backend still fails loud (existing behavior unchanged).
- Config: `agent.kind: claude-repl` passes schema validation; an invalid kind still rejects.

**Verification:** Setting the backend to `claude-repl` for an issue dispatches it through the REPL driver end-to-end with both surfaces able to act.

---

- [x] U6. **Two-setting surface config (RC opt-in, default OFF) + safe fallback**

**Goal:** Implement the R6 two-setting model. Setting #1 (default backend/model) is unchanged. Add Setting #2 — a `remote_control` opt-in, consulted only for RC-capable backends, **defaulting OFF**. Optionally (gated on U0(d)) allow interactive-REPL to be the default *transport* for `claude` with RC still off. Provide a documented fallback to the headless `claude` backend if REPL launch fails, so a tmux/RC problem never strands an issue.

**Requirements:** R6, R1

**Dependencies:** U5

**Files:**
- Modify: `src/lib/aiur/config/schema.ex` and config defaults — **do NOT change the existing `field(:kind, :string, default: "codex")` default.** Add a separate opt-in knob (e.g. `agent.remote_control` boolean, default `false`, and/or `agent.claude_transport` ∈ `headless | repl` if U0(d) justifies a default-transport switch). RC is only meaningful when the resolved backend is RC-capable.
- Modify: `src/lib/aiur/agent_runner.ex` (on `start_session` `{:error, _}` from the REPL backend, fall back to headless `claude` and log `aiur_perf` fallback)
- Test: `src/test/aiur/agent_runner_test.exs`, `src/test/aiur/config/schema_test.exs`

**Approach:**
- Keep the two settings orthogonal and explicit so behavior is obvious and revertible (the whole feature lives on `kevin/repl-dualchat`; the fallback to headless is the in-product safety net).
- **Default posture:** RC OFF. An agent only attaches `/remote-control` when the operator turns the opt-in on (globally or per-session). With RC off, an unattended agent runs autonomously exactly as today.
- **Single flippable default (operator directive 2026-06-08):** the no-setting-present default must live in exactly ONE place — the `Config.Schema` field default(s) — so switching to always-remote (or interactive-transport-by-default) later is a **one-line change**, not edits scattered across call sites. Every code path reads the config knob via the resolver (`backend_for/1` / a `Config` accessor); nothing hard-codes the default. Add a test asserting the resolver honors the config default so a future flip is provably one-line.
- Fallback path: if `ReplAgent.start_session` fails (no tmux, REPL not ready, RC activation failed), `AgentRunner` retries once with the headless `claude` backend and records why.

**Test scenarios:**
- Default path: with no opt-in set and no override, dispatch behavior is **unchanged** — the existing `codex`/`claude` default and `:checkpoint` delivery apply; no agent is auto-parked into RC.
- Opt-in path: with `agent.remote_control: true` (and an RC-capable backend), a dispatched issue resolves into the REPL driver with RC active.
- **Autonomy-under-RC (R0):** with RC active and NO dev input, the agent still drives the feature to completion on its own (aiur's autonomous loop keeps feeding turns; RC attachment does not park or suppress it). A dev message injected mid-run changes course but is not *required* for progress.
- Error path: REPL `start_session` returns `{:error, :repl_not_ready}` → `AgentRunner` falls back to headless `claude` and the issue still runs.
- Edge case: an explicit `model:claude` override still pins the headless backend; `model:codex` is unaffected by the RC opt-in.

**Verification:** With the RC opt-in OFF (default), `scripts/aiur` behaves exactly as before. With it ON, a dispatched issue lands in a REPL+RC agent with opencode follow/chat live; killing tmux before dispatch makes it fall back to headless without stranding the issue.

---

- [x] U7. **Teardown hardening: no orphaned REPL process or pane**

**Goal:** Guarantee R7 across all exit paths (normal completion, error, orchestrator shutdown, crash): the `claude` REPL OS process and its tmux pane are confirmed dead. This subsumes the origin's blocking bug #1.

**Requirements:** R7

**Dependencies:** U1, U3

**Files:**
- Modify: `src/lib/aiur/claude/repl_agent.ex` (`stop_session`, crash/cleanup paths)
- Modify: `src/lib/aiur/orchestrator.ex` (ensure the REPL session's pid+pane are tracked in the running entry and torn down on completion/abort). **Reference correction:** the existing `codex_app_server_pid` is the real model to mirror (tracked at ~1888, ~2897, torn down ~3979-4015). Note that `coding_agent.ex:210` *emits* `claude_app_server_pid` but **nothing consumes it** — do not assume a working claude-side teardown to copy; add the REPL pid/pane tracking by following the `codex_app_server_pid` pattern.
- Modify: `src/lib/aiur/shutdown.ex` (sweep REPL panes on app shutdown, alongside existing sweeps)
- Test: `src/test/aiur/claude/repl_agent_test.exs`, `src/test/aiur/orchestrator_test.exs`

**Approach:**
- `stop_session` = `kill_pane` + `RemoteControl.graceful_kill/1` on the OS pid, then verify both gone; log `aiur_perf` teardown with outcome.
- Track the REPL pid+pane id in the orchestrator running entry so an abort/shutdown can reach them even if the session map is lost.
- Reaper sweep: extend the existing dead-socket/reaper sweep (recent commits scoped an aiur reaper) to also kill stray `claude` REPL panes whose owning agent is gone.

**Execution note:** Manual repro first (start a REPL agent, force-abort, confirm with `ps`/`tmux list-panes` that nothing survives), then a failing test, then the fix.

**Test scenarios:**
- Happy path: normal `stop_session` kills pane + pid; both confirmed gone.
- Error path: turn errors out → teardown still runs (no leaked pane).
- Edge case: pid already dead but pane alive (or vice versa) → teardown still cleans the survivor, no crash.
- Integration: orchestrator abort of an in-flight REPL agent leaves no `claude` process and no tmux pane.

**Verification:** Stress: dispatch, abort, and shut down REPL agents repeatedly; `ps aux | grep claude` and `tmux list-panes` show zero orphans afterward.

---

- [x] U8. **Operator-facing `model:claude-remote` label alias that forces RC**

**Goal:** Add the label-only alias `model:claude-remote` → backend `claude-repl` that, when present on an issue, forces remote-control ON for that issue regardless of the global Setting #2 default. Keep `claude-repl` as the internal backend key everywhere; auto-seed the alias as a GitHub label.

**Requirements:** R8 (and upholds R6's "Setting #2 defaults OFF" globally — the alias is a per-issue override, not a default flip).

**Dependencies:** U5 (registry + `backend_for/1` resolution), U6 (the `remote_control` opt-in this alias overrides).

**Files:**
- Modify: `src/lib/aiur/coding_agent.ex` — alias map consulted before the longest-prefix backend match in spec resolution; a public forced-RC predicate over an issue's labels; add the alias to the auto-seeded `model:*` label set.
- Modify: `src/lib/aiur/agent_runner.ex` — the RC-resolution line so `rc?` is `(forced? OR global opt-in) AND backend RC-capable`.
- Modify: `src/lib/aiur/github/labels.ex` (or wherever `override_labels/0` is consumed for seeding) — ensure the alias label is created in the repo.
- Test: `src/test/aiur/coding_agent_test.exs`, `src/test/aiur/agent_runner_test.exs`.

**Approach:**
- Resolve `model:claude-remote` via an explicit alias map checked *first*, returning `{"claude-repl", nil}` so it never falls through to the `claude` prefix match (the mis-split bug). Bare `model:claude-repl` keeps resolving to transport-only (RC per global default).
- A forced-RC predicate scans the issue's labels for an alias whose presence forces RC; `agent_runner` OR-es it with the global opt-in before AND-ing with backend RC-capability. No other backend is affected.
- Seed the alias label alongside the existing `model:<backend>[-variant]` labels so it exists in GitHub for the operator to apply.

**Patterns to follow:** the existing `resolve_backend_spec/2` longest-match resolution and `override_labels/1` seeding in `src/lib/aiur/coding_agent.ex`; the existing `rc?` computation in `run_codex_turns` (`src/lib/aiur/agent_runner.ex`).

**Test scenarios:**
- Happy path: an issue labeled `model:claude-remote` resolves backend `claude-repl`, pins no model variant, and the forced-RC predicate returns true.
- Happy path: `model:claude-repl` (no alias) resolves `claude-repl` and forced-RC is false (RC follows the global default).
- Edge case: `model:claude-remote` is NOT mis-resolved to backend `claude` + variant `remote`.
- Integration: in `run_codex_turns`, an alias-labeled issue yields `rc? = true` even with the global `agent.remote_control` default OFF; a non-RC-capable backend with the alias still yields `rc? = false` (AND with capability holds).
- Seeding: `override_labels/0` includes `model:claude-remote`.

**Verification:** Dispatch an issue labeled `model:claude-remote` through `scripts/aiur` with the global RC default OFF; confirm it launches the REPL agent with `--remote-control` attached and self-drives (R0), while an issue labeled only `model:claude-repl` launches the REPL transport with RC off.

---

- [x] U9. **Rewire the `r` key: promote a running agent to `claude-remote` by re-dispatch**

**Goal:** Replace the old RC handoff toggle so pressing `r` on a running non-remote agent (headless `claude` or `codex`) **adds the `model:claude-remote` label** to the issue, stops the current agent, and re-dispatches the same issue as `claude-remote` (persistent REPL + forced RC), resuming the existing transcript/session by cwd. `r` stays a true toggle: pressed on an already-remote agent it **removes the label** and re-dispatches as the default (non-remote) backend. The `model:claude-remote` label is the durable single source of truth for remote-ness — it survives crash-triggered re-dispatches (the orchestrator re-fetches labels from GitHub on retry) and drives the agent-list remote indicator.

**Requirements:** R9, R0 (the re-dispatched agent self-drives; RC is the takeover channel), R8 (re-dispatch uses the `claude-remote` selection so RC is forced).

**Dependencies:** U5, U6, U8 (re-dispatch targets the `claude-remote` alias), U1–U4 (the REPL backend the agent is promoted into).

**Files:**
- Modify: `src/lib/aiur/agent_list/app.ex` — the `r`-key handler (`toggle_remote_control` cast → `toggle_selected_agent_remote_control` → `toggle_agent_remote_control` → `handle_remote_control_result`) so it requests promotion/re-dispatch instead of the old toggle.
- Modify: `src/lib/aiur/orchestrator.ex` — replace the old `set_remote_control` → `launch_remote_control` → `do_launch_remote_control` (`claude remote-control --spawn` handoff) with a stop-current-agent + re-dispatch-as-`claude-remote` flow that resumes the issue's transcript by cwd. Retire the now-dead handoff path as part of the end-of-build dead-code pass (guarded: do not break codex or the headless fallback).
- Test: `src/test/aiur/orchestrator_test.exs`, and an `agent_list` test for the `r`-key cast routing if one exists.

**Approach:**
- On `r` for a running non-remote agent: stop the current agent cleanly (existing stop path), then re-dispatch the same issue selecting the `claude-remote` alias (forces RC via U8) so the new REPL agent resumes the existing transcript/session via cwd+mtime resolution (no new conversation).
- Reuse the existing dispatch entry point rather than the bespoke handoff spawn; the `claude remote-control --spawn` path becomes unreachable for this flow and is removed under the dead-code guards.
- Keep the result feedback the `r` key already surfaces (`{:ok, :on}` / `{:error, :unsupported}` analogues) so the AgentList UX still reports success/failure.

**Patterns to follow:** the existing dispatch flow used by the orchestrator to start an issue's agent; the existing `r`-key cast plumbing in `src/lib/aiur/agent_list/app.ex`; transcript-resume-by-cwd from `src/lib/aiur/claude/remote_control.ex`.

**Execution note:** Manual repro first — dispatch a plain `codex`/headless-`claude` agent, press `r`, confirm the old agent stops and a `claude-remote` REPL agent resumes the same transcript — then a failing test, then the rewire.

**Test scenarios:**
- Happy path: `r` on a running headless-`claude` agent stops it and re-dispatches the issue as `claude-remote` (REPL + RC), same workspace/transcript.
- Happy path: `r` on a running `codex` agent does the same (codex is non-RC-capable, so promotion is the only way it reaches RC).
- Edge case: `r` on an agent that is already `claude-remote`/RC does not double-dispatch (no-op or documented toggle-off, matching current UX).
- Error path: re-dispatch failure surfaces a clear result to the AgentList (no silent stop that strands the issue with no running agent).
- Integration: after promotion, the resumed agent self-drives the issue end-to-end (R0) with RC attached, and both surfaces act on one transcript (R5).

**Verification:** Through `scripts/aiur`: start an issue on `codex` (or headless `claude`), press `r` in the AgentList, confirm the original agent is gone (no orphan, R7), a `claude-remote` REPL agent is running on the same issue/transcript with RC attached, and it continues autonomously.

---

## System-Wide Impact

- **Interaction graph:** new pane lifecycle touches `Aiur.Tmux`, `PaneManager`/`HiddenWindow` conventions, `AgentRunner` (`on_message` + run_turn callsites), `chat_completions.ex` (inbound), `AgentPubSub`/`AgentChat` (delivery policy + fan-out), `orchestrator.ex` (running-entry tracking + teardown), `shutdown.ex` (sweep), the `CodingAgent` registry.
- **Error propagation:** REPL launch failures must degrade to the headless fallback (U6), never strand an issue. Turn timeouts and pane death surface as `{:error, _}` with the same shape the orchestrator already handles.
- **State lifecycle risks:** orphaned `claude` processes/panes (U7); transcript file rotation mid-session (U2); a turn whose completion signal is missed (U3 timeout backstop).
- **API surface parity:** `ReplAgent` must implement every `Aiur.CodingAgent` callback; the registry-derived helpers (`safe_checkpoints`, `remote_control?`, `transcript_module`) must all return sane values for `claude-repl`.
- **Integration coverage:** cross-surface sync (an action from one surface appears to the other) is only provable end-to-end; unit tests use the tmux `{:mock, pid}` transport and temp transcript files, but each phase ends with a live `scripts/aiur` check.
- **Unchanged invariants:** the headless `claude` and `codex` backends keep their exact current behavior (one-shot JSON-RPC, `:checkpoint` delivery). `:immediate` delivery and the REPL transport are gated strictly on the `claude-repl` backend.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Turn-completion can't be detected reliably from the transcript | U0 spike chooses the signal before building; U3 has a hard timeout backstop; worst case, fall back to idle-prompt capture. |
| Mid-turn `send_keys` not accepted by a busy REPL (R3 core premise) | U0 decides inject-vs-interrupt-then-send before U4 commits to an approach. |
| Interactive REPL blocks on tool permissions, stalling autonomous turns | U0/U1 verify the permission posture; carry the headless backend's `permission_mode`; fallback (U6) covers the failure. |
| tmux/RC flakiness strands issues | Headless fallback (U6) + teardown reaper (U7); `aiur_perf` logging for diagnosis. |
| One RC URL per agent leaks if logged | Capability-token discipline: surface to local operator only, never to logs/files (enforced in U1). |
| Scaling: N agents = N live `claude` REPLs + N RC sessions | v1 local-only; rely on existing concurrency limits; note resource cost, revisit if it bites. |
| Rewrite regresses the proven headless path | New backend is additive; headless `claude` untouched and remains the fallback. |
| `r`-key promotion (U9) stops the old agent but re-dispatch fails, stranding the issue with no running agent | Surface re-dispatch failure to the AgentList (U9 error path); resume by cwd so a retry re-attaches the same transcript; the issue stays in an active label state for the orchestrator to pick up. |
| `model:claude-remote` mis-resolves to backend `claude` + variant `remote` | Alias map consulted before longest-prefix backend match; explicit test asserts whole-alias resolution (U8). |

---

## Documentation / Operational Notes

- Update `src/AGENTS.md` / root `AGENTS.md` with the REPL-driver model and how to verify it via the tmux manual-driver recipe.
- `aiur_perf` lifecycle logs (always-on): REPL spawn, RC-activation, first-output, fallback-to-headless, teardown outcome.
- Memory: on completion, update `rc-dual-surface-state` (Q2 integration → done) and `rc-cloud-mediated`.
- Branch/rollback: all work on `kevin/repl-dualchat`; `kevin/remotecontrol` (toggle/handoff) remains the revert target.
- **Dead-code cleanup (end-of-build pass, operator directive 2026-06-08):** after the REPL driver is proven, delete code the rewrite genuinely orphans — but with two hard guards: (1) **codex must still work** — never delete shared infrastructure codex depends on (delivery-policy plumbing, transcript/pubsub, `Aiur.Tmux` helpers, the codex app-server path, registry machinery); (2) the **headless `claude` backend is intentionally retained** as the R6 fallback, so it is NOT "unused" and must not be removed in v1. Scope deletions to what the REPL work alone makes unreachable; if unsure whether codex needs something, keep it and flag it, don't delete. The old RC handoff path (`launch_remote_control` / `do_launch_remote_control` spawning `claude remote-control --spawn`) becomes unreachable once U9 lands and is a prime candidate for this pass — under the same guards.

---

## Phased Delivery

### Phase 1 — De-risk & foundation
- U0 (spike), U1 (lifecycle), U2 (tailer). Ends with a REPL that spawns, activates RC, and emits transcript events.

### Phase 2 — Turn lifecycle & instant delivery
- U3 (run_turn), U4 (instant operator delivery). Ends with a fully drivable agent over the REPL with mid-turn steering.

### Phase 3 — Integration, opt-in config, hardening
- U5 (registry/routing/parity), U6 (two-setting opt-in + fallback), U7 (teardown). Ends with the REPL+RC mode available as an opt-in (RC default OFF), both surfaces at parity when on, zero orphans.

### Phase 4 — Operator-facing controls (redesign 2026-06-08)
- U8 (`model:claude-remote` label alias forces RC per issue), U9 (`r` key promotes a running agent by re-dispatching it as `claude-remote`, retiring the old handoff toggle). Ends with the operator able to force dual-chat on any issue via one label, and to promote any running agent to remote with a keystroke — the global RC default still OFF.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md](docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md) (approach partially superseded — see supersession note)
- **Fallback plan:** docs/plans/2026-06-08-001-feat-rc-dual-surface-handoff-plan.md
- Driver being replaced: `src/lib/aiur/claude/coding_agent.ex`
- Adapter registry: `src/lib/aiur/coding_agent.ex`
- tmux mechanism: `src/lib/aiur/tmux.ex`
- RC spawn + graceful_kill + transcript resolution: `src/lib/aiur/claude/remote_control.ex`
- Transcript extraction: `src/lib/aiur/claude/transcript.ex`
- Operator inbound + delivery policy: `src/lib/aiur/opencode/chat_completions.ex`, `src/lib/aiur/agent_chat.ex`, `src/lib/aiur/agent_pubsub.ex`
- Memory: `rc-dual-surface-state` (Q1-RESOLVED proof), `rc-cloud-mediated` (scope of the old verdict)
