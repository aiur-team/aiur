---
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# opencode Pane Brainstorm

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md

## Goal

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#goal)

## Current Aiur Pane Responsibilities

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#current-aiur-pane-responsibilities)

## opencode Foundational Architecture

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#opencode-foundational-architecture)

### Process model

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#process-model)

### Server endpoints worth pinning down

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#server-endpoints-worth-pinning-down)

### Port and discovery

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#port-and-discovery)

### Storage

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#storage)

### Message and part model

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#message-and-part-model)

### Bus and SSE events

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#bus-and-sse-events)

### Configuration stack

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#configuration-stack)

### Permissions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#permissions)

### Agent concept (important — don't confuse "opencode agent" with "Aiur agent")

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#agent-concept-important--dont-confuse-opencode-agent-with-aiur-agent)

### Plugins, MCP, and custom tools — when to use which

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#plugins-mcp-and-custom-tools--when-to-use-which)

### Things that are still open / unverified

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#things-that-are-still-open--unverified)

## Working Thesis (revised after 2026-05-19 clarification)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#working-thesis-revised-after-2026-05-19-clarification)

## Integration Mechanism Choices

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#integration-mechanism-choices)

### A. Aiur is opencode's "provider" (LLM relay)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#a-aiur-is-opencodes-provider-llm-relay)

### B. Plugin neutralizes opencode's model, Aiur drives via HTTP

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#b-plugin-neutralizes-opencodes-model-aiur-drives-via-http)

### C. opencode as dumb display; Aiur drives everything via server API

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#c-opencode-as-dumb-display-aiur-drives-everything-via-server-api)

### D. A + decorative plugin (recommended hybrid if A's shim is acceptable)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#d-a--decorative-plugin-recommended-hybrid-if-as-shim-is-acceptable)

## Concrete Integration Sketch (mechanism-agnostic)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#concrete-integration-sketch-mechanism-agnostic)

### Per-workspace bootstrap

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#per-workspace-bootstrap)

### Per-issue session — created at agent start, not at pane open

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#per-issue-session--created-at-agent-start-not-at-pane-open)

### When operator opens the pane

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#when-operator-opens-the-pane)

### When operator submits a message

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#when-operator-submits-a-message)

### When the Aiur agent produces output while the operator is watching

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#when-the-aiur-agent-produces-output-while-the-operator-is-watching)

### When Aiur needs to alert the operator

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#when-aiur-needs-to-alert-the-operator)

### When the operator closes the pane

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#when-the-operator-closes-the-pane)

## Open Foundational Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#open-foundational-questions)

## Feature and Scope Questions (still open)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#feature-and-scope-questions-still-open)

## Decisions (in order resolved)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#decisions-in-order-resolved)

### 2026-05-19: Single agent, opencode is a chat-UI swap only

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-single-agent-opencode-is-a-chat-ui-swap-only)

### 2026-05-19: Server lifetime — lazy spawn, kill on close

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-server-lifetime--lazy-spawn-kill-on-close)

### 2026-05-19: Mechanism D — Aiur-as-provider + decorative plugin

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-mechanism-d--aiur-as-provider--decorative-plugin)

### 2026-05-19: Backfill is event-by-event from `logs/agent.ndjson`

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-backfill-is-event-by-event-from-logsagentndjson)

### 2026-05-19: Alerts surface both ways

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-alerts-surface-both-ways)

### 2026-05-19: Pane open for queued (not-yet-running) issue auto-starts on first submit

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/opencode-pane-brainstorm.md#2026-05-19-pane-open-for-queued-not-yet-running-issue-auto-starts-on-first-submit)

