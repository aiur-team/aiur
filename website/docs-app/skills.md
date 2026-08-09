---
title: Skills
---

Aiur has two skill families: driver skills under `.claude/skills/`, and skills present in agent workspaces. The latter include Codex-native git-workflow skills under `.codex/skills/` plus the compound-engineering skills invoked by the complexity router.

## Driver skills

[using-aiur](../../.claude/skills/using-aiur/SKILL.md) is the per-ticket operating manual for the agent:* label lifecycle, brainstorm→plan→work→review flow, Agent Workpad, and development loop. It is loaded every ticket turn via the shared per-turn prompt pointer.

[aiur-agent](../../.claude/skills/aiur-agent/SKILL.md) routes cross-ticket events, including `emit_event`, subscriptions, blockers, and attention open/close. An agent loads it before emitting or subscribing to events.

[aiur-build](../../.claude/skills/aiur-build/SKILL.md) researches and decomposes a feature into requirements, ticket contracts, a validated graph, and an Executor handoff. It stops before implementation or an Aiur run.

[aiur-run](../../.claude/skills/aiur-run/SKILL.md) is the Executor playbook for launching and operating a bounded Aiur run through its accepted outcome. It triggers on “run aiur”, “run IAR”, “iarc run”, or the legacy phrase “run the aiur loop”.

[aiur-monitor](../../.claude/skills/aiur-monitor/SKILL.md) compiles a one-glance status board from `aiurdev watch`. It triggers on “aiur status” or “iarc status”.

[release](../../.claude/skills/release/SKILL.md) is the Executor playbook for cutting a new npm release by bumping `src/mix.exs`, tagging, and creating a GitHub release. It triggers on `/release` or “release a new version”.

## Skills in agent workspaces

After a workspace is populated, `Aiur.AgentSkills.install/1` ([`agent_skills.ex`](../../src/lib/aiur/agent_skills.ex)) writes **using-aiur**, **aiur-agent**, and **design-import** into `<workspace>/.claude/skills/` and mirrors them into `<workspace>/.codex/skills/` via relative symlinks, so agents on any repository can load them; see the [Driver skills](#driver-skills) section.

### Codex-native git-workflow skills

[commit](../../.codex/skills/commit/SKILL.md) provides the Codex-native conventional-commit flow: read session intent, confirm scope before staging, use a `type(scope)` subject, and avoid model-attribution trailers. It triggers when a commit is requested.

[push](../../.codex/skills/push/SKILL.md) safely pushes changes and creates or updates a pull request against the PR template. It triggers when publishing changes is requested and distinguishes sync failures, which go to pull, from authentication failures.

[pull](../../.codex/skills/pull/SKILL.md) updates a branch with a merge rather than a rebase, using rerere and a clear conflict-resolution doctrine. It triggers when a branch needs to be synchronized with `origin/main`.

[land](../../.codex/skills/land/SKILL.md) handles end-to-end PR landing: staying conflict-free, keeping CI green, answering review personas, and squash-merging. It triggers when landing or merging a pull request is requested.

[debug](../../.codex/skills/debug/SKILL.md) is a log-tracing runbook for stuck or failing runs using issue and session correlation keys. It triggers when a run stalls, retries, or fails unexpectedly.

[linear](../../.codex/skills/linear/SKILL.md) explains how to use the `linear_graphql` app-server tool. It triggers when raw Linear GraphQL operations are needed.

### Compound-engineering skills

These are Executor-provided CE skills invoked by the complexity router; they are not bundled into workspaces by Aiur. The routing rules are in [complexity-routing.md](../../.claude/skills/using-aiur/complexity-routing.md), which references **ce-work**, **ce-code-review**, **ce-plan**, **ce-brainstorm**, and **ce-doc-review**. These skills ship with the Executor’s environment, so this page does not link to per-skill files in this repository.
