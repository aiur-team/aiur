---
name: aiur-run
description: "Launch and operate an Aiur run end to end as its Executor: establish authority, protect a finite acceptance boundary, launch and monitor, maximize safe critical-path parallelism, recover agents, coordinate PR review/rework, apply merge policy, and handle Aiur defects. Use for 'run aiur', 'run IAR/AYR', 'iarc run', 'run the aiur loop', '/aiur-loop', 'improve this repo with aiur', 'execute this Build Order', or a persistent Aiur goal."
---

# Run Aiur as the Executor

Use this skill when the agent owns the whole Aiur run, not merely its launch.
It replaces the former `aiur-loop` workflow. Read the canonical
[Executor role](references/executor.md) before acting, then use `aiur-monitor`
for status reads and the recurring observation loop.

`iarc` is an Executor alias for `aiur`; IAR and AYR are common spellings. Treat
their run requests as this workflow.

## 1. Establish the run contract

Identify the working repository and read its `AGENTS.md`, `CONTRIBUTING.md`,
Aiur config, and Executor handoff. Record the authority envelope from the
Executor reference: scope, issue creation/comment, review, merge, self-fix,
concurrency, cadence, debug mode, and terminal condition. Record external issue
mutation authority separately from debug mode; one never implies the other.

The handoff must identify the finite feature boundary, critical path, required
documentation/cleanup, required end-to-end proof, and deferred-findings ledger.
If those are absent, establish them before launch.

Ask only for a material permission that is neither stated nor safely
discoverable. Never infer merge, destructive-change, or external issue-creation
authority.

If a Build Order handoff exists, verify its approved plan version and GitHub
selector. Query GitHub and Aiur for current state; do not trust a hand-written
status table in the planning branch.

## 2. Preflight

Set `AIUR_CMD=scripts/aiurdev` in an Aiur development checkout and
`AIUR_CMD=aiur` in a consumer repository. Use that command boundary throughout;
consumer repositories do not contain the development shim.

From the repository root:

1. confirm auth, config discovery, tracker state slugs, workspace hooks, and the
   base branch required by the repository;
2. run `"$AIUR_CMD" status` and resolve an existing session deliberately;
3. inspect the scoped queue and native blockers before dispatch; if explicit
   IDs are in scope, queue them separately before launch:

   ```bash
   "$AIUR_CMD" --todo <ids...> [--only]
   ```

   `--only` dequeues all other pending tickets and therefore requires explicit
   scope authority;
4. choose a conservative starting cap and the recorded maximum;
5. when `AIUR_CMD=scripts/aiurdev`, use `"$AIUR_CMD" build` if the local release
   needs an explicit clean checkpoint; ordinary local launches rebuild stale
   sources, and installed `aiur` has no shim-only `build` command.

Do not use `--test` or `--test3` for a real run. Those are destructive sandbox
harnesses. Do not run from nested tmux.

## 3. Launch

Use the repository shim while developing Aiur and the installed `aiur` command
in consumer repositories. Equivalent background forms are:

```bash
"$AIUR_CMD" run --bg --debug --max-agents <n>
"$AIUR_CMD" --bg --debug --max-agents <n>
```

Include `--debug` only when authorized. It controls evidence capture and never
authorizes filing or commenting on an issue; those mutations require separately
recorded authority. Do not combine the separate `--todo` command with launch
options.

Verify `status`, then use a full monitor snapshot to confirm the orchestrator,
queue, alerts, and first dispatch. Background mode is intentionally headless;
observe it through the control commands, not TUI panes.

Before increasing the session ceiling, verify the configured repo prewarm is
ready or intentionally disabled. A prewarm error can fall back to cold workspace
builds; reduce concurrency before that fan-out.

## 4. Arm monitoring immediately

Use `aiur-monitor` after launch. First run:

```bash
"$AIUR_CMD" watch --full
"$AIUR_CMD" alerts --needs-attention
```

Then arm the platform's recurring/monitor mechanism at the recorded cadence.
Claude may use its recurring loop facility; Codex should use its persistent
goal/monitor continuation; a shell operator can use:

```bash
"$AIUR_CMD" watch --changes --interval <seconds>
```

The timer and alert path are additive: an urgent alert is handled immediately,
while the cadence still provides a quiet-state floor. Do not depend on PR or
agent-completion events as the only wake-up mechanism.

## 5. Drive the run

On every observation:

- act on the `ACTIONABLE` section before routine scheduling;
- keep dependency-ready, conflict-free critical-path lanes occupied;
- let default-on AIMD govern effective slots under the session ceiling; use
  `"$AIUR_CMD" set max-agents <n>` to raise that ceiling deliberately or to
  lower it for resource/review pressure AIMD does not capture;
- classify discoveries before ticket creation, prefer contained rework, and
  freeze creation when promoted/created tickets outpace completions;
- keep feature critical-path counts/ETA separate from the deferred reliability
  and optimization ledger;
- follow the recovery ladder for stale, looping, or feedback-blind agents;
- treat `ci-wait` as an automatic gate unless evidence shows the poller failed;
- use `"$AIUR_CMD" message <id> <text>`, `pause`, and `resume` as the least
  invasive controls;
- preserve decisions and incidents in the durable handoff/workpad.

As PRs become ready, reserve capacity for the required parallel review/rework
loop defined in the Executor reference. Verify that review comments reach the
owning worker through the event path. Merge only under the recorded policy and
protect typed dependency/conflict ordering.

## 6. Backstop and defects

Prioritize unblocking Aiur workers. Take over an affected ticket/lane or patch
Aiur directly only when its recovery ladder is exhausted, takeover is the best
authorized option, and self-fix authority exists; other lanes may keep moving.

For Aiur crashes, leaked processes, missed comments, dispatch failures, or
broken controls, follow the reference's sanitization and consent policy:

- with separately recorded external issue mutation authority: check for
  duplicates, then file or comment with sanitized evidence;
- without that authority: prepare the sanitized draft and ask before filing or
  commenting.

Always remove secrets and privacy-sensitive context, regardless of debug mode.

## 7. Rebuild, resume, and stop

Use deliberate rebuild checkpoints after merges that must enter the worker
base. Stop the current session cleanly, update the base under the repository's
branch policy, rebuild, and resume only the remaining live GitHub scope.

Before context exhaustion, update the durable handoff and create a three-to-five
sentence goal describing the Executor role, authority, Build Order selector,
terminal condition, and immediate next actions. A replacement Executor starts
by querying live GitHub/Aiur state.

The true terminal condition requires the bounded feature to be implemented and
reviewed, integrated with green evidence on the current base, merged under the
recorded policy, documented, and proven through its named end-to-end workflow.
Deferred non-blockers do not extend that boundary. Then—or on an explicit human
stop—run:

```bash
"$AIUR_CMD" stop
```

Confirm the control plane and background processes are gone. A leak is an Aiur
bug and follows the same reporting policy.
