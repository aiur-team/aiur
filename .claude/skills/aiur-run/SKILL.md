---
name: aiur-run
description: "Launch and operate an Aiur run end to end as its Executor: establish authority, preflight and launch, maximize safe parallelism, monitor and recover agents, coordinate PR review/rework, apply merge policy, and handle Aiur defects. Use for 'run aiur', 'run IAR/AYR', 'start the dogfood loop', 'execute this Build Order', or a goal that asks an agent to keep Aiur working until a terminal outcome."
---

# Run Aiur as the Executor

Use this skill when the agent owns the whole Aiur run, not merely its launch.
It replaces the former `aiur-loop` workflow. Read the canonical
[Executor role](references/executor.md) before acting, then use `aiur-monitor`
for status reads and the recurring observation loop.

`iarc`, IAR, and AYR are operator aliases or common spellings for Aiur in this
repository. Treat their run requests as this workflow.

## 1. Establish the run contract

Identify the working repository and read its `AGENTS.md`, `CONTRIBUTING.md`,
Aiur config, and Executor handoff. Record the authority envelope from the
Executor reference: scope, issue creation, review/comment, merge, self-fix,
concurrency, cadence, debug mode, and terminal condition.

Ask only for a material permission that is neither stated nor safely
discoverable. Never infer merge, destructive-change, or external issue-creation
authority.

If a Build Order handoff exists, verify its approved plan version and GitHub
selector. Query GitHub and Aiur for current state; do not trust a hand-written
status table in the planning branch.

## 2. Preflight

From the repository root:

1. confirm auth, config discovery, tracker state slugs, workspace hooks, and the
   base branch required by the repository;
2. run `scripts/aiurdev status` and resolve an existing session deliberately;
3. inspect the scoped queue and native blockers before dispatch;
4. choose a conservative starting cap and the recorded maximum;
5. build with `scripts/aiurdev build` when the local release needs an explicit
   clean checkpoint; ordinary launches already rebuild stale sources.

Do not use `--test` or `--test3` for a real run. Those are destructive sandbox
harnesses. Do not run from nested tmux.

## 3. Launch

Use the repository shim while developing Aiur and the installed `aiur` command
in consumer repositories. Equivalent background forms are:

```bash
scripts/aiurdev run --bg --debug --max-agents <n>
scripts/aiurdev --bg --debug --max-agents <n>
```

Include `--debug` only when authorized. Its incident-reporting consequence is
defined in the Executor reference. Pass `--todo <ids...> [--only]` when the
scope is an explicit ticket set.

Verify `status`, then use a full monitor snapshot to confirm the orchestrator,
queue, alerts, and first dispatch. Background mode is intentionally headless;
observe it through the control commands, not TUI panes.

## 4. Arm monitoring immediately

Use `aiur-monitor` after launch. First run:

```bash
scripts/aiurdev watch --full
scripts/aiurdev alerts --needs-attention
```

Then arm the platform's recurring/monitor mechanism at the recorded cadence.
Claude may use its recurring loop facility; Codex should use its persistent
goal/monitor continuation; a shell operator can use:

```bash
scripts/aiurdev watch --changes --interval <seconds>
```

The timer and alert path are additive: an urgent alert is handled immediately,
while the cadence still provides a quiet-state floor. Do not depend on PR or
agent-completion events as the only wake-up mechanism.

## 5. Drive the run

On every observation:

- act on the `ACTIONABLE` section before routine scheduling;
- keep all dependency-ready, conflict-free lanes occupied;
- ramp with `scripts/aiurdev set max-agents <n>` while the machine and review
  pipeline have headroom, and reduce the cap on resource or quality pressure;
- follow the recovery ladder for stale, looping, or feedback-blind agents;
- treat `ci-wait` as an automatic gate unless evidence shows the poller failed;
- use `scripts/aiurdev message <id> <text>`, `pause`, and `resume` as the least
  invasive controls;
- preserve decisions and incidents in the durable handoff/workpad.

As PRs become ready, run the parallel review/rework loop defined in the
Executor reference. Verify that review comments reach the owning worker through
the event path. Merge only under the recorded policy and protect typed
dependency/conflict ordering.

## 6. Backstop and defects

Prioritize unblocking Aiur workers. Take over a ticket or patch Aiur directly
only when the recovery ladder is exhausted, progress is otherwise impossible,
and self-fix authority exists.

For Aiur crashes, leaked processes, missed comments, dispatch failures, or
broken controls, follow the reference's sanitization and consent policy:

- debug run: file a sanitized Aiur bug automatically;
- non-debug run: prepare the sanitized draft and ask before filing.

Always remove secrets and privacy-sensitive context, regardless of debug mode.

## 7. Rebuild, resume, and stop

Use deliberate rebuild checkpoints after merges that must enter the worker
base. Stop the current session cleanly, update the base under the repository's
branch policy, rebuild, and resume only the remaining live GitHub scope.

Before context exhaustion, update the durable handoff and create a three-to-five
sentence goal describing the Executor role, authority, Build Order selector,
terminal condition, and immediate next actions. A replacement Executor starts
by querying live GitHub/Aiur state.

At the true terminal condition—or on an explicit human stop—run:

```bash
scripts/aiurdev stop
```

Confirm the control plane and background processes are gone. A leak is an Aiur
bug and follows the same reporting policy.
