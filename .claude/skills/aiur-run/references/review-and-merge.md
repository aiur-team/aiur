# Review and merge

### Review the queue in parallel, with background agents

**Review is the Executor's own throughput ceiling, and reviewing serially is the
single easiest way to become the bottleneck.** A fleet of N agents produces PRs
at N times the rate one reader clears them. On 2026-08-22 twelve agents ran
against one reviewer and the queue reached 32 non-draft PRs with **zero
approved** — every PR had been looked at, and none could merge.

So do not read PRs one at a time. **Dispatch one background agent per PR (or per
tightly-coupled pair) and run them concurrently**, then post the reviews
yourself. This is the same parallelism the run applies to implementation, applied
to the lane that gates it.

**Check load before every fan-out, and again before topping up.** Review agents
run `mix test`; each one is a BEAM plus a compile. They are *not* governed by
`agent.max_load_average` — that gate holds the Aiur fleet, and nothing holds
these. On 2026-08-22 a fan-out of eight reviewers alongside eleven fleet agents
drove a 16-core box to **load 45 against a threshold of 24**, with an 83 five-minute
average and 31 concurrent BEAMs. The fleet correctly reported `binding: load+cpu
contention` and stopped dispatching; the reviewers kept going, because nothing
told them not to.

Read `/proc/loadavg` and `free -g` first. If one-minute load is already near the
threshold, dispatch fewer and top up as they return rather than launching the
whole set. Prefer batching several small PRs into one agent over one agent per PR
when the box is busy — the wall-clock cost of a queued agent is lower than the
cost of freezing the host the fleet is working on.

**Watch for rework while you review.** Rework lands minutes after a review, and
`gh pr list` shows `CHANGES_REQUESTED` identically whether the author has
responded or not. The only way to see it is to compare each PR's last commit
timestamp against its last review timestamp. Measured on this repo:
**15 of 20 PRs showing `CHANGES_REQUESTED` had been reworked since the review
that blocked them, and 12 of those were mergeable with zero failing checks.** The
queue was not blocked — it was unattended, and three quarters of it was already
finished work waiting for a second look nobody scheduled.

One asymmetry explains why this only ever accumulates: a branch ruleset with
`dismiss_stale` dismisses stale **approvals** on push, and nothing dismisses a
stale **`CHANGES_REQUESTED`**. Worse, the stale block keeps re-routing the ticket
to `agent:rework`, sending an agent to redo work that is already done. A
re-review is far cheaper than the first pass: scope it to *"were these named
blockers fixed?"*, passing the original findings with their file:line, and ask
for FIXED / NOT FIXED / PARTIAL per blocker rather than a fresh read.

**Give every review subagent its own scratchpad and require worktree isolation
for mutation testing.** Concurrent review agents on one box share a session
scratchpad root, and a shared default write path is the failure: two agents
pick the same obvious worktree name (`wt`, `worktree`, `pr`, `build`), the
second repoints the first's checkout at a different branch *mid-run*, and the
first agent's mutation test then runs against a tree that never contained the
change it just reverted — a confident wrong verdict on a PR. The contamination
is bidirectional: another agent writing into your correctly-identified worktree
is indistinguishable from your own tree, so only isolating the write paths
fixes it. Naming discipline alone never will — each instruction to be unique
creates a new shared name one level up. Tracked as #2362.

- **Give each subagent a per-agent scratchpad.** Key the scratchpad on the
  subagent's id, mirroring `tasks/<agentId>.output`, so no two subagents share
  a default write root. If a shared area is genuinely needed, put it in an
  explicit `shared/` subdirectory so sharing is a choice, not the default.
- **Never persist the worktree path in a file.** Shell state does not survive
  between a subagent's calls, and telling it to remember a unique path in
  `scratchpad/wt.txt` moves the collision one level up — five agents
  independently invented the same filename and clobbered each other. Require
  the agent to recompute the path inline per command (e.g.
  `scripts/agent-worktree path <n> --unique <agent-component>`) instead of
  reading a stored value.
- **Assert the worktree HEAD before every mutation batch.** `git -C <wt>
  rev-parse HEAD` must equal the intended SHA (`gh pr view <n> --json
  headRefOid`), and the batch aborts loudly on drift.
  `scripts/agent-worktree head-check <wt> <sha>` makes this one command and
  exits non-zero on mismatch. The tree must be clean too: the #2362
  contamination overwrote a file in place without committing, so HEAD alone
  proves nothing. Pass `--allow-dirty` only for the batch's own reverts,
  asserted before the first mutation.
- **Forbid mutation testing in the live checkout.** A worktree is required,
  not optional: never `git checkout <sha> -- <files>` inside the Executor's
  own checkout.

What a review agent needs in its prompt, every time:

- **The established facts it must not re-derive.** Measured numbers, the file:line
  of the mechanism, which claims were already corrected. A reviewer that
  re-discovers context spends its budget on what you already know, and a
  reviewer given a stale "fact" will confidently confirm it.
- **The boundaries that make an approval wrong.** Name the invariants a change
  must not violate — on this repo, the `@unsafe_selections` refusals in
  `read_cache/policy.ex` are correct and a PR that "improves the cache hit rate"
  by caching verdict state is a reject, not a nitpick.
- **Saving claims are measured, not estimated.** A PR claiming a quota, latency,
  or cost saving must carry the five items AGENTS.md requires ("A claimed saving
  must be measured"): a number with units and a baseline (`X → Y pts/hr`), a
  measurement against the running system or a census of real data — never
  derived from the code; `aiur github-cost` gives per-caller points, calls, and
  rate, and the local ledger plus the App-token `/rate_limit` give the
  credential-side view — what must be true at merge for the saving to occur, a
  test asserting the claimed figure, and a count of the population the change
  will meet in production. Verify that last one yourself: **check the
  population, not the mechanism.** Before judging whether a
  cache/classifier/cadence change is correct, count what it will actually see in
  production. #2360's classification was observability as first reviewed (it
  saves reads only since a later revision added TTLs) and it satisfies the other
  four items, #2399's shipped configs left every `polling.intervals` gate
  commented out, and #2417's validator almost never fires — successive censuses
  found 0 of 462 and 1 of 99 stored bodies with its shape. All three passed a
  mechanism-only review and measured zero. An instrumentation PR should claim no
  saving at all; if it does, that is the finding.
- **Mutation-testing discipline, explicitly.** Require the agent to check whether
  each new test still passes with the production change reverted, and to **name
  any test that does**. This is what separates a review from a summary. It has
  repeatedly found tests that assert pre-existing behaviour: a `%{}` pattern that
  matches any map, a vacuous global-pause test, an assertion pinned to a constant
  the change never touches. The author-side rules that move these checks before
  review — the unknown-path, computed-age and collapsed-cause rules — live in
  the repo's `AGENTS.md` (`Tests must fail without the production change they
  guard` and `Computed ages and collapsed causes`); cross-reference those
  sections rather than restating them, so the reviewer's check is a formality,
  not the first time it is performed.
- **Local tests evidence.** Compare `Policy`, `Tested head`, `Base`, `Selection`
  and command results with the diff and `aiur status` policy; stale SHAs, unsafe
  selection or unrun/failed commands are blocking, even if the body gate passes.
- **The test-run hazard.** `mix test test/some_dir/` silently excludes
  `test/aiur/*.exs` one level up. Require the exact command run to be reported.
- **Worktree isolation** (`isolation: "worktree"`) whenever the agent may rebase,
  push, or run a mutation. Two agents in one checkout is a data-loss bug: one
  `git reset --hard` destroyed another agent's uncommitted work.
- **Instruction not to post to GitHub.** The agent returns text; you post the
  review under the merge identity. Keep authorship and authority in one place.

Review **coupled PRs together in one agent**, not separately. Two PRs touching
the same seam can each be sound and still be incoherent merged — and the trap is
that the production files conflict while every test file auto-merges cleanly, so
the resolver sees no markers and inherits a mutually unsatisfiable suite. Ask
explicitly for a merge-order recommendation.

Do not relabel by hand after a `CHANGES_REQUESTED` review. The review webhook
and poll both publish `ticket.<id>.pr.review_comment`; `CommentWake` writes
`agent:rework` (add before remove) and delivers the review to a live worker. A
hand relabel only repeats that write and spends shared GitHub core budget. (The
2026-10-15 `dispatch-declined` on #4570/#4566 came from a budget hold on the
rework claim, not the relabels; #4646.) Verify the ticket left
`agent:human-review`/`agent:ci-wait` for `agent:rework`. If not, fix what the
`review_rework_refused` alert names (often: re-review the current head). With no
alert, run `aiur executor-sweep` (#4620) and grep the daemon log for `Rework
dispatch claim failed` or `writer=comment_wake` before you touch a label.

Before relabeling on a wake, read the issue's current labels and skip the
relabel if the ticket has already moved on. A
`ticket.*.agent.handoff.human_review` wake says the agent handed off, not that
the ticket is still there: when CI is pending the daemon moves it to
`agent:ci-wait` within minutes. Swapping `agent:human-review` for
`agent:rework` from that stale wake leaves `agent:rework` + `agent:ci-wait`,
and dispatch authorization refuses the pair (#5796). When you do relabel, make
two sequential calls: add the new state label first, then remove the old one.
`gh issue edit --add-label X --remove-label Y` runs both mutations concurrently
and is not atomic, so do not combine them.

## Pull-request review loop

Branch freshness is an owning-worker responsibility. A pull request reaches
review-ready state only when all of these are true:

- its `baseRefName` is the configured integration branch or an Aiur-verified open, unmerged direct blocker's head branch (stacked PRs require integration retargeting before merge);
- the current remote base head is an ancestor of the exact PR head;
- fresh CI for that exact head has passed the required gate.

If any condition fails, send one bounded update/re-cut directive to the owning
ticket and let its agent fetch, integrate or re-cut, resolve semantic drift,
validate, and push. Do not assign reviewers against the stale head. If the
bounded attempt does not materially converge, apply the [takeover rule](driving.md#convergence-escalation-and-takeover)
instead of issuing the same directive indefinitely. Once all conditions hold:

1. reserve or rebalance capacity for multiple independent background reviewers;
2. diff the pull request body's claims against the diff **first**. Any claim the
   diff does not support is a P1, never a nitpick; this is the most common
   defect class by a wide margin — a transport described as feature-complete
   whose `sendFeatureReport` unconditionally throws, a design document whose
   stated colour derivation is arithmetically impossible, a "fix" that never
   reads the config it claims to. Six of the nine pull requests rejected in the
   2026-07/08 run failed on exactly this, and every one of them would have
   merged on a skim. A body edited *down* toward a thinner diff is the same
   defect wearing a disguise: the capstone pull request was quietly retitled
   from "driven by live fleet state" to "runbook and evidence framework" and
   marked done while the page still rendered invented data;
3. answer two questions about every new test, in this order — **does this test
   execute at all**, and **would it still pass against a trivially wrong
   implementation?** The first is the one reviewers skip, and it is not cheap to
   skip: twenty tests sat outside the `vitest` include glob for 5.8 hours while
   their pull request read as fully tested, because a test the runner never
   collects reports no failure. Require the runner's own output naming the test
   file, not the file's existence in the tree. For the second, the real examples
   are `f(x) === f(x)` assertions, a test hand-poking the same
   `:persistent_term` the broken wiring should have set, and tests asserting
   against an inlined *copy* of the code under test that stayed green after the
   real code was deleted. On the same principle, the author-side rules that move
   these checks before review — the unknown-path, computed-age and collapsed-cause
   rules — live in the repo's `AGENTS.md` (`Tests must fail without the
   production change they guard` and `Computed ages and collapsed causes`);
   cross-reference those sections rather than restating them;
4. check `Local tests`: policy matches `aiur status`, `Tested head` is current,
   `Base` and `Selection` cover the diff, and command results prove what ran;
   stale, incomplete or failed evidence blocks approval. Use `ce-code-review`
   when available, adding the relevant security, data, frontend, backend or
   design lens for the change;
5. reconcile duplicates and contradictions, classifying each finding under the
   convergence policy before routing it;
6. return contained findings to the existing ticket as rework; create a new
   ticket only for an independent P0/P1 feature blocker;
7. confirm the event bus or tracker transition wakes the owning agent and that
   it acknowledges the rework. Submitting is not landing: re-read the observable
   state after every mutation — `reviewDecision` for the review itself, the
   label set for a transition, the thread's latest comment for a reply — because
   a verdict issued as a turn ends can be lost with the request still in flight
   and nothing reports the loss. Six review verdicts vanished this way in one
   run;
8. require the worker to restore the same branch-freshness and CI gate after
   fixes, rerun targeted review, then apply the recorded merge policy.

If tooling or an explicit resource limit prevents parallel review, record the
degraded review and compensate before merge. Do not equate green CI with
feature acceptance. The integration/capstone owner must still produce the
evidence named by the planning handoff.

### Merge mechanics

Branch protection measures the identity of the **pusher**, not the commit
author, and `require_last_push_approval` evaluates the last **reviewable** push.
The authenticating token determines the pusher; the URL username and commit
author do not. Never embed a token in the remote URL. Use the fail-closed helper
recipe in `../../aiur-agent/dev-loop.md`, which resets inherited GitHub credential
helpers before supplying `GITHUB_TOKEN`, and open agent PRs with the agent
identity — GitHub counts the PR **opener** for self-approval, not the commit
author. Tree-identical empty commits do not replace an earlier reviewable-push
attribution.

If a current human approval and green checks still leave a PR `BLOCKED` and
`REVIEW_REQUIRED`, follow the diagnostic recipe below: after the first ordinary
merge refusal, read the failed rule suite with the operator-only credential and
emit GitHub's exact active-rule detail as a `merge.rule-violation` alert. Do not
use `--admin` as a diagnostic probe. Before every merge run `scripts/check-stack-order.sh <pr> <owner/repo> --repo-dir <clone>` (`merge-order-gate.md`); any exit other than 0 means do not merge.

Read `aiur status` for the active `merge_policy`; do not inherit a CI rule
from memory or a reviewer brief. Merge only with
`aiur pr merge <N> --reviewed-sha <full-reviewed-head-sha>`; never substitute
`gh pr merge`, `--admin`, or a scratch script. The command rechecks policy,
current-head approval, failed checks, full-CI exceptions and queue requirements.
With `ci: wait`, wait for every required check on that head. With `pending_ok`,
pending checks may proceed only on reviewed `Local tests` evidence for that
head and the configured local-test mode, with main watching enabled; failed
checks and full-CI labels/paths still block. Refusals are not bypass authority.
On `system.main.ci.failed`, inspect the watcher’s fixer ticket and progress;
do not repair main by hand unless the fixer is stalled and takeover is authorized.

Branch protection measures the identity of the **pusher**, not the commit
author, and `require_last_push_approval` evaluates the last **reviewable** push.
The authenticating token determines the pusher; the URL username and commit
author do not. An inline helper is additive unless the helper list is reset, so
it can silently fall through to the Executor's cached `gh` credential. A
token-bearing URL is both unsafe and ineffective as an after-the-fact repair:
the #1401 experiment used the agent token, but pushed only tree-identical empty
commits, which did not replace the earlier human reviewable-push attribution.
Use the fail-closed recipe in `../../aiur-agent/dev-loop.md` from the first real push,
and open worker pull requests with the agent identity; GitHub counts the PR
**opener**, not the commit author, when deciding self-approval.

When required checks are green and a current CODEOWNER approval exists, but
GitHub still reports `mergeStateStatus: BLOCKED` and
`reviewDecision: REVIEW_REQUIRED`, do not spend another review or use
`--admin` as a diagnostic probe. After an ordinary merge/queue attempt produces
GitHub's generic policy error, fetch the read-only rule-suite evidence:

```bash
<loaded-aiur-run-skill>/scripts/diagnose-pr-merge-gate.sh <pr-number> <owner/repo>
```

The rule-suite endpoint requires repository Administration: read. The helper
uses `AIUR_CI_READINESS_TOKEN` when present, otherwise the operator's `gh`
keyring with `GITHUB_TOKEN`/`GH_TOKEN` overrides removed; it never gives that
authority to the daemon or worker token. It correlates the failed suite to the
pull request's generated merge commit and prints GitHub's exact active-rule
`details`. When it succeeds, immediately emit an Executor-facing alert with
that output verbatim:

```text
emit_alert(
  name: "merge.rule-violation",
  message: <exact diagnostic output>,
  reason: "PR #N is green and approved but GitHub still blocks the merge",
  needs_attention: true,
  severity: "critical"
)
```

If no suite matches, report that the exact diagnostic is unavailable; do not
invent a GitHub message. The normal attempt is what creates the failed suite,
so this path surfaces the reason immediately after the first refusal instead of
requiring a second `--admin` attempt.

Read the active `merge_policy` from `aiur status`, not memory or a reviewer
brief. Before every merge run `scripts/check-stack-order.sh <pr>` (see
`merge-order-gate.md`), then use only
`aiur pr merge <N> --reviewed-sha <full-reviewed-head-sha>`.
Never replace it with `gh pr merge`, `--admin`, or scratch scripts.
With `ci: wait`, all required checks must pass on the reviewed head.
With `pending_ok`, reviewed local-test evidence for that head and configured
mode plus enabled main watching may permit pending CI; failed checks and
full-CI labels/paths still block. Respect command refusals and queue routing.
On `system.main.ci.failed`, inspect the watcher’s fixer ticket and progress.
Do not fix main by hand unless the fixer is stalled and takeover is authorized.

### Ticket close-out

Before closing a ticket, grep for deferred-work markers naming it —
`git grep -n "Follow-up (#<N>)"`. That is the house convention because
`credo --strict` in `make lint` forbids `TODO`, so the codebase has zero TODO
tags and these markers are the only greppable record of work a ticket deferred.
If one still names the ticket, either the deferred work lands first or the
marker is re-pointed at a successor ticket that is open. **Never close a ticket
while live markers still name it.** #1350 closed with `Follow-up (#1350)` still
live on a hardcoded fixture in `streamdeck_live.ex`; two days later the capstone
proof failed because the page it named still rendered invented data. The marker
was correct and greppable — nothing read it.

Before closing a ticket, grep the codebase for deferred-work markers naming it:

```bash
git grep -n "Follow-up (#<N>)"
```

`Follow-up (#<N>)` is the house convention because `credo --strict` in
`make lint` forbids `TODO` tags — the codebase has zero of them, so these
markers are the only greppable record of work a ticket knowingly deferred. When
one still names the ticket being closed, resolve it first: either the deferred
work lands, or the marker is re-pointed at a successor ticket that is open.
**Never close a ticket while live markers still name it.**

The 2026-07/08 analytics-streamdeck run shows the cost. `streamdeck_live.ex`
carried `Follow-up (#1350)` on a hardcoded fixture, `preview_key_descriptors/0`,
which #1350's key-content model was meant to replace. #1350 closed; nobody wired
it. Two days later the build order's capstone proof (#1358) failed: it required
the emulator be "driven by live fleet state", and that was structurally
impossible because the page still rendered invented data with no PubSub
subscribe and no `handle_info/2`. The marker was correct, greppable, and named
the exact ticket — there was simply no check that read it.

The reviewer's tell arrived before the proof did: the capstone PR title had
drifted from "driven by live fleet state" to "runbook and evidence framework".
When a proof ticket's title slides from proving behavior to documenting it, the
behavior is usually still missing.
