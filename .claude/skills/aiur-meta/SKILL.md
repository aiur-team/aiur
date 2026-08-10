---
name: aiur-meta
description: Run one Aiur Executor meta-check — observe every operator-facing surface, name the current biggest bottleneck, file what is broken, and log it durably. Use for '/aiur-meta', 'meta check', 'hourly meta', 'aiur retrospective', or on the recurring timer that aiur-run sets up. Not a status poll; a status poll is one metric and this is an audit.
---

# Aiur meta-check

One pass over every surface an operator can see, ending in a named bottleneck and
a durable log. Run hourly during a run, on the timer `aiur-run` sets up.

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

## 1. Observe — do not infer

### Dashboard pages

Capture all four at a desktop viewport, full page, with console errors collected.
Stream Deck is excluded: it is a control surface, not a report, and has its own
coverage.

| page | route | what "working" means |
| --- | --- | --- |
| Units | `/` | every active agent, live state |
| Commands | `/decisions` | real commands awaiting response |
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
outside that tmux session; if neither source is available it records an explicit
attention verdict without attempting the wrong dashboard.

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

What to flag: staleness banners, `N/A` or em-dash where a number belongs, a
metric column that is entirely one repeated value, an empty table, a banner whose
two halves contradict each other, and any figure that disagrees with a known
configured value.

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

## 3. File what is broken

Every finding becomes a ticket, linked to the run's meta epic. Not a note, not a
chat message — both die with the session. Of 71 findings in this repo's
2026-07-30 run, 23 reached no ticket, which is why the self-improvement pack
exists.

Include the evidence that would let someone else confirm it without repeating the
investigation: the command, its output, file:line, the screenshot.

Do not fix findings inline inside an unrelated PR. That is how a finding becomes
invisible to everyone who was not in the room.

## 4. Log durably

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
