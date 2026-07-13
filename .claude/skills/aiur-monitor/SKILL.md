---
name: aiur-monitor
description: "Inspect and monitor a running Aiur session using its server-side status board and alert feed. Use for 'aiur status', 'aiur monitor', 'how are the agents doing', 'what is stuck', 'tail the agents', or as the observation/recovery component of aiur-run. It does not launch Aiur."
---

# Monitor an Aiur Run

This skill provides current evidence to the Executor. A human who launched
Aiur is the Executor and may ask an agent to monitor for them. An agent using
`aiur-run` is itself the Executor. The durable responsibilities and recovery
policy live in the
[Executor reference](../aiur-run/references/executor.md); do not duplicate or
override that authority here.

`iarc`, IAR, and AYR are operator aliases or common spellings for Aiur.

## One-shot status

From the repository root, use the local shim for an Aiur development checkout
or replace it with installed `aiur` in a consumer repository:

```bash
scripts/aiurdev watch --full
scripts/aiurdev alerts --needs-attention
scripts/aiurdev status
```

`watch --full` is the primary board. It reads the orchestrator snapshot and
structured alert feed server-side and prints ticket, state, complexity,
activity age, current work, and an `ACTIONABLE` section. Report that evidence
faithfully; do not reconstruct state from GitHub labels or log-tail heuristics.

If the orchestrator is not running, report `daemon down`. Do not render that as
an empty successful fleet and do not launch a replacement unless `aiur-run` or
the human Executor authorized it.

## Recurring monitoring

For a live run, first establish a full baseline, then use changes mode:

```bash
scripts/aiurdev watch --changes
scripts/aiurdev watch --changes --interval <seconds>
```

An agent Executor should arm the recurring mechanism available in its host and
continue until the run's terminal condition or an explicit stop. A human
Executor may request a one-shot snapshot without starting a recurring loop.

Rules:

- keep a time-based cadence even when no state changes;
- handle needs-attention alerts immediately rather than waiting for the next
  cadence tick;
- do not start nested recurring loops;
- do not treat one empty/warm-up board as terminal;
- use `watch --full` again after a daemon restart or when the delta baseline is
  uncertain.

The optional `scripts/watch-alerts.sh` streams new workspace alert records for
hosts that can supervise a persistent process. It adds immediacy but never
replaces the server-side board or the recurring cadence.

## Respond to actionable state

When the `ACTIONABLE` section is non-empty, name the ticket and concrete next
action. Then, if acting as the agent Executor, follow the canonical recovery
ladder:

1. inspect the ticket/PR, alert, workpad, and relevant logs;
2. message the worker with `scripts/aiurdev message <id> <text>`;
3. correct authoritative queue/dependency state only within granted authority;
4. pause/resume or restart when process delivery is broken;
5. route a sanitized Aiur bug under the debug/consent policy;
6. backstop the work only when the fleet cannot recover and self-fix is allowed.

`ci-wait` is normally an automatic gate owned by the central poller, not an
instruction to keep an agent alive polling GitHub. A PR-ready ticket does
require the Executor's configured parallel review/rework flow.

## Capacity signal

The board shows fleet activity, not all host pressure. While the agent is the
Executor, combine it with bounded checks of CPU, memory, file descriptors,
provider throttling, and review backlog. Raise or lower concurrency with:

```bash
scripts/aiurdev set max-agents <n>
```

Maximize useful parallel work, not raw workers. Blocked or contract-conflicting
tickets should not consume capacity merely to fill the board.

## Report shape

Lead with the outcome and urgent action, then include the Aiur board in a
fenced block. Add only evidence-backed interpretation: capacity change,
recovery action, review state, or an unresolved decision.

If a Build Order planning pack exists, link its stable IDs and acceptance
owner, but query GitHub and Aiur for current facts. Never require a
feature-specific hard-coded roadmap table in this generic skill.
