---
name: aiur-monitor
description: "Inspect and monitor a running Aiur session using its server-side status board and alert feed. Use for 'aiur status', 'IAR status', 'iarc status', 'AYR monitor', 'how are the agents doing', 'what is stuck', 'tail the agents', or as the observation/recovery component of aiur-run. It does not launch Aiur."
---

# Monitor an Aiur Run

This skill provides current evidence to the Executor. A human who launched
Aiur is the Executor and may ask an agent to monitor for them. An agent using
`aiur-run` is itself the Executor. The durable responsibilities and recovery
policy live in the
[Executor reference](../aiur-run/references/executor.md); do not duplicate or
override that authority here.

`iarc` is an Executor alias for `aiur`; IAR and AYR are common spellings.

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

The optional `scripts/watch-alerts.sh` streams new local-workspace alert records
for hosts that can supervise a persistent process. Remote-worker and
workspace-less alerts remain visible through the server-side board's central
feed, so the script never replaces the recurring cadence. Read
[Alert and decision relay](references/alerts-and-decisions.md) before arming it.

## Respond to actionable state

When the `ACTIONABLE` section is non-empty, name the ticket and concrete next
action. Then, if acting as the agent Executor, follow the canonical recovery
ladder:

1. inspect the ticket/PR, alert, workpad, and relevant logs;
2. message the worker with `scripts/aiurdev message <id> <text>`;
3. correct authoritative queue/dependency state only within granted authority;
   in a GitHub workflow, use the `agent:paused` tracker overlay to shelve an
   undispatched ticket;
4. pause/resume an existing worker; stop and relaunch the run when process
   delivery is broken because there is no per-worker restart control;
5. route a sanitized Aiur bug under the debug/consent policy;
6. backstop the affected ticket/lane when recovery is exhausted, takeover is
   the best option, and self-fix is allowed.

`agent:ci-wait` is an expected, non-actionable idle state. The central
`Aiur.Events.GithubCiPoller` owns continuous CI polling while the worker is
paused and its slot is released. Do not keep or wake a worker turn just to poll
`gh pr checks`; a terminal event or configured fallback wakes the next action.
A PR is review-ready only after its owning worker has put the exact head on the
configured integration base, made the current remote base an ancestor of that
head, and passed fresh CI. If it is stale, report a worker update/re-cut action;
do not count it as available review capacity and do not have the Executor or
reviewers update its code. A genuinely ready ticket requires the Executor's
configured parallel review/rework flow.

## Capacity signal

The board shows fleet activity, not all host pressure. While the agent is the
Executor, combine it with bounded checks of CPU, memory, file descriptors,
provider throttling, and review backlog. `set max-agents` changes the session
safety ceiling; default-on AIMD controls effective slots below it. Change the
ceiling with:

```bash
scripts/aiurdev set max-agents <n>
```

Maximize useful parallel work, not raw workers. Blocked or contract-conflicting
tickets should not consume capacity merely to fill the board.

## Feed the hourly meta-analysis

The Executor's hourly meta-analysis (see the Executor reference) names the
single largest wall-clock cost and classifies recurring failure classes. The
monitor's role is observation: accumulate the per-hour evidence that analysis
consumes — counts, timestamps, and recurrences of the same symptom or failure
class — rather than performing the analysis itself. Note when the same class
of problem (not the same incident) repeats across tickets or hours.

If no Executor is active, the monitor itself files the systemic ticket when a
class crosses the threshold (3+ reproductions, or 2 with a shared root cause),
recording the reproductions that justify it, under the normal issue-creation
authority rules.

Write the resulting evidence as host-local state, not a worktree document:
append findings to `~/.aiur/repo/<owner>/<repo>/meta/findings.ndjson` and write
the hourly retrospective to `meta/retros/<boot-id>.md`. Use `aiur findings
--unfiled` to make unfinished promotion visible; a `ticket: null` finding is
not complete. Raw state does not cross machines. The periodically regenerated,
committed digest in `docs/executor/` is the only cross-machine channel.

## Report shape

Lead with the outcome and urgent action, then include the Aiur board in a
fenced block. Add only evidence-backed interpretation: capacity change,
recovery action, review state, or an unresolved decision.

For a bounded feature run, also report two independent tracks:

1. feature critical path, remaining active ticket count, acceptance gaps, and
   ETA when source-backed;
2. reliability/optimization findings, separated into active, deferred, and
   post-feature counts.

At each interval report completed versus created/promoted tickets. If creation
exceeds completion, surface that the mandatory creation freeze is active.
Deferred findings never inflate feature remaining count or ETA.

If a Build Order planning pack exists, link its stable IDs and acceptance
owner, but query GitHub and Aiur for current facts. Never require a
feature-specific hard-coded roadmap table in this generic skill.
