---
title: Skills
---

# Skills

Aiur skills are grouped by where they run.

`@issue_worker_skills` in [`agent_skills.ex`](../../src/lib/aiur/agent_skills.ex) combines Aiur's worker skills with the pinned Compound Engineering manifest, and [`aiur_agent_skill_test.exs`](../../src/test/aiur/aiur_agent_skill_test.exs) cross-checks both sets so they cannot drift.

## Agent-workspace skills

These three Aiur skills and the complete pinned Compound Engineering set are installed into every ticket workspace, for both Claude and Codex agents.

`Aiur.AgentSkills.install/1` writes them into `<workspace>/.claude/skills/` and mirrors them into `<workspace>/.codex/skills/` by relative symlink, so neither backend depends on a machine-local plugin cache.

| Skill | Loaded when | Covers |
| --- | --- | --- |
| [aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) | Every ticket turn | Agent labels, phases, Workpad, alerts, complexity, development, PR handoff, and [Message Bus](/concepts/message-bus) events. |
| [aiur-debug](../../.claude/skills/aiur-debug/SKILL.md) | Run, daemon, agent, or workspace failure | Correlated evidence and safe recovery order. |
| [design-import](../../.claude/skills/design-import/SKILL.md) | Large frontend design import | Disk-first import without overflowing agent context. |

Executor skills are excluded: an issue worker has no reason to run Aiur itself.

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

The complexity routing rules that pick which CE skill to run live in [complexity-routing.md](../../.claude/skills/aiur-agent/complexity-routing.md).
