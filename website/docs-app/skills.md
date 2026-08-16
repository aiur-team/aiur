---
title: Skills
---

# Skills

Aiur ships Agent Skills in this repository under `.claude/skills/`, mirrored to `.codex/skills/` by relative symlink. They split into two families by **where they run**, not by where they are stored:

- **Agent-workspace skills** are copied into every ticket workspace, so the agent working a ticket can load them on any repository.
- **Executor skills** stay in this repository and load in the Executor's own session, whether that Executor is a human or an agent driving Aiur.

The split is defined in code, not by convention. `@issue_worker_skills` in [`agent_skills.ex`](../../src/lib/aiur/agent_skills.ex) combines Aiur's worker skills with the pinned Compound Engineering manifest, and [`aiur_agent_skill_test.exs`](../../src/test/aiur/aiur_agent_skill_test.exs) cross-checks both sets so they cannot drift.

## Agent-workspace skills

After a workspace is populated, `Aiur.AgentSkills.install/1` writes these four Aiur skills and the complete pinned Compound Engineering set into `<workspace>/.claude/skills/`, then mirrors them into `<workspace>/.codex/skills/` via relative symlinks. Destination paths come from `CodingAgent.skill_install_locations/0`, so a Claude workspace and a Codex workspace get the same set without depending on a machine-local plugin cache.

| Skill | Loaded when | What it covers |
| --- | --- | --- |
| [using-aiur](../../.claude/skills/using-aiur/SKILL.md) | Every ticket turn, via the shared per-turn prompt pointer. | The `agent:*` label lifecycle, the brainstorm, plan, work, and review flow, the Agent Workpad, milestone alerts, complexity routing, and the development loop. |
| [aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) | Before emitting, subscribing to, or reacting to any event. | The [Message Bus](/concepts/coordination): `emit_event`, `aiur_subscribe`, blocker declaration, and attention open and close. |
| [aiur-debug](../../.claude/skills/aiur-debug/SKILL.md) | When a run, daemon, agent, or workspace misbehaves. | An Aiur-specific context overlay for correlating evidence and ordering safe recovery. |
| [design-import](../../.claude/skills/design-import/SKILL.md) | Before frontend work that involves a design artifact. | Importing large design payloads without overflowing inline tool-result limits. |

Executor skills are deliberately excluded from this set: an issue worker has no reason to run Aiur itself.

## Executor skills

These load in the Executor's session and are never bundled into a workspace.

| Skill | Triggers on | What it does |
| --- | --- | --- |
| [aiur-intro](../../.claude/skills/aiur-intro/SKILL.md) | "what is aiur", "how do I install aiur". | First-contact evaluation, the two operating modes, install, and first run. |
| [aiur-build](../../.claude/skills/aiur-build/SKILL.md) | "break this feature into Aiur tickets", "plan the Build Order". | Research and decomposition into requirements, ticket contracts, a validated graph, and an Executor handoff. It stops before implementation. |
| [aiur-run](../../.claude/skills/aiur-run/SKILL.md) | "run aiur", "run IAR", "iarc run", "run the aiur loop". | The Executor playbook for launching and operating a bounded run through its accepted outcome. |
| [aiur-monitor](../../.claude/skills/aiur-monitor/SKILL.md) | "aiur status", "iarc status". | A one-glance status board compiled from `aiur watch` and the alert feed. |
| [aiur-meta](../../.claude/skills/aiur-meta/SKILL.md) | The recurring hourly timer that `aiur-run` arms, or "meta check". | One audit across every operator-facing surface, naming the current bottleneck and filing it durably. |
| [aiur-handoff](../../.claude/skills/aiur-handoff/SKILL.md) | An Executor handoff, or before context exhaustion. | Writes the handoff document the next Executor reads on boot. |
| [release](../../.claude/skills/release/SKILL.md) | `/release`, "release a new version". | Bumps `src/mix.exs`, tags, and creates the GitHub release. |

`aiur-handoff`, `aiur-meta`, and `release` are Claude-only and are not symlinked into `.codex/skills/`.

## Codex-native git-workflow skills

These live only under `.codex/skills/` and are not installed by Aiur. They are the Codex-native equivalents of the git workflow.

| Skill | Triggers on | What it does |
| --- | --- | --- |
| [commit](../../.codex/skills/commit/SKILL.md) | A commit is requested. | Reads session intent, confirms scope before staging, uses a `type(scope)` subject, and avoids model-attribution trailers. |
| [push](../../.codex/skills/push/SKILL.md) | Publishing changes is requested. | Pushes and creates or updates a PR against the template. It distinguishes sync failures, which go to `pull`, from authentication failures. |
| [pull](../../.codex/skills/pull/SKILL.md) | A branch needs synchronizing with `origin/main`. | Updates with a merge rather than a rebase, using rerere and a clear conflict-resolution doctrine. |
| [land](../../.codex/skills/land/SKILL.md) | Landing or merging a PR is requested. | Stays conflict-free, keeps CI green, answers review personas, and squash-merges. |
| [debug](../../.codex/skills/debug/SKILL.md) | A run stalls, retries, or fails unexpectedly. | A log-tracing runbook using issue and session correlation keys. |
| [linear](../../.codex/skills/linear/SKILL.md) | Raw Linear GraphQL operations are needed. | How to use the `linear_graphql` app-server tool. |

## Compound-engineering skills

Aiur vendors the complete Compound Engineering **3.19.0** skill tree under [`.claude/skills/`](../../.claude/skills/). The exact version and managed skill names live in [`compound-engineering.version`](../../.claude/skills/compound-engineering.version) and [`compound-engineering.skills`](../../.claude/skills/compound-engineering.skills); the upstream MIT license is retained verbatim in [`compound-engineering.LICENSE`](../../.claude/skills/compound-engineering.LICENSE).

The full set is intentional. Aiur directly routes work through **ce-work**, **ce-code-review**, **ce-plan**, **ce-brainstorm**, **ce-doc-review**, and **ce-debug**, while those workflows conditionally invoke sibling CE skills. Shipping the complete tree keeps those branches reproducible and prevents a second silent missing-skill dependency. Every dispatched workspace receives the same pinned set, including remote workspaces.

To update the vendored copy, clone the exact upstream release tag and run the guarded refresh script:

```bash
update_dir=$(mktemp -d)
git clone https://github.com/EveryInc/compound-engineering-plugin.git "$update_dir/compound-engineering"
git -C "$update_dir/compound-engineering" checkout <exact-release-ref>
scripts/update-compound-engineering-skills X.Y.Z "$update_dir/compound-engineering"
```

Choose the release ref whose `.claude-plugin/plugin.json` reports `X.Y.Z`; the refresh script rejects a mismatch. Review the upstream release notes and the resulting skill diff, then run the AgentSkills tests before committing. The script replaces only previously managed CE skill paths, refreshes the license/version/manifest files, and recreates the Claude-to-Codex links.
