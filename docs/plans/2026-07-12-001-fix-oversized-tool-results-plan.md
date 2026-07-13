---
title: Spill Oversized Tool Results
type: fix
status: completed
date: 2026-07-12
---

# Spill Oversized Tool Results

## Summary

Keep large MCP/dynamic-tool payloads out of the Codex inline result channel by writing successful outputs over 100 KiB into the active issue workspace and returning a short path-bearing result. Add design-import guidance to Aiur's agent prompt so authenticated Claude sessions fetch large design artifacts directly to disk when that route is available.

## Requirements

- R1. Successful dynamic-tool output over 100 KiB is saved below the active issue workspace, with a concise response that tells the agent where and how to read it.
- R2. Small results and existing failure results retain their current response shape.
- R3. Codex and Claude app-server backends use the same spill behavior.
- R4. A repository design-import skill and Aiur's prompt enforce the authenticated Claude-to-disk design import path.

## Scope Boundaries

- General looping/stall detection remains owned by #1024; this fix removes the known oversized-result trigger rather than adding a second watchdog.
- The external compound-engineering frontend-design skill is not vendored by this repository; a focused repository design-import skill composes with it.

## Key Technical Decisions

- Spill after the tool executor builds its standard response but before the JSON-RPC reply is sent, preserving all tool implementations and covering every MCP/dynamic tool uniformly.
- Store the complete normalized output below `.aiur/tool-results/` in the issue workspace. Return an absolute path because the agent may read it from any current subdirectory.
- If persistence fails, return a short failed result instead of falling back to the oversized inline payload, preventing the original overflow loop.

## Implementation Units

### U1. Shared spill contract

**Goal:** Normalize and spill oversized successful tool results safely.

**Requirements:** R1, R2

**Files:**
- Modify: `src/lib/aiur/app_server/messages.ex`
- Test: `src/test/aiur/app_server/messages_test.exs`

**Test scenarios:**
- Happy path: a successful output above 100 KiB writes the exact content to disk and returns a short path-bearing envelope.
- Edge case: output at or below the limit remains inline.
- Error path: an unwritable spill destination produces a bounded failed response without echoing the large payload.
- Edge case: failed tool results remain unchanged.

### U2. Backend wiring

**Goal:** Supply the active workspace to shared normalization in both app-server adapters.

**Requirements:** R3

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/codex/turn_loop.ex`
- Modify: `src/lib/aiur/codex/approvals.ex`
- Modify: `src/lib/aiur/claude/coding_agent.ex`
- Test: `src/test/aiur/codex/turn_loop_test.exs`

**Test scenarios:**
- Integration: a Codex dynamic-tool call receives the workspace-aware bounded result.
- Integration: Claude uses the same normalizer with its session workspace.

### U3. Design import guidance

**Goal:** Make the known authenticated Claude-to-disk recovery path part of every Aiur ticket prompt.

**Requirements:** R4

**Dependencies:** None

**Files:**
- Create: `.claude/skills/design-import/SKILL.md`
- Modify: `.aiur/prompt.md`

**Test expectation:** none -- prompt-only operational guidance is reviewed directly.

## Verification

- Compile with warnings as errors.
- Format the changed Elixir files.
- Run app-server message and directly affected adapter tests with at most four concurrent cases.
