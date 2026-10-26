---
name: aiur-run
description: "Launch and operate an Aiur run end to end as its Executor: establish authority, protect a finite acceptance boundary, launch and monitor, maximize safe critical-path parallelism, recover agents, coordinate PR review/rework, apply merge policy, and handle Aiur defects. Use for 'run aiur', 'run IAR/AYR', 'iarc run', 'run the aiur loop', '/aiur-loop', 'improve this repo with aiur', 'execute this Build Order', or a persistent Aiur goal."
---

# Run Aiur as the Executor

Before launch, resolve repository-local `.aiur/config`, then `~/.aiur/config`. If only global defaults exist, tell the user that Aiur will fall back to them; do not require `aiur init` or copy config into every repository. Global GitHub startup targets the current `origin` and ensures required workflow/marker and complexity labels before dispatch, without seeding model/effort/alias labels. Prefer config (`agent.priority`, backend settings, `agent.routing`) for model selection. Shared credentials belong in `~/.aiur/.env` outside Git, or configured App/keyring auth. Missing-label permission failures must be resolved before launch; existing pauses and human decisions remain binding. Omit `tracker.github.repo` in portable global defaults; a conflicting explicit repo fails safely. Use local `init` when repository-specific settings are needed.

Home setup is performed once; each repository still needs readiness checks. Follow [per-repository setup](../aiur-intro/SKILL.md#prepare-each-repository-without-repeating-init): verify effective credential Write access, base-branch inputs, CODEOWNERS or
explicit dispatch allowlist, and worker validation. Create missing CODEOWNERS with the approved human owner under the user's authority. Tell the user what was created and what remains blocked; distinguish startup from observed worker push/PR publication.

Use this skill when the agent owns the whole Aiur run, not merely its launch. It replaces the former `aiur-loop` workflow. Read the canonical
[Executor role](references/executor.md) before acting, then use `aiur-monitor`
for status reads and the recurring observation loop.

Before interpreting a dictated operator message, read the shared
[dictated-input note](../aiur-agent/dictated-input.md).

`iarc` is an Executor alias for `aiur`; IAR and AYR are common spellings. Treat
their run requests as this workflow.

## Who you are talking to

A run is started and then left. The operator walks away; the fleet works for
hours. Everything below that tells you to report something is governed by this
section first, because the same sentence is useful to a present reader and pure
waste to an empty terminal.

**The signal is how the turn began, and you always have it.**

- **Attended** — a human message opened this turn.
- **Unattended** — a wake event, task notification, monitor firing, scheduled
  tick, or self-scheduled loop opened it.

Nothing needs to detect this. There is no presence flag in the daemon and none
should be added: the operator may be watching the dashboard or the Stream Deck
rather than the terminal, so the only thing you can honestly know is whether
someone just spoke to you.

### Attended: unchanged

Answer what was asked, in the operator's configured style, including any
personal style skill they have loaded. This section takes nothing away from an
attended turn.

### Unattended: one skimmable line, or silence

Write for someone scrolling back through six hours looking for what merged,
what is stuck, and what needs them. Paragraphs fail that reader — this is not
only a token argument, terse lines are genuinely better for the person coming
back.

```
- merged #2637 init repo-local config — unblocks #2639 label creation
- #2638 .env credential shadow — codex terra picked up, low effort
- #2641 usage-probe — agent blocked, needs a decision: <url>
- 90% — 10 agents on phase 3 tickets, 2 in review
```

- One line. No preamble, no recap, no closing.
- Lead with the identifier — `#2637`, `merged`, `90%`. The first token is what
  the eye scans for.
- **Carry enough context to be understood cold.** The reader has been away for
  hours and does not remember what `#2638` is, what "Y" was, or which agent you
  meant. Every line pairs the number with a few words of subject: `#2638 .env
  credential shadow`, never a bare `#2638`. A line the operator has to go look
  up has failed — they will read it in a scrollback, with nothing else loaded.
  This is the one place terseness must give ground: shorter is better only up
  to the point where the line still stands alone.
- Name the consequence, not the mechanism: "unblocks #2639 label creation", not
  "the dependency edge was recomputed".
- Spell out anything you would otherwise abbreviate for yourself — internal
  shorthand, run-local letters, backend nicknames, alert topic names. If a term
  only means something because of an earlier turn, it does not belong in an
  unattended line.
- Do not restate *history* from an earlier line — the scrollback holds that —
  but do restate *identity* every time. Those are different: repeating "what
  happened before" is noise, repeating "which thing this is" is the whole point.
- **Silence is the default.** A tick that found nothing emits nothing. A check
  that ran and passed is not news. This is the largest saving here and the
  easiest rule to talk yourself out of, because a quiet tick feels like it
  should be acknowledged. It should not.

### Escalation is never terse

Terseness governs reporting, never blocking. Anything that stops the run — a
command request, a decision only the operator can make, a downed fleet, an
exhausted credential — gets its line **and** a push notification. A blocked run
discovered three hours late costs far more than the tokens saved by not saying
so.

### A periodic progress table, not a per-tick one

A returning operator wants shape as well as events. On a real cadence — the
hourly audit is the natural one — or when the shape materially changes, emit
one compact table instead of prose about overall progress:

Read per-feature progress from Build home at `/?view=list&list=features`.

```
#2637  init repo-local config    ████████░░  80%  codex terra   PR #2650 ci
#2638  .env credential shadow    ██████░░░░  60%  codex sol     rework
#2639  init creates no labels    ███░░░░░░░  30%  codex terra   in progress
#2640  idle poll backoff         ░░░░░░░░░░   0%  —             queued
```

- Fixed width, so columns line up when scrolled past quickly.
- One row per *active* ticket. Queued work is a count, not rows.
- Every percentage comes from an observable signal — PR state, CI state,
  checklist completion. Never estimate one. A percentage you cannot resolve
  renders as `—`; a confident wrong number is worse than a blank, which is the
  same rule the meta-check applies to every other surface (#1491 rendered every
  ticket at 0% because completion resolution failed silently, and it read as
  real).
- A table on every wake is exactly the noise this section exists to remove.

### Returning is a transition

When a human message arrives after an unattended stretch, lead with a compact
digest of what happened while they were gone, then answer what they asked. Do
not make them reconstruct it by scrolling.

Read now: [Establish the run contract](references/run-contract.md) before preflight.

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
4. choose a measured starting cap and the recorded maximum. Treat `max-agents`
   as a runtime admission ceiling recomputed from dependency-ready width,
   serialization constraints, model capacity, CPU, memory, file descriptors,
   and build-gate pressure — never a fixed program-wide target. Keep the
   session ceiling high enough to admit every ready independent lane; use
   AIMD/build gates or explicit resource thresholds to regulate effective
   concurrency, not an arbitrary low fixed cap;
5. when `AIUR_CMD=scripts/aiurdev`, use `"$AIUR_CMD" build` if the local release
   needs an explicit clean checkpoint; ordinary local launches rebuild stale
   sources, and installed `aiur` has no shim-only `build` command.

Preflight also covers the Executor wake path. The listener is armed on **every**
run now, with or without `--executor`, so `LISTENER absent` no longer means "no
Executor was intended" — it always means the recording path is broken and this
run is losing its wake stream. Treat `LISTENER absent` on your post-launch
`status` as a failed launch, not a warning, whatever flags you used.

Do not use `--test` or `--test3` for a real run. Those are destructive sandbox
harnesses. Do not run from nested tmux.

## 3. Launch

Use the repository shim while developing Aiur and the installed `aiur` command
in consumer repositories. Equivalent background forms are:

```bash
"$AIUR_CMD" run --bg --executor --debug --max-agents <n>
"$AIUR_CMD" --bg --executor --debug --max-agents <n>
```

`--executor` is required for every Executor-owned run, but what it now declares
is **authority**, not recording. Every run records the wake stream and every run
arms the listener; `--executor` is what raises created and deferred Commands as
needs-attention alerts, and it registers a renewing principal in
`executor-roster`. A live peer with a different identity is recorded as an
observer. Registration never acknowledges wakes or advances the shared cursor;
only `executor-wait` does that. If you are acting as the Executor, launch with
`--executor`; there is no valid Executor launch without it.

For a multi-instance fleet, run one Executor from one machine. Stop the
per-machine Executors, then use `aiur --instance all executor-wait --as
<executor-id> --json` in its loop. The CLI waits on every registered instance
and returns records as soon as one instance has wakes; each instance has its
own deferred-ack cursor, so a retry after interruption redelivers uncommitted
wakes. Use `--instance <name>` to wait on one remote instance. Remote waits
require an explicit `--as` identity and cap `--timeout` at 600 seconds.

Include `--debug` only when authorized. It controls evidence capture and never
authorizes filing or commenting on an issue; those mutations require separately
recorded authority. Do not combine the separate `--todo` command with launch
options.

Verify `status` immediately after launch. A healthy launch reports
`LISTENER present (28 bindings: executor.#, ...)`; a partial binding set reports
`LISTENER degraded (N/28 bindings; MISSING: ...)`; and no live bindings reports
`LISTENER absent (FAULT: ...)`. Treat degraded or absent as a launch failure and
fix it before dispatching work; a run that dispatches agents but cannot hear their handoffs
is worse than one that refuses to start.

Run `aiur executor-roster` at the same point. Another executor may legitimately
be listening — the operator may want more than one — so a healthy peer is
information, not an error. Report any peer to the operator with its evidence
(`last_renewed_at`, `last_acknowledged_at`, `pending_count`, whether the cursor
moved), and say plainly when one is `stalled` or `expired`. Recommend; do not
revoke a live peer's claim yourself. `aiur executor-revoke <id>` is the
operator's decision.

**Arm the wake monitor before dispatch.** The daemon holds the real event-bus
subscription (28 bindings); **the Executor does not.** Events are projected to a file —
`~/.aiur/repo/<owner>/<repo>/executor/<repo>.executor.wakes.ndjson`, with the read
position in `<repo>.executor.wakes.cursor.json`. `<repo>` is the sanitized final
segment of the tracker project identity (`Paths.repo_name/0`; for example,
`khala`, producing `khala.executor.wakes.ndjson`), not always `aiur`. Nothing
pushes. Without a
monitor you see events only when you happen to run a command, and on the
2026-08 run that meant 2,832 unconsumed records — 402 of them
`ticket.branch.push` — with the cursor still at `wake_id: 1` and the oldest
record five days old.

The requirement is: convert that file into a push signal by whatever mechanism
your harness has, persistent for the session lifetime. In Claude Code that is
the `Monitor` tool with `persistent: true`. The reference implementation:

```bash
wake_path="$HOME/.aiur/repo/<owner>/<repo>/executor/<repo>.executor.wakes.ndjson"
if [ ! -f "$wake_path" ]; then
  printf 'aiur: wake monitor not armed: expected wake stream is absent: %s\n' "$wake_path" >&2
  exit 1
fi
last="$(tail -n1 "$wake_path" | jq -s 'last.wake_id // 0')"
tail -F -n0 "$wake_path" \
  | jq -rcn --unbuffered --argjson last "${last:-0}" 'foreach inputs as $w ({last: $last}; {last: ([.last, $w.wake_id] | max), new: ($w.wake_id > .last)}; select(.new) | $w) | select((.topic_class // "") | test("allowed_contributor|branch\\.push|pr\\.ready_for_review|pr\\.opened|agent\\.handoff\\.human_review|ci\\.failed|agent\\.attention|retry_exhausted|tokens_exhausted|connectivity_lost")) | "\(.topic_class) ticket=\(.ticket // "-") pr=\(.pr_number // "-") observation=\(.observation // "-")"'
```

Each detail is a trap someone already hit: `tail -F` (follow by name), not
`-f`, because the file is rotated; `-n0` so arming does not replay the whole
backlog as notifications; `jq --unbuffered`, or events sit in jq's buffer and
never arrive. **Dedupe by `wake_id`**, seeded from the file's last `wake_id` at
arm time: past its 10,000-record cap the daemon trims the journal to 8,000 by
renaming a new file into place, and `tail -F` re-emits a renamed file from the
top. Unseeded, a trim right after arming still replays all of it (#4166). The
existence check makes a wrong repository or uninitialized state node fail
visibly. The filter must cover **failure** signals (`ci.failed`,
`agent.attention`, `retry_exhausted`, `tokens_exhausted`, `connectivity_lost`).

The tail is notification-only. It does **not** advance the durable cursor and
cannot substitute for `executor-wait`: `-n0` skips the existing prefix, the
filter intentionally omits many wake classes, and a follower has no Executor
identity or owner lease. Ordinary `aiur status` prints `WAKES CURSOR <id>
PENDING <count>`; a growing `PENDING` value means the authoritative consumer is
not draining even when tail notifications are arriving.

`ticket.branch.push` is the **rework signal**: it names the PR and means "a
blocking review has probably been addressed; re-review now". Agents also post
an explicit PR comment on rework naming the head SHA and the findings they
addressed, so an Executor that misses a rework has ignored two independent
notifications. And an undrained wake inbox is itself a reportable finding —
check its depth during the periodic audit, because a growing backlog means the
monitor is not armed or its filter does not match.

**Say so to the human.** At the first status report after launch, state one
line confirming the subscription, for example: "Listening for Executor events
on all 28 reviewed bindings." This is a deliberate spoken confirmation, not a silent
internal step: a run that subscribes says so, so a run that says nothing is
legible as broken immediately. If the listener is later confirmed dead or
restarted, pair the same statement with that loss, so the operator learns about
a mid-run interruption too.

Then use a full monitor snapshot to confirm the orchestrator, queue, alerts,
and first dispatch. Background mode is intentionally headless; observe it
through the control commands, not TUI panes.

Before increasing the session ceiling, verify the configured repo prewarm is
ready or intentionally disabled. A prewarm error can fall back to cold workspace
builds; reduce concurrency before that fan-out.

Read now: [Arm monitoring immediately](references/monitoring.md) after launch, including the [Command decision loop](references/command-decisions.md) and [Hourly meta-analysis](references/meta-analysis.md).

Read now: [Drive the run](references/driving.md) on every observation, and [Review and merge](references/review-and-merge.md) before review, merge, or closure.

## 6. Backstop and defects

Prioritize restoring productive Aiur workers, but do not preserve nominal
worker ownership while delivery is demonstrably failing to converge. A single
ordinary stale-base, conflict, lint, or review repair remains the owning
worker's first responsibility. Repeated cycles, loss of a live owner, prolonged
no-progress age, or a reasonable evidence-backed judgment that takeover is now
the faster and safer path permit the Executor to take over under recorded
self-fix/takeover authority. Follow the [convergence watch](references/driving.md#convergence-watch-and-takeover), stop duplicate
writers, and keep other independent lanes moving.

For Aiur crashes, leaked processes, missed comments, dispatch failures, or
broken controls, follow the reference's sanitization and consent policy:

- with separately recorded external issue mutation authority: check for
  duplicates, then file or comment with sanitized evidence;
- without that authority: prepare the sanitized draft and ask before filing or
  commenting.

Always remove secrets and privacy-sensitive context, regardless of debug mode.

### Environment hazards

- Backgrounded shell commands containing heredocs can silently fail to apply
  while reporting success; this has produced a duplicated config block and a
  duplicated doc section. Prefer the Write/Edit tools for file content, and
  verify the file after any heredoc write or append rather than trusting the
  exit status.
- A global rename is only safe where the value is a literal on both sides of an
  assertion. A fixture that composes a value from parts (`owner: "x"` plus a
  repo name) has its assertion renamed and its producer missed. Grep for the
  unjoined components, not just the composed string; missing this broke three
  of four coverage shards and the browser harness.

### Fix what you notice

Noticing a problem is the start of the work, not the report. In the same turn:

1. **Stop the bleeding.** If a reversible change within your authority removes
   the symptom now, make it: an existing config value (back up the config
   first), a dequeue, a cancel of runs for discarded merge groups, a label
   repair, an approval on the current head. Verify the effect from the live
   system (daemon log, queue, runs), not from the edit.
2. **Question the mechanism.** A symptom that repeats is a design problem. Ask
   why the mechanism exists before working around it again. On 2026-10-21 the
   150-minute `agent.max_agent_duration_minutes` cap paused seven progressing
   agents in one afternoon while the Executor relabelled and restarted them; the
   no-progress stop and command timeouts already guard against runaway agents,
   so the cap was set to 0 (the documented "disabled" value).
3. **File and dispatch.** File the root cause with `agent:todo` and the
   evidence, so it joins the continuous build now. Do not keep it in a deferred
   ledger because it is "incidental": the queue orders it against other work.
4. **Do it by hand once.** The second manual repeat of the same fix is an
   automation ticket, with the counts as evidence (see `aiur-meta` 3b).
5. **Disarm before you review.** If a PR with auto-merge on gets a push after
   your approval, disable auto-merge first, then review the new commits; `main`
   has no review rule, so an unreviewed commit merges on green CI.

Escalate to the operator only what is theirs: spend, product choices the pack
does not answer, store releases, deploys they reserve, and irreversible
actions. Everything else, act and report.

When a reproducible Aiur defect is discovered, diagnose and file it first, then
dispatch it with `agent:todo` unless it would displace ready critical-path work
that the operator ranked ahead of it. Base the decision on the measured live
state in the [capacity policy](references/executor.md#capacity-policy) and record any deferral, with its reason, in the Executor decision
ledger.

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
