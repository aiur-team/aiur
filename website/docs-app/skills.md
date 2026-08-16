---
title: Skills
---

# Skills

Aiur skills are grouped by where they run.

## Agent-workspace skills

These four skills are installed into every ticket workspace for both Claude and Codex agents.

| Skill | Loaded when | Covers |
| --- | --- | --- |
| [using-aiur](../../.claude/skills/using-aiur/SKILL.md) | Every ticket turn | Agent labels, phases, Workpad, alerts, complexity, development, and PR handoff. |
| [aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) | Before event or blocker work | [Message Bus](/concepts/message-bus), subscriptions, dependencies, and attentions. |
| [aiur-debug](../../.claude/skills/aiur-debug/SKILL.md) | Run, daemon, agent, or workspace failure | Correlated evidence and safe recovery order. |
| [design-import](../../.claude/skills/design-import/SKILL.md) | Large frontend design import | Disk-first import without overflowing agent context. |

## Executor skills

These stay with the Executor and are not copied into ticket workspaces.

| Skill | Trigger | Covers |
| --- | --- | --- |
| [aiur-intro](../../.claude/skills/aiur-intro/SKILL.md) | First contact or installation | Operating modes, setup, and first run. |
| [aiur-build](../../.claude/skills/aiur-build/SKILL.md) | Plan a large feature | Requirements, ticket contracts, dependency graph, and Build Order handoff. |
| [aiur-run](../../.claude/skills/aiur-run/SKILL.md) | Operate a run | Accepted boundary through review and merge. |
| [aiur-monitor](../../.claude/skills/aiur-monitor/SKILL.md) | Inspect a live run | Status board and alert feed. |
| [aiur-meta](../../.claude/skills/aiur-meta/SKILL.md) | Hourly audit | Operator surfaces, bottleneck, and durable findings. |
| [aiur-handoff](../../.claude/skills/aiur-handoff/SKILL.md) | Executor handoff | Boot document for the next Executor. |
| [release](../../.claude/skills/release/SKILL.md) | Release | Version, tag, and GitHub release. |

`aiur-handoff`, `aiur-meta`, and `release` are Claude-only.

## Codex-native git workflow

| Skill | Covers |
| --- | --- |
| [commit](../../.codex/skills/commit/SKILL.md) | Scope-aware commit creation. |
| [push](../../.codex/skills/push/SKILL.md) | Push and PR creation or update. |
| [pull](../../.codex/skills/pull/SKILL.md) | Merge-based integration from `origin/main`. |
| [land](../../.codex/skills/land/SKILL.md) | Conflict, CI, review, and squash-merge handling. |
| [debug](../../.codex/skills/debug/SKILL.md) | Log-tracing recovery. |
| [linear](../../.codex/skills/linear/SKILL.md) | Raw Linear GraphQL operations. |

## Compound Engineering

| Skill | Purpose |
| --- | --- |
| `ce-brainstorm` | Clarify requirements and alternatives. |
| `ce-plan` | Produce an implementation-ready plan. |
| `ce-work` | Execute a concrete plan or request. |
| `ce-code-review` | Review bugs, regressions, tests, and standards. |
| `ce-doc-review` | Review documentation structure and accuracy. |
