---
title: "fix: Inject Aiur dynamic tools in Claude sessions"
type: fix
date: 2026-06-24
---

# fix: Inject Aiur dynamic tools in Claude sessions

## Summary

Hand-launched Claude ticket sessions receive the same shared agent prompt as Codex sessions, but the Claude app-server backend does not advertise or execute Aiur dynamic tools. This plan brings Claude to parity with Codex for the existing `emit_alert`, `emit_event`, `aiur_subscribe`, `aiur_unsubscribe`, `aiur_declare_blocker`, and `aiur_unblock` primitives.

---

## Problem Frame

Issue #515 reports that a Claude Code agent on a ticket cannot call the pause, attention, progress, or blocker primitives documented in the shared prompt and `/aiur-agent` skill. The tool implementations already exist in `Aiur.Codex.DynamicTool`; the gap is the Claude app-server launch path, whose module documentation and `thread/start` frame omit DynamicTool integration.

---

## Requirements

- R1. Claude `thread/start` must advertise `DynamicTool.tool_specs()` so ToolSearch can discover the Aiur primitives in hand-launched ticket sessions.
- R2. Claude `item/tool/call` notifications must execute through the same injected `tool_executor` used by Codex-backed agent turns.
- R3. Tool-call success, failure, and unsupported-tool events must be surfaced through the existing `on_message` callback shape for status/log consumers.
- R4. The change must not alter Codex behavior or invent new tool contracts.

---

## Key Technical Decisions

- **Reuse `Aiur.Codex.DynamicTool` as the canonical tool registry:** The existing module is already backend-neutral enough for these Aiur-owned tools and is the single source of truth for specs and execution.
- **Mirror Codex's app-server bridge at the Claude boundary:** Claude should pass `dynamicTools` during `thread/start`, normalize tool results, send the app-server response by request id, and emit `:tool_call_completed` / `:tool_call_failed` / `:unsupported_tool_call`.
- **Keep approvals unchanged:** This issue is only about Aiur-owned dynamic tools, not Claude command approval behavior or broader permission mode changes.

---

## Implementation Units

### U1. Advertise dynamic tools to Claude app-server

- **Goal:** Include `dynamicTools: DynamicTool.tool_specs()` in the Claude `thread/start` params.
- **Requirements:** R1, R4
- **Files:** Modify `src/lib/aiur/claude/coding_agent.ex`; test `src/test/aiur/claude/coding_agent_test.exs`.
- **Approach:** Alias `Aiur.Codex.DynamicTool`, update the module docs, and extend the existing fake app-server test to assert the expected tool names are present.
- **Test scenarios:** A Claude session start records a `thread/start` frame whose params include every DynamicTool name; configured model behavior still works.
- **Verification:** Focused Claude coding-agent tests pass.

### U2. Execute Claude dynamic tool calls

- **Goal:** Handle `item/tool/call` notifications in the Claude receive loop using the `tool_executor` option passed by `AgentRunner`.
- **Requirements:** R2, R3, R4
- **Files:** Modify `src/lib/aiur/claude/coding_agent.ex`; test `src/test/aiur/claude/coding_agent_test.exs`.
- **Approach:** Store `tool_executor` in turn state, add an `item/tool/call` branch before generic notification handling, support both `"tool"` and `"name"` params, normalize `contentItems` output like Codex, send the result response to the app-server, and emit the same message events.
- **Test scenarios:** A fake Claude app-server calls `emit_event`; the injected executor receives the tool and arguments; the response frame contains the normalized output; failure and nil tool names classify as failed or unsupported.
- **Verification:** Focused Claude coding-agent tests pass without changing Codex tests.

---

## Scope Boundaries

- No new event vocabulary, alert routing, subscription behavior, or GitHub dependency API work.
- No changes to shared prompt text, because the prompt already documents the tools.
- No manual `scripts/aiurdev --test` run from this agent workspace; if the guard blocks it, record the blocker and rely on focused module tests.

---

## Risks & Dependencies

- Claude app-server compatibility depends on it accepting the same `dynamicTools` thread-start field as Codex. The issue evidence and app-server protocol naming indicate that is the intended contract; the test locks Aiur's side of the wire.
- If the Claude adapter emits a different tool-call notification shape, support both observed Codex shapes (`params.tool` and `params.name`) and keep the branch easy to extend.
