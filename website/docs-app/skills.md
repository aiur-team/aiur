---
title: Skills
---

# Skills

Aiur ships Agent Skills under `.claude/skills/` and makes them available to Codex under `.codex/skills/`. They split into two families by **where they run**:

- **Agent-workspace skills** are copied into every ticket workspace, so the agent working a ticket can load them on any repository.
- **Executor skills** stay in this repository and load in the Executor's own session, whether that Executor is a human or an agent driving Aiur.

## Agent-workspace skills

These four skills, together with the complete pinned Compound Engineering set, are available in every ticket workspace under both `<workspace>/.claude/skills/` and `<workspace>/.codex/skills/`, so a Claude workspace and a Codex workspace get the same set without a machine-local plugin cache.

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

Aiur vendors the complete Compound Engineering **3.19.0** skill tree under [`.claude/skills/`](../../.claude/skills/), so every dispatched workspace receives the same pinned set.

| Skill | Purpose |
| --- | --- |
| `ce-brainstorm` | Clarify requirements and alternatives. |
| `ce-plan` | Produce an implementation-ready plan. |
| `ce-work` | Execute a concrete plan or request. |
| `ce-code-review` | Review bugs, regressions, tests, and standards. |
| `ce-doc-review` | Review documentation structure and accuracy. |
| `ce-debug` | Diagnose failing behavior. |

The complexity router invokes those skills directly, and they conditionally invoke sibling CE skills; the complete tree keeps those branches reproducible.

| Pin record | Location |
| --- | --- |
| Version | [`compound-engineering.version`](../../.claude/skills/compound-engineering.version) |
| Managed skill names | [`compound-engineering.skills`](../../.claude/skills/compound-engineering.skills) |
| Upstream MIT license | [`compound-engineering.LICENSE`](../../.claude/skills/compound-engineering.LICENSE) |

To update the vendored copy, clone the exact upstream release tag and run the guarded refresh script:

```bash
update_dir=$(mktemp -d)
git clone https://github.com/EveryInc/compound-engineering-plugin.git "$update_dir/compound-engineering"
git -C "$update_dir/compound-engineering" checkout <exact-release-ref>
scripts/update-compound-engineering-skills X.Y.Z "$update_dir/compound-engineering"
```

Choose the release ref whose `.claude-plugin/plugin.json` reports `X.Y.Z`; the refresh script rejects a mismatch.

Review the upstream release notes and the resulting skill diff, then run the AgentSkills tests before committing. The script replaces only previously managed CE skill paths, refreshes the license, version, and manifest files, and recreates the Claude-to-Codex links.
