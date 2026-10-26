## 5. Drive the run

### A quiet fleet is usually blocked, not idle

Five distinct faults present identically as "the fleet is quiet", and none of
them log anything. Work this ladder before any per-agent triage:

0. **check for open tickets carrying no `agent:*` label.** A ticket without a
   dispatch state is well-formed, visible in GitHub, and completely inert: it
   appears in no state-scoped view, no agent can claim it, and the fleet
   truthfully reports `binding: ticket supply` while it sits. This is the
   fault most easily mistaken for "there is no work left".

   ```bash
   gh issue list --state open --limit 1000 --json number,title,labels \
     --jq '[.[]|{n:.number,t:.title,a:([.labels[].name]|map(select(startswith("agent:")))),l:[.labels[].name]}
           |select(.a|length==0)
           |select((.l|index("build-order"))==null)
           |select((.l|index("epic"))==null)
           |select((.t|test("(^(BO|Epic):)|[Ee]pic:"))==false)
           |"#\(.n) \(.t[0:60])"]|join("\n")'
   ```

   Build Order roots and epics legitimately carry no agent state — they are
   containers, not work — so exclude them or the real signal drowns. Match
   `epic:` anywhere in the title, not only as a prefix: this repo's meta epics
   are named `SP-901 Meta epic: …`, which a `^Epic:` anchor misses.

   **`--limit` must exceed the open-issue count.** `gh` truncates silently, so
   a limit below the total makes the check report fewer unlabelled tickets than
   exist — the safety net acquiring the exact failure mode it was written to
   catch. At 121 open issues, `--limit 100` returned 29 and `--limit 300`
   returned 33.

   On 2026-08-10 this found **28** such tickets, eight of them `priority:1`,
   while the fleet idled at 1-4 of 16 agents. Two described faults that then
   cost hours to rediscover from scratch: the CPU load gate not being applied
   (the fleet sat at `AGENTS 0/16` behind a load gate for an hour), and a third
   test-flake mechanism found while merge-queue ejections were being chased
   independently. A third had already diagnosed the operator's reported
   Build Order failure, precisely, and sat unqueued while the Executor
   investigated the same bug from the outside and filed a weaker duplicate.

   **This is not an agent-side problem.** Authorship on that backlog was
   roughly half agents and half the Executor's own identity, including two
   tickets the Executor filed the same day it was failing to notice them. Check
   your own filings, not just the fleet's — every ticket you open during a run
   needs todo or the queued Build Order marker at creation unless parked.

   Tracked as #1793.

1. run bare `"$AIUR_CMD" resume`. The global pause switch survives daemon
   restarts and machine reboots, and per-ticket `resume <id>` exits 0 silently
   while it is on;
2. check `agent.max_concurrent_agents` in `.aiur/config`; it silently floors the
   `--max-agents` flag (a configured 16 beats a passed 32);
3. check the prewarm gate: `~/.aiur/repo/<owner>/<repo>/base-record.json` must
   match `latest`'s `HEAD` and the configured prewarm script hash. A failed
   base build holds every dispatch tick (issue #1404); the repository node
   carries the clone, cache sidecars, and record across an org rename;
4. account for the adaptive dispatch envelope: it starts at **1 slot on every
   daemon start** (`dispatch_policy.ex:116`) and widens by `load_ramp_step` per
   below-target sample. With defaults (target 1.0, step 1, cooldown 60s) a
   restarted fleet needs ~30 minutes to reach 32, which reads as idle rather
   than ramping. Do not measure capacity within minutes of a restart.

A `CHANGES_REQUESTED` (or explicitly blocking `COMMENTED`) review on an open PR moves its
ticket to `agent:rework` from `agent:human-review` or `agent:ci-wait` when the
reviewer is trusted (configured account or CODEOWNER).

Body-only `COMMENTED` reviews need a line or heading starting with `Blocking:`,
`Blockers:`, `Must fix:`, or `Changes required:`, or an update, rebase, merge, or
fix requested “before merge”. Clean summaries such as “No blockers; waiting on
CI” or “All blockers resolved” do not route to rework.

Failed CI in `agent:human-review` routes to rework when that head already passed
CI or the head changed. An inherited failure on a dismissed head remains held;
the existing test-only one-poll retry still applies.

Alerts persist across daemon restarts and tokens (full-history scan, #1231), so
the `ACTIONABLE` list keeps naming long-merged tickets. Check timestamps before
acting and trust the top state table over the alert list.

Run `aiur executor-sweep` on every observation and handle its findings first. It checks decisions, approved PR/CI, merge queue, capacity/order, ticket hygiene, blockers, handbacks, and watcher/dispatcher health. Ready PRs unreviewed at their head rank first using `executor.sweep.unreviewed_pr_minutes`, whatever the ticket state (the finding names it, so a ready PR on an `agent:in-progress` ticket reads as a missed handoff); the daemon repeats every five minutes and wakes on new findings. Continue below for actions it cannot perform:

- act on the `ACTIONABLE` section before routine scheduling;
- continuously push toward the maximum **useful** concurrency across workers,
  independent reviewers, and merge/rework lanes. Keep every dependency-ready,
  conflict-free lane occupied; when live concurrency is below the run target,
  identify the exact limiting gate and prioritize removing it;
- dispatch in parallel **across** distinct build lanes, but **serialize within a
  shared-file clique**. Tickets that all edit one hot file do not run as
  independent lanes: they collide, and the resulting merge thrash is the most
  expensive waste class in a run — far costlier than the concurrency it buys. The
  known hotspot on this repo is the dashboard-ui clique around
  `dashboard_live.ex`; treat any file that several ready tickets all name as the
  same kind of clique and admit those tickets one at a time;
- let default-on AIMD govern effective slots under the session ceiling; use
  `"$AIUR_CMD" set max-agents <n>` to keep the ceiling at the recorded maximum.
  Lower it only for measured pressure AIMD/build gates do not capture, record a
  restoration condition, and raise it again as soon as that condition clears;
- use CPU saturation as a control target, then memory, file descriptors,
  build serialization, model/provider capacity, review capacity, and dependency
  width as successive bottlenecks. Do not leave CPU/memory/provider headroom
  idle while independent ready work or review work exists;
- measure live state before recomputing the ceiling: read the daemon
  (`"$AIUR_CMD" agents`, `"$AIUR_CMD" status`) together with host evidence —
  CPU idle/run queue, available memory, FD and build pressure, and occupied
  agent slots. Distinguish current worker-owned browser/test processes from
  stale PID-1 daemons with no live owner; the latter are recoverable capacity,
  not load to schedule around. Measured on a 16-core/31 GB host, saturation is
  ~19-20 concurrent agents (load ~14, memory 10/31 GB, GitHub budget
  4668/5000): CPU is the real ceiling, memory and API budget are not close.
  Note `max_load_average` is multiplied by the scheduler count, so `1.5` means
  "hold at load ~18" on 16 cores — it is not a 1.5 load cap;
- before dispatching a ticket, check whether its work already exists. Tickets
  whose deliverables shipped months ago or sit in an open draft PR produce
  busywork or agents that pause repeatedly with nothing to do;
- do not inflate utilization by waking `ci-wait`, human-review, dependency-
  blocked, or conflict-bound tickets. Those are external gates, not idle worker
  lanes. Instead fill reviewer capacity and staff the unblocker/fan-out spine.
  **Reviewer capacity is something you create, not something you wait for** —
  fan background agents out across the open PRs in parallel, one per PR, per
  ["Review the queue in parallel"](review-and-merge.md#review-the-queue-in-parallel-with-background-agents). When the queue is growing and nothing is
  approved, raising `max-agents` makes it worse;
- classify discoveries before ticket creation, prefer contained rework, and
  freeze creation when promoted/created tickets outpace completions;
- keep feature critical-path counts/ETA separate from the deferred reliability
  and optimization ledger;
- follow the recovery ladder for stale, looping, or feedback-blind agents;
- keep branch freshness with the owning worker. When a PR does not contain the
  current configured integration base, route one explicit update/re-cut packet
  to that ticket's agent before review. If that bounded recovery repeats without
  material progress, apply the convergence escalation below instead of leaving
  the PR in an ownership vacuum or another identical loop;
- treat `ci-wait` as an automatic gate unless evidence shows the poller failed;
- use `"$AIUR_CMD" message <id> <text>`, `pause`, and `resume` as the least
  invasive controls; for `message`, exit 124 = outcome unknown: check the ticket log first, then retry only with the printed `--message-id` command, never a plain resend (a plain resend now queues a second copy).
- preserve decisions and incidents in the durable handoff/workpad.

A PR becomes review-ready only when its configured base is correct, that base's
current remote head is an ancestor of the PR head, and fresh CI has run on that
exact head. The owning worker is responsible for fetching, integrating or
re-cutting against the current base, resolving semantic drift, and rerunning
validation on the first bounded recovery attempt. Until those facts hold, do
not start background review. Do not keep returning an unchanged failure to an
agent that is no longer converging; inspect and escalate ownership instead.

### Convergence watch and takeover

Continuously inspect unusually old active tickets and pull requests, especially
when observed implementation time is small relative to elapsed delivery time.
Treat these as warning signals, not as reasons to wait for a fixed timer:

- repeated worker starts, cold dispatches, `max_turns` recycles, or resume loops;
- an open PR with no live owning agent, a frozen head, or no material git progress;
- repeated review-to-rework or comment-triggered wake cycles on substantially
  the same change;
- repeated stale-base merges, conflict repair, or exact-head review invalidation;
- recurring CI, lint, or Dialyzer failures that do not produce a shrinking,
  authoritative failure set;
- a thrash/stall alert that does not latch, a completed-but-claimed worker, or
  another lifecycle state that leaves the PR stranded.

On a warning signal, inspect the issue/PR history, agent logs, restart count,
commit timeline, base ancestry, checks, comments, and current live owner. Send
one consolidated P0/P1 failure or update/re-cut packet and allow one bounded
recovery attempt when that is still economical. If the agent repeats the same
cycle, makes no material progress, becomes unowned, or the Executor reasonably
believes continued delegation is increasing delivery risk or cost, take
leadership under the recorded self-fix/takeover authority. The Executor may
pause the duplicate worker and directly finish, re-cut, validate, push, review,
and merge the ticket in an isolated worktree. Catastrophic Aiur failure is not
required.

Preserve the original branch/workspace, keep the ticket's acceptance boundary,
defer non-blocking nits, and record the evidence and reason for takeover. The
purpose is fast, safe convergence—not making the Executor the default worker.

Once the gate holds, reserve capacity for the required parallel review/rework
loop defined in the Executor reference. The reviewer's first task is to diff the
PR body's claims against the diff; any claim the diff does not support is a P1,
never a nitpick. Six of the nine pull requests rejected in the 2026-07/08 run
were exactly this shape, and every one of them would have merged on a skim. A
body edited *down* toward a thinner diff is the same defect: the capstone PR was
quietly retitled from "driven by live fleet state" to "runbook and evidence
framework" and marked done while the page still rendered invented data. Ask two
questions of every new test — does it execute at all, and would it still pass
against a trivially wrong implementation? Twenty tests sat outside the `vitest`
include glob for 5.8 hours while their pull request read as fully tested. Verify
that review comments reach the owning worker through the event path, and that
the review itself landed rather than merely being submitted. Merge only under
the recorded policy and protect typed dependency/conflict ordering.

After every merge, dependency change, CI completion, review result, or material
load change, recompute ready width and the safe concurrency ceiling immediately.
Dispatch the newly ready batch in the same observation; never wait for the next
reporting tick merely to restore utilization.

## Convergence escalation and takeover

Do not measure progress solely by whether a worker process is alive. Inspect
long-running tickets and PRs for delivery progress, particularly when the code
was implemented quickly but review, rework, CI, or integration has consumed
most of the ticket lifetime.

Escalation signals include:

- multiple worker starts, cold dispatches, `max_turns` recycles, pause/resume
  loops, or a completed-but-claimed entry with no continuation;
- an open PR with no live owner, a frozen head, or repeated turns without a
  commit, test result, resolved finding, or reduced diff;
- repeated comment-triggered review-to-rework transitions, exact-head reviews
  that continually mint new blocking findings, or fragmented reviewer packets;
- repeated integrations of a moving base, recurring conflicts on the same hot
  files, or a branch that repeatedly becomes stale before review begins;
- recurring CI/lint/Dialyzer failures without a shrinking authoritative failure
  set, including a non-latching thrash alert or failed wake/continuation path;
- elapsed delivery time that is disproportionate to the observed implementation
  work and no evidence-backed completion trajectory.

When one or more signals appear:

1. inspect the issue and PR timelines, commits, checks, review comments, base
   ancestry, live agent state, restart count, workpad, and agent logs;
2. identify the single current blocker and send one consolidated P0/P1 failure
   or update/re-cut packet to the owner;
3. allow one bounded recovery cycle when the owner is live and the repair is
   economical, while defining the material progress that must occur;
4. if the worker repeats the same cycle, makes no material progress, becomes
   unowned, or direct completion is now reasonably safer/faster, stop duplicate
   writers and take over under the recorded authority;
5. use an isolated worktree, preserve the existing branch/workspace, retain the
   original acceptance boundary, defer non-blocking nits, establish one
   current-base head, run focused validation plus the required central gate,
   and merge under the recorded policy;
6. record the evidence, attempted recovery, takeover reason, and outcome in the
   durable handoff so future runs can improve their triggers.

This is a judgment rule, not a rigid elapsed-time gate. Do not wait for a
catastrophic crash or an arbitrary age threshold when the evidence already
shows that delegation is not converging. Conversely, do not take over merely
because the first ordinary repair is inconvenient.

### Run an Experiment analyst locally

Use `aiur experiments analyze <id> --local` to obtain the sanitized analyst brief and any existing ticket URL.
Park that ticket first, then run exactly one background agent with the brief and `aiur-experiment` skill.
Confirm the submitted pre-registration or report version before completing the analysis ticket; never run two analysts for one experiment.

Read now: [Review and merge](review-and-merge.md) before starting review.
