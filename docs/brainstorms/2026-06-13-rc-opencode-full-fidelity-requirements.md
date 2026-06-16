# RC-claude opencode pane: full-conversation fidelity

**Date:** 2026-06-13
**Scope:** Standard (feature) — bounded rewiring of the RC-claude display path
**Status:** requirements captured → ready for `/ce-plan`

## Problem

For an RC-claude agent (`claude --remote-control` in a tmux pane), the opencode chat pane and the Claude remote-control (RC) channel show **different-looking logs** of the **same** agent. The opencode pane is reconstructed from only three hook signals — `UserPromptSubmit` (prompt), `PostToolUse` (a bare `→ ToolName` row, no I/O), `Stop` (final assistant message) — so it is a sparse skeleton. The RC channel shows claude's full native transcript: thinking, every tool's input **and** output, and the intermediate assistant text between tools. Operators read this as "two different agents." It is one agent; only the display fidelity diverges.

This is pinned task #27, axis 2. It is **not** a regression from the prompt-submit fix (`d98dd4f`).

## Goal

The opencode pane and the RC channel are **two views of one conversation**. Opening the opencode pane shows the same messages, in the same order, that the operator sees in the RC view.

## Decision (chosen approach: B — transcript tailer for display)

Drive the opencode display for RC-claude from the **claude transcript jsonl** (the same store claude itself reads on resume), reusing the existing `src/lib/aiur/claude/transcript.ex` (record → role mapping, incl. `thinking → :reasoning`) and `src/lib/aiur/claude/transcript_tailer.ex`. The opencode renderer already supports the needed roles (`:reasoning`, `:tool` with I/O, `:assistant`, `:user`) in `src/lib/aiur/opencode/chat_completions.ex` and `src/lib/aiur/opencode/session_writer.ex` — **no new rendering work**.

**Responsibility split (the core architectural decision):**
- **Hooks = turn detection / control** — `UserPromptSubmit`/`PostToolUse`/`Stop` keep driving turn completion + heartbeat (the reliable path from the recent fix). Unchanged.
- **Transcript tailer = display** — the tailer becomes the single source of opencode transcript events (thinking, assistant text, tool input/output, user), following the current session's `transcript_path` (carried in every hook event).

**Alternatives considered:**
- **A — enrich hooks** (tool I/O + messages from hook payloads): low cost, high robustness, but structurally can't carry thinking, intermediate narration, or history (Stop only carries the *last* message), so it would still read as a different, thinner log. Rejected: doesn't meet the "same convo" goal.
- **C — phased (A then B):** rejected; B's real cost is moderate (reuses existing tailer/parser) and phasing mostly adds rework + double-render dedup.

## Requirements

1. **Full parity content.** Opencode shows: user prompts, claude thinking/reasoning blocks (`:reasoning`), intermediate assistant text (`:assistant`), tool calls with their inputs **and** outputs (`:tool`), in transcript order.
2. **Backfill on attach.** Opening the opencode pane mid-conversation replays the full prior conversation from the session's jsonl (scroll back the whole convo), not just events after attach.
3. **Single display source (no double-render).** Remove the sparse hook display emissions (`maybe_emit_tool_progress` `→ Tool` at `repl_agent.ex:593`; `finish_hook_turn` final-message at `:602`) so the tailer is the only thing painting the convo. Hooks keep their **control** role.
4. **Read-only.** The tailer only displays; it never re-sends or re-prompts the agent (honor `feedback_repl_backfill_display_only`).
5. **Display-only failure isolation.** Any jsonl read/parse/flush problem (lazy flush lag, partial line mid-write, unknown/changed record block, missing file) degrades gracefully to a thinner/empty view and **must never** affect turn detection, the agent run, or crash anything. Lag is acceptable; the view catches up.
6. **Session-rotation aware.** The claude `session_id` can rotate mid-run (observed `d01d5f9e` → `955a9c15`); the tailer must follow the current session's `transcript_path` and not strand on a stale jsonl.
7. **Large-content handling.** Very large tool outputs / thinking blocks are capped/truncated to keep the pane readable (match the spirit of RC's own collapsing). Exact thresholds: planning.

## Scope boundaries

**In:** RC-claude agents (the reported bug).
**Out (separate, #27 axis 1):** real-time operator-message consumption for codex + non-RC claude; the opencode bridge double-dispatch. Codex already streams its own rich transcript; not touched here.

## Success criteria

- In a live `--test3` run, the opencode pane for issue 101 and the RC channel show the same messages (thinking, tool I/O, assistant text) in the same order for a turn.
- Opening 101's pane mid-conversation shows the full prior conversation (backfill).
- A simulated jsonl problem (truncated/garbage line, missing file) thins/empties the pane but leaves turn detection and the agent run unaffected (no crash, no `:repl_gone`).
- compile / test / credo / dialyzer green.

## Dependencies / assumptions

- **Assumption (verified):** by the time `PostToolUse`/`Stop` fire, claude has flushed the relevant records to `transcript_path` (jsonl files exist with full user/assistant/thinking/tool content). The lazy-flush window only hurt timing-critical turn *detection*, not lag-tolerant display.
- **Reuses:** `Aiur.Claude.Transcript`, `Aiur.Claude.TranscriptTailer`, `Aiur.Claude.HookEvents` (for `transcript_path` + session_id), opencode `chat_completions.ex` / `session_writer.ex` rendering.
- **Related memory:** `project_rc_opencode_sparse_mirror`, `project_bug1_no_transcript_root`, `feedback_repl_backfill_display_only`, `project_rc_prompt_submit_paste_race`.
