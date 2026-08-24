---
name: aiur-meta
description: Run one Aiur Executor meta-check — observe every operator-facing surface, name the current biggest bottleneck, file what is broken, and log it durably. Use for '/aiur-meta', 'meta check', 'hourly meta', 'aiur retrospective', or on the recurring timer that aiur-run sets up. Not a status poll; a status poll is one metric and this is an audit.
---

# Aiur meta-check

One pass over every surface an operator can see, ending in a named bottleneck and
a durable log. Run hourly during a run, on the timer `aiur-run` sets up.

## This check is a backstop, not the discovery path

**The meta-check is the quiet-state safety floor.** Work is discovered on the
event stream — the Executor listener's 24 bindings, drained by `executor-wait` or
a persistent wake monitor, which `aiur-run` requires as a launch step. This check
catches what the stream missed; it is not how you find out that a PR is ready.

Getting this backwards is expensive. On the 2026-08 run an Executor used the
hourly check as its primary loop while the durable wake inbox accumulated **2,832
unconsumed records — 402 of them `ticket.branch.push`** — cursor stuck at
`wake_id: 1`, oldest record five days old. The result was 17 PRs
reworked-but-unreviewed, 16 of them with zero failing checks, the oldest waiting
nearly a day.

So: **if this check is where you first learn of a rework, PR-ready, or CI event,
the event path is broken and that is itself the finding.** Check the wake inbox
depth and the consumer cursor, and report both.

**A meta-check is not a status poll.** Reading one metric and reporting it green
is the failure this exists to prevent. Every defect found in the first run of
this check was invisible to `aiur status` and `aiur alerts`, and three of four
were invisible to the HTTP API as well. If you did not *look at* the surfaces,
you did not do the check.

## The rule that governs everything below

**A surface that renders a confident wrong number is worse than one that fails.**
An operator acts on a number. A blank cell they investigate. So when auditing,
the question is never "did it render" — it is "would an operator who trusted this
have been misled".

Real examples from this repo: a provider meter reported `freshness: :fresh` on a
3.6-day-old reading and claimed a provider was exhausted when it was not
(#1564); a Build Order page rendered every ticket at 0% because completion
resolution failed silently (#1491); a blocker card described a PR as unmerged for
five days after it merged (#1565).

**The same rule applies to your own carried-forward claims.** A "standing item"
repeated from the last log is an unverified assertion, not a finding. On
2026-08-22 an Executor reported "webhook ingress was never enabled" in five
consecutive hourly logs, built a plan on it, and asked the operator to enable a
tunnel. Webhooks had been delivering `202 OK` the entire time. The claim was
inherited from a handoff and never re-tested.

**Re-verify every standing item you repeat, from the system that owns the
answer.** If you cannot cheaply re-verify one, say "unverified since <time>"
rather than restating it as fact. Carrying a stale claim forward is how a whole
run's plan ends up resting on something nobody checked.

### Verify capability from the system of record, not from local config

The failure above had a second half. The Executor *did* check — it ran
`tailscale funnel status`, saw Funnel disabled, and treated that as
confirmation. But Funnel was one hypothetical transport; the live one was a
Cloudflare tunnel the operator had already built.

**Checking a mechanism you assume is in use does not answer whether the
capability works.** Ask the system that owns the answer, not the local file that
would describe one possible implementation of it: delivery history over a
tunnel's status, `gh pr checks` over a local test run, the running daemon's
behaviour over a merge commit, a credential resolved against the API over a
variable that is merely set.

An empty local config proves nothing about a capability that may be provided
elsewhere. Prefer the source that would still be right if every local assumption
were wrong.

**Before auditing a GitHub-facing surface, read
[`website/docs-app/apis/github.md`](../../../website/docs-app/apis/github.md).**
It is the source of truth for how Aiur talks to GitHub — poll cadence, API
budgets, credential pooling, the read cache, webhook delivery states, and the
Cloudflare tunnel boundary. In the incident above it already documented the
tunnel and the delivery-state table that would have prevented the whole
detour. Do not restate its contents in a skill or a ticket; link to it, so there
is one copy to keep true.

## 1. Observe — do not infer

### Dashboard pages

Capture all four at a desktop viewport, full page, with console errors collected.
Stream Deck is excluded: it is a control surface, not a report, and has its own
coverage.

| page | route | what "working" means |
| --- | --- | --- |
| Units | `/` | every active agent, live state |
| Commands | `/commands` | real commands awaiting response |
| Build Order | `/build-orders` | progress that tracks reality |
| Analytics | `/analytics` | current data, not a frozen window |

Playwright is already vendored at `src/browser/`. Two details that cost time if
rediscovered each run:

- basic auth needs Playwright's `httpCredentials`, not inline URL credentials
- **LiveView hydrates after `domcontentloaded`.** Without a settle wait (~5s) the
  capture shows the static shell and every metric looks empty — a naive
  implementation reports false positives on every page, every hour

Credentials live in the daemon's environment as `AIUR_DASHBOARD_USERNAME` /
`AIUR_DASHBOARD_PASSWORD`.

Use the durable helper rather than starting a one-off browser session. It writes
full-page PNGs, `report.json`, and a short `verdict.md` beside the run's
retrospective, then appends that verdict to the narrative log:

```bash
.claude/skills/aiur-run/scripts/executor-retrospective.sh visual-check
```

The runner reads the daemon-published `@aiur_control_url` from its tmux socket,
rather than guessing a fixed port. Set `AIUR_DASHBOARD_URL` only when running
outside that tmux session. If neither source is available the check refuses
before the browser ever launches: it exits 67, prints which variable to set on
stderr, and writes a **did not run** verdict — a skipped check must never read
as a healthy capture. Dashboard credentials are likewise refused (exit 69)
after falling back to the running daemon's own environment when the wrapper
carries none, so the password never has to be copied out by hand. A page that
stalls past `AIUR_META_PAGE_TIMEOUT_MS` (default 120s) is reported as a timeout
verdict naming that page, keeps whatever partial screenshot completed, and the
remaining pages still run instead of the whole check hanging in silence.

Pass `AIUR_META_EXPECTED_CAPACITY` when the configured cap is known; it catches
a page reporting a stale cap as well as a peak greater than the displayed cap.
Pass `AIUR_META_EXPECTED_ACTIVE_AGENTS` when the run's current active-agent
count is known so a Units zero-state is only accepted for a confirmed idle run.
`AIUR_META_KNOWN_NOISE` accepts a JSON array of narrow `{kind, status, path}`
rules for a confirmed recurring browser error. Nothing is baselined by default —
the old `conversation-drawer-hook.js` 404 went away when #1681 landed. Only
baseline a path that has an **open** issue, drop the rule when that issue
closes, and never baseline all 404s. Whatever a rule suppresses is counted at
the bottom of `verdict.md`, so a stale baseline stays visible.

Then **look at the screenshots**. Reading extracted text is not the same as
seeing the page; a table of em-dashes reads as "empty" in text and as "broken" on
sight.

What to flag: missing primary content, rendered unavailable/error states,
staleness banners, `N/A` or em-dash where a number belongs, a metric column whose
values are mostly missing (or missing for any populated row), a metric column
that is entirely one repeated value, an empty table, a banner whose two halves
contradict each other, and any figure that disagrees with a known configured
value. A settled page that contains nothing recognizable is attention, never
evidence of health.

### The interactive CLI

The terminal is the surface most operators actually drive, and it degrades
first — under load the control RPC times out at 10s and `status` returns **empty
output with no error**, which is indistinguishable from a healthy idle fleet.

Run `aiur status`, `aiur agents`, `aiur alerts`. Record for each whether it
answered, **how long it took**, and whether output was non-empty. Slow is the
signal, not just failed: the CLI budgets 10s, so anything near that is already a
finding. An empty or timed-out response is a finding, never a skip.

Also record pane count against `pre_warmed_sessions` and the live agent cap —
that coupling (#1337) is invisible in config and obvious in a running session.

Use read-only commands. `stop`, `pause`, `resume` and `set` change fleet state
and have no place in a routine health check.

### The host

```
nproc; cat /proc/loadavg; free -g
```

Compare load against `agent.max_load_average × schedulers`. This box has run at
**load 100 on 16 cores** while status reported `binding: none` (#1610). If load
exceeds the threshold and the fleet reports headroom, that contradiction is the
finding.

### The fleet and the PRs

Open PR count, how many are conflicting, how many carry a stale review whose
objection a later commit already met. Compare the review timestamp against the
commit timestamps — "review is stale" and "review is unaddressed" look identical
until you do.

## 2. Name the bottleneck

Name the single biggest current time-sink and say what would shrink it. One
bottleneck, not a list. It is never "a completed check" — if everything looks
fine, the bottleneck is whatever is *next* slowest.

Distinguish three things that present identically as "the fleet is idle":

- **no supply** — nothing is queued (tickets need an explicit `agent:todo`; an
  open, labelled, unblocked ticket is invisible to dispatch without it)
- **no capacity** — a gate is holding
- **ramping** — the dispatch envelope starts at 1 slot every daemon start and
  widens per below-target sample

Resolve a bottleneck when it can be done without adding much complexity. Do not
invent work.

**When the bottleneck is review, the remedy is parallel review, not fewer
agents.** A queue that is growing with nothing approved is the Executor's own
throughput ceiling, and it is the most common steady-state bottleneck once the
fleet is healthy — on 2026-08-22 it reached 32 non-draft PRs with zero approved
against twelve agents. Measure it as two numbers, because they mean different
things: how many PRs have **never been reviewed** (a coverage problem) and how
many are reviewed but **not approved** (a throughput problem). Fan background
agents across the open PRs one per PR to clear it; `aiur-run`'s "Review the queue
in parallel" section owns the how, including the prompt contents that make a
review agent useful rather than a summarizer. Raising `max-agents` while the
queue grows makes it worse.

## 3. Ask what can move — within your mandate

**First establish the mandate, then act only inside it.** This skill is also
invoked via `/aiur-monitor`, where the agent is *watching* a run it does not own
and moving tickets is out of scope — observing, naming the bottleneck, and
reporting are the whole job. Before touching anything, check the handoff, the
operator's stated goal, and whether this agent launched with `--executor`. An
agent in monitor mode that starts merging PRs is a worse failure than one that
only reports, because it acts outside the boundary the operator set.

**The definition of "progress" belongs to the run's stated goal, not to this
skill.** If the operator scoped the run to one Build Order, to a ticket class, or
to observation only, that scope governs. The question is always "can anything
move *within my mandate*" — never "what can I touch".

Where the mandate allows it, ask whether any ticket or PR can be advanced right
now, and advance it. States that repeatedly sit unnoticed here:

- a PR **reworked after its blocking review**, green and mergeable, waiting only
  for a second look. Compare the PR's own contribution diff, not the commit
  timestamp — a merge of `main` moves the timestamp without changing anything
- a ticket in `agent:error` whose cause was **transport, not the agent** —
  recovered by re-labelling to the state its PR actually warrants, not by
  investigation
- **contradictory state labels** (`agent:ci-wait` + `agent:rework`,
  `agent:human-review` + `agent:in-progress`), which make `dispatch_authorization`
  deny the ticket permanently
- a ticket left in `agent:human-review` when its PR actually needs **author**
  rework — it reads as waiting on the Executor and is invisible to rework dispatch
- an **unlabelled** open ticket, which is invisible to dispatch entirely
- an approved PR blocked only by a **known flake** or by a failure inherited from
  a red `main`

**Check whether a ticket already has an open PR before re-dispatching it.** Nine
of ten tickets recovered this way already had one; a blanket re-dispatch would
have duplicated all nine.

## 4. File what is broken

Every finding becomes a ticket, linked to the run's meta epic. Not a note, not a
chat message — both die with the session. Of 71 findings in this repo's
2026-07-30 run, 23 reached no ticket, which is why the self-improvement pack
exists.

Give every ticket its disposition in the same creation request. Executable
findings carry the configured lifecycle todo label (`agent:todo` in the standard
workflow); deliberately parked findings carry `needs-triage` or `human:todo`
with the reason in the body. The meta epic is an explicitly named container and
remains undispatched.

Include the evidence that would let someone else confirm it without repeating the
investigation: the command, its output, file:line, the screenshot.

Do not fix findings inline inside an unrelated PR. That is how a finding becomes
invisible to everyone who was not in the room.

## 5. Log durably

Write to `~/.aiur/repo/<owner>/<repo>/meta/<UTC timestamp>-<slug>.md`:

- verdict per surface
- the named bottleneck and what would shrink it
- what changed since the last log — resolved as well as new
- what needs the operator, and why the Executor cannot do it

State resolved items too. A log that only lists problems reads as a fleet getting
worse.

## What the operator sees

Report the verdict, the bottleneck, and anything needing them. Lead with what is
broken. Do not narrate the check itself — that a check ran is not news; what it
found is.
