# Build Order Executor Handoff

## Live Executor state (updated 2026-07-13 19:48 PDT)

You are the **Executor**: you run Aiur to implement this feature, make every
PR merge-ready via review, do the merging, keep agents genuinely working, and
act as the fallback when an agent cannot finish its last mile. Everything
below this section is the binding contract; this section is the current live
truth and supersedes stale pre-run wording later in the document.

**State right now:** planning approval remains frozen at
`4d8de9508206e08e314f2730cd916501a3b4cafd`; the complete graph is live at root
#1084 with 54 members #1085–#1138 and 107 exact blocker relations. Skills PR
#1065 was reviewed at `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and
squash-merged to `main` as `ed1846c4bc76d4657095da57951a0dbf3e914c3d`.
Receipt finalization exposed a contained authority-loader defect after the
successful idempotent publication; the operator explicitly overrode that gate
for this run on root comment
`https://github.com/its-everdred/aiur/issues/1084#issuecomment-4964521448`.
Because execution has now legitimately mutated issue lifecycle state, the old
OPEN publication snapshot is historical evidence and must not be presented as
a fresh executable receipt.

Aiur is running against current `main` from an isolated Executor checkout.
Phase 1 has five dependency-ready Terra workers: #1086 BO-004, #1087 BO-008,
#1088 DASH-006, #1089 DASH-017, and #1090 DASH-018. The initial cap of five
matched the graph's ready width; it is not a program ceiling. At every readiness
transition, set concurrency toward the full ready width when measured CPU,
memory, file-descriptor, build-gate, serialization, and model capacity permit.
After a contained restart, only those five BO tickets are routable. The load
controller restarted at an effective width of two and admitted #1086 and #1087;
the configured/session cap remains five and must ramp toward every ready ticket
as measured load permits. At this snapshot load is 3.86 with 23 GiB available,
so the controller—not an arbitrary Executor cap—is the remaining admission gate.

**Current operating decisions:**

1. Use explicit `progress.checkin` events as the percentage authority. Workpad
   checkboxes are useful planning evidence but are not the live progress meter.
2. Replace unconditional five-minute model wakes with an adaptive shell wait:
   wake immediately for attention, agent-state, PR/CI, daemon, stale-log, or
   unchanged-progress/thrash signals; otherwise force a health audit after a
   quiet ceiling. Start at 10 minutes, bound it to 2–20 minutes, shorten after
   an intervention, lengthen after repeated no-action audits, and retain a
   wake/outcome history so later phases tune thresholds from evidence. A user
   check-in always interrupts the wait.
3. Keep `docs/build-order/plan-preview.html` current at meaningful execution
   snapshots and every phase boundary. Show actual event-reported percentages
   while work is active and verified/merged truth when a phase closes; avoid
   committing a new snapshot for every uneventful local poll.
4. Diagnose reproducible Aiur defects and file them, then apply two gates before
   activation: the work must be authorized/in-boundary (or a direct P0/P1
   blocker), and measured CPU, memory, build, serialization, and agent-slot
   headroom must exist. Otherwise schedule it for a later phase without
   `agent:todo`. Issue #1140 records the tracked per-workspace Hex cache defect;
   it is deferred because Phase 1 currently has no compute or slot headroom.
   Issue #1142 owns permanent adaptive-monitoring and resource-triage skill
   delivery after this multi-phase run supplies tuning evidence; its prototype
   is active operationally but it also has no dispatch label.
5. Maintain this handoff whenever an operator directive, execution override,
   capacity decision, discovered blocker, or validation authority changes.
6. The prewarm base currently equals live `origin/main` at `e27e96db`. Although
   `prewarm.poll_seconds` is zero, each tracker dispatch cycle calls
   `RepoBase.refresh_async/0`; after every merge verify the base fetches,
   rebuilds, and reaches the new `main` before newly-ready dispatch begins.
7. At 19:13 PDT the adaptive watcher caught #1088's operator-decision alert:
   PR #1144 had opened against legacy `v2`, producing 429 unrelated files.
   The Executor auto-retargeted it through the REST API to authorized `main`,
   reducing the diff to 12 files, recorded the decision on #1088, and messaged
   the worker to rerun scoped validation and resolve the attention. This is the
   canonical response when a branch is based on current `main` but GitHub PR
   creation inherits the repository's legacy default base.
8. The same defect reproduced on PRs #1143/#1086 and #1145/#1087. Both were
   REST-retargeted to `main` and reduced to scoped 13-file and 23-file diffs;
   the workers retain their real lint/browser-test rework. P1 issue #1146 owns
   a durable fix that carries `tracker.base_branch` through agent PR creation.
   It has no dispatch label while CPU, build slots, and all five agent slots
   are saturated; the Executor auto-retargets any recurrence and may activate
   #1146 only in genuine spare capacity without displacing ready critical-path
   work.
9. At 19:23 PDT the Executor found the concrete override: both live configs
   already said `tracker.base_branch: main`, but the dogfood `.aiur/hooks`
   fetched/checked out/merged hard-coded `v2` and `.aiur/prompt.md` explicitly
   instructed agents to open PRs against `v2`. Both live copies were corrected;
   hooks now consume injected `THIS_BASE_BRANCH` with a `main` fallback. The
   isolated fix was shell-validated and pushed directly to `main` as
   `e27e96db7d5326d5744ec5bcca40ce32b0d8812f`. The running prewarm checkout
   then fetched/reset to that SHA and rewrote `.aiur-base-built` after the
   commit timestamp, proving refresh plus rebuild on a live `main` advance.
   Keep #1146 open until the next agent-created PR targets `main` without
   intervention; do not claim automatic wrong-base repair from configuration
   inspection alone.
10. At 19:34 PDT a controlled restart proved that startup removes durable
    `agent:paused` labels from active-state tickets via
    `PauseResume.recover_startup_pause_override/2`. Deferred #1032 and #678
    immediately consumed two Sol turns, displacing BO rework; #99, #728, and
    #1030 were exposed to the same defect. P1 #1148 records the contradiction
    with the documented pause contract. Run containment removed active-state
    labels from all five deferred tickets while retaining `agent:paused`, then
    restarted cleanly; do not restore their active-state labels during this
    bounded feature run. The local dashboard is healthy on `127.0.0.1:4000`;
    direct non-loopback binding correctly refused to start without basic-auth
    credentials, and adding a Tailscale Serve listener requires host sudo. The
    separate progress prototype remains reachable on the existing Tailscale
    listener at port 4180.
11. PR #1145/#1087 reached a clean all-green head, then two independent
    Executor reviews converged on five contained BO-008 gaps: no authenticated
    navigation proof, a transform-only performance primitive, unsanitized
    binary browser artifacts, no CI invocation of the failure-evidence
    verifier, and recursive cleanup of a caller-owned artifact directory. The
    deduplicated review is recorded at
    `https://github.com/its-everdred/aiur/pull/1145#issuecomment-4964932068`;
    #1087 returned to `agent:rework` rather than merging a green-but-incomplete
    harness. Keep all fixes on #1087; do not file five follow-up tickets.
12. At 20:05 PDT Claude refreshed the committed OCC design and plan preview
    with complexity-weighted phase-progress bars. Operator direction assigns
    this only to later-phase #1107/BO-020; it does not alter Phase 1 dispatch.
    BO-020 now points at the prototype `.bo-prog` / `renderBoSummary` reference,
    consumes BO-007 authoritative progress, preserves unknown/stale states, and
    renders `sum(complexity * progress) / sum(complexity)` with color-independent
    accessible text. Analytics is intentionally excluded and cannot become a
    ticket or acceptance dependency. The prototype's CDN-loaded d3 remains
    non-authoritative; production layout stays within BO-009/BO-010's vendored
    platform contract.
13. PR #1147/#1089 reached a clean all-green head, but dual independent review
    found four contained trust/acceptance defects: bare legacy records could
    inject unhashed provenance, new provenance-bearing schema-1 events were not
    compatible with the previous decoder's rollback hash semantics,
    credential-shaped strings could enter allowlisted identity fields, and the
    required store-backed lifecycle/history matrix was incomplete. The
    deduplicated review is at
    `https://github.com/its-everdred/aiur/pull/1147#issuecomment-4965018879`;
    #1089 returned to `agent:rework` and resumed. Keep every fix on #1089.
    At the same snapshot #1086/#1143 and #1090/#1141 are green and in dual
    Executor review, #1088/#1144 is rerunning its failed test, and #1087/#1145
    remains in its existing review-driven rework.
14. At 20:16 PDT the operator added a hard hourly retrospective to the adaptive
    Executor monitor. Immediate event/attention wakes and the adaptive quiet
    ceiling remain in force, but neither resets this independent one-hour due
    time. Every audit records an `action` or `no-action` reason; once per hour
    the Executor reviews the preceding hour's wake/outcome history, identifies
    redundant/no-action checks that a more specific Aiur/event-bus notification
    could replace, and records one small cadence/trigger adjustment or an
    explicit unchanged decision. Do not overfit isolated misses. At BO-015,
    synthesize repeated evidence into at most one or two deferred Aiur
    notification/polling issues under the normal scope circuit breaker; these
    optimizations cannot delay Build Order acceptance. The run-isolated helper
    and durable `/aiur-run` contract are in PR #1150; this run uses stable ID
    `aiur-dashboard-program-20260713` and its first isolated retrospective is
    due at 21:30 PDT.
15. Dual review returned #1086/#1143 to rework for three contained repository-
    identity gaps: ambiguous bare-number API results leaked one arbitrary
    nested identity, noncanonical/contradictory structs could be marked
    joinable, and rate-limit fallback redispatch dropped identity metadata.
    The packet is at
    `https://github.com/its-everdred/aiur/pull/1143#issuecomment-4965070307`;
    #1086 resumed and owns every fix.
16. Dual review returned #1090/#1141 to rework for the provider-account
    generation lifecycle as a whole: authenticated startup did not seed a
    binding, RPC waits dropped lifecycle notifications, subscription and hard-
    teardown boundaries could preserve/cross stale generations, and five
    related continuity/degradation cases violated the ticket contract. The
    single consolidated packet is at
    `https://github.com/its-everdred/aiur/pull/1141#issuecomment-4965072012`;
    #1090 resumed. Do not split these findings into new tickets.
17. Dual review returned #1088/#1144 to rework despite green CI: the default
    query path named the wrong store module, response paging still performed
    unbounded store/metrics reads, partial detail health was hidden, canonical
    counts did not reach the UI, and required property/replay/security coverage
    was absent. The consolidated packet is at
    `https://github.com/its-everdred/aiur/pull/1144#issuecomment-4965131360`;
    keep all fixes on #1088.

At 19:48 PDT the five latest event-reported percentages are BO-004 70%, BO-008
90%, DASH-006 90%, DASH-017 90%, and DASH-018 70% (82% ticket-average). All
five remain unmerged; #1087 is explicitly in review-driven rework and the
other four workers retain their CI/fix ownership. The Executor begins
independent review only when a branch stabilizes and never treats an in-flight
draft or a green build with unmet acceptance criteria as merge-ready.

**Read-first map for this run:** `README.md` (pack index) →
`08-implementation-pointers.md` (verified per-ticket file/module/function
anchors for all 54 tickets — workers start here, and every published issue
links its own section) → `07-graph-parallelism-review.md` (waves, critical
path, serialization cliques) → `09-plan-review-synthesis.md` (review verdict
and accepted recommendations). Day-one width is 5 tickets (BO-004, BO-008,
DASH-006, DASH-017, DASH-018 have no blockers); staff the top fan-out spine
first — DASH-003 (8 dependents), BO-008 (6), BO-004 (5), BO-017 (5), BO-005,
DASH-001, DASH-008 — a stall there starves more of the fleet than anything
else. The serial critical path is BO-004→001→002→003→007→011→012→013→014→015
(amber in the committed plan preview, `docs/build-order/plan-preview.html`);
keep it staffed continuously.

## Start gate (historical contract; explicitly overridden for this run)

The operator-authorized override and live execution state above are now the
authority for this run. Do not attempt to recreate a fresh pre-execution OPEN
snapshot after runtime labels and lifecycle transitions have begun. The
remaining text in this section records the intended immutable ceremony and is
useful for fixing the publisher, but it is not a reason to pause the authorized
Phase 1 workers.

This handoff becomes executable only after the live Build Order root contains a
uniquely marked immutable pending `aiur-build-order-reconciliation` comment and
one distinct canonical successful comment linking a post-publication receipt
whose exact commit contains both valid
reconciliations, both external gates below are recorded as resolved, and the
operator's current conditional run authorization remains in force. No second
approval prompt is required after those conditions pass. Re-run the trusted
final-comment verifier;
neither caller-supplied identity or query JSON, Git object substitution,
imported foreign history, nor a merely local/API-visible commit is a start
gate. The verifier anchors the repository to the configured GitHub origin,
fetches the exact receipt-recorded pending comment ID, rejects malformed or
duplicate reconciliation evidence, and proves approval plus receipt
remain ancestors of the unchanged tip of the frozen branch while separately
proving approval is an ancestor of receipt. It rejects legacy graft entries in
both the worktree and common Git directories, and all authority API reads pin
`github.com` with finite timeouts. The frozen branch ref is
`refs/heads/build-order-research`. Deletion or a force-push that removes
either commit revokes this gate; never substitute `main`, a pull ref, or a tag.
Planning publication does not queue work. Until then, do not run Aiur,
implement tickets, or add `agent:todo`.

The finite authorized boundary is the one consolidated 54-member BO+DASH
graph. Publish and dispatch only those members after the verifier and gates;
every member retains the exact `model:codex-gpt-5.6-terra` label, with no model
substitution.

The immutable receipt and final verifier attest the publication-finalization
snapshot: all 56 issues are open and unlocked, have their receipt-bound
titles/bodies/full labels, the root has exactly 54 children, every
non-root has no children, and all 107 blockers are exact. Run that full verifier
immediately before the first execution mutation. Once the authorized run
begins, later lifecycle changes are legitimate runtime truth and do not rewrite
the receipt: gate resolution may update live issues, the skill-delivery issue
may close, and member issues may acquire `agent:*` labels. Record and resolve both
external gates while the skill issue is still open; only after both gates are
proven may the Executor close the skill issue and dispatch member work. Never close
the skill issue or add dispatch labels first and then attempt to use the now
historical OPEN receipt as though it were a fresh publication snapshot.

## Identity and objective

- Build Order: `its-everdred/aiur:build-order-dashboard`
- Plan version: 1
- Repository: `its-everdred/aiur`
- Researched commit: `9849f32963c2a65367bce565b3f5ede3777c218f`
- Approved planning commit: `4d8de9508206e08e314f2730cd916501a3b4cafd`
- GitHub root: marker-resolved #1084 at pending publication; always re-resolve
  live by the hidden Build Order root marker rather than trusting a copied
  number

Deliver the consolidated 54-ticket program: the authenticated,
GitHub-planning-read-only Build Order feature plus the dashboard companion
members, all direct children of one root (operator decision 2026-07-13).
GitHub owns current plan facts; Aiur owns runtime facts. Linear #1067,
skill-delivery work and deferred findings remain outside the root and cannot
change this run's 54-member denominator or ETA.

## Required startup

1. Read these repository-relative paths in order:
   - `docs/build-order/README.md`
   - `docs/brainstorms/2026-07-12-build-order-requirements.md`
   - `docs/build-order/05-technical-decisions.md`
   - `docs/build-order/build-order.json`
   - every `tickets[].document` path in
     `docs/build-order/build-order.json` (BO-001 through BO-020 under
     `tickets/` and DASH-001 through DASH-034 under `companion-tickets/`)
   - `docs/build-order/validation-report.md`
   - `docs/build-order/github-publication.md`
2. Use `/aiur-run`, not the retired `/aiur-loop` workflow. Require reviewed
   PR #1065 source head `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and
   squash-merged `main` commit `ed1846c4bc76d4657095da57951a0dbf3e914c3d`
   to be recorded, and verify the landed skills preserve multi-prefix
   validation, finite-boundary, review/rework, circuit-breaker, and publication
   rules. A matching skill name without the recorded authority is insufficient.
3. Write a three-to-five-sentence `/goal` stating that you are the Executor,
   the finite acceptance boundary, granted issue/merge authority, critical-path
   priority and terminal condition.
4. The receipt-bound full live verifier was superseded for this run by the
   explicit root override recorded in the live-state section. The Executor
   re-queried repository instructions, set the isolated operator config to
   `tracker.base_branch: main`, and verified current integration truth before
   dispatch. Never use planning JSON as fresher live GitHub truth.
5. Queue only approved members of the consolidated root under explicit user
   authority. The shared
   predecessor baseline is recorded as resolved (`origin/main` at
   `9849f32963c2a65367bce565b3f5ede3777c218f`), and any ticket-specific
   provider gate (GATE-003 on DASH-019, GATE-004 on DASH-013) must still be
   resolved before those tickets are pickable.

## External pre-dispatch gates

- **GATE-001 — integration baseline (RESOLVED):** the predecessor OCC run is
  complete and the baseline is resolved — `origin/main` at
  `9849f32963c2a65367bce565b3f5ede3777c218f` contains closed #1034 plus every
  accepted OCC successor. Record that resolved branch and SHA on the live
  root; do not silently implement against any earlier snapshot.
- **GATE-002 — Executor skill:** record reviewed source head
  `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and landed `main` commit
  `ed1846c4bc76d4657095da57951a0dbf3e914c3d`, then confirm `/aiur-build`,
  `/aiur-run`, and `/aiur-monitor` are discoverable. The separate human
  skill-delivery issue remains outside the Build Order denominator.

GATE-001 and GATE-002 are resolved for execution; the skill-delivery issue was
closed under the operator's explicit receipt override before Phase 1 dispatch.
BO-004 and BO-008 are the independent initial nodes. BO-001 follows BO-004.

Record GATE-001's resolution and resolve GATE-002 before changing the skill
issue from its publication-finalization OPEN state. Close that issue only after the
installed bounded skill is proven, and only afterward add dispatch state to
ready BO issues under the user's execution authority.

## Authority map

- GitHub: root/member identity, title/body, planning labels, lifecycle/state
  reason and native blockers.
- Aiur: running/queued/retry/paused state, progress, active agent stage, alerts,
  events and latest evidence.
- Planning pack: approved requirements, technical decisions, ticket contracts,
  initial scheduling/conflict metadata, validation and finite boundary.
- Executor: current readiness/capacity, review/rework routing, merge policy
  under authority, recovery, status and final proof.

Unknown/stale provider data never becomes empty, ready, successful or zero.
Aiur progress, including 100%, never clears a GitHub blocker.

## Initial graph and capacity

After both external gates resolve, start BO-004, BO-008, DASH-006, DASH-017,
and DASH-018 in parallel. BO-001
and BO-017 follow BO-004. BO-002 follows BO-001; BO-003 follows BO-002; BO-005
follows BO-017. BO-003, BO-005, BO-016, and BO-019 serialize on the
application-supervision seam wherever hard dependencies do not already order
them; BO-005 also serializes with DASH-029 on observation-envelope
consumption. BO-006 follows BO-005. BO-007 follows BO-001, BO-003, and BO-005.
BO-009 follows BO-001 and BO-008; BO-010 follows BO-008 and BO-009. BO-016
follows BO-004 and owns configured-repository ticket detail. BO-019 follows
BO-005 and owns bounded sanitized recent history. BO-018 follows BO-008,
BO-016, and BO-019 and owns accessible base context. BO-011 follows BO-007 and
BO-018 and adds Build Order relationships and truthful destination links.
BO-012 follows BO-003, BO-007, BO-010, and BO-011; BO-013 follows BO-008 and
BO-012; BO-014 follows BO-008 and BO-013. BO-020 follows BO-003 and BO-012 and
serializes with BO-013/BO-014 on the shared Build Order route surface. BO-015
follows BO-006, BO-014, BO-020, DASH-023, and DASH-033.

The DASH members carry the same in-graph serialization: DASH-001 with BO-012
on the OCC route/navigation shell, DASH-023 with BO-013/014 on the Build
Order route surface, and
DASH-029 with BO-005. DASH-018/019 serialize on the Claude process-lifecycle
adapter. DASH-004/019 depend on BO-004's configured-repository identity. The
eight supervised member services—DASH-002/009/012/018/019/024/025/026—also
declare every independently ready serialization pair
against BO-003/005/016/019 on the central application supervision tree. Hard
dependencies already order the omitted pairs.

Derive current readiness from GitHub native blockers, ticket lifecycle,
declared serialization and real capacity. Phase is only a rollout/display hint.
Maximize progress against ready critical-path work, not raw active count. Do not
activate deferred findings to keep slots busy.

## Review, rework and convergence

- Review each PR against its issue contract, decisions and current base. Use
  parallel independent code review where useful.
- Return a contained finding to the same ticket/worker through rework and the
  event bus. Do not multiply tickets to preserve PR momentum.
- Promote a new issue only for an independent P0/P1 acceptance blocker. Record
  P2/P3 and optimization evidence in the deferred ledger.
- At each status interval compare completed versus created/promoted work. If
  promotion exceeds completion, freeze further promotion until the original
  feature lands.
- Keep branches current, CI green and shared-write work sequenced. Merge only
  under the user's current authority and repository policy.

Report two tracks separately: bounded Build Order critical path/count/ETA, and
reliability/optimization findings as active only when separately authorized or
otherwise deferred. Deferred work cannot consume critical-path capacity or
prevent completion.

## Operational playbook (field-proven in the OCC run)

These patterns come from the predecessor dashboard run that shipped the OCC
wave; the full version lives at
`docs/operator-control-center/EXECUTOR-HANDOFF.md` on branch `occ-planning`.

- **Merge gates, every time:** verify the PR's `baseRefName` is the
  configured integration branch before merging (agents build stacked PRs — a
  mis-based squash lands in the wrong branch silently), and run
  `git merge-base --is-ancestor origin/<base> origin/<branch>` (a green PR
  can be green against a stale base). Merge with `--squash --admin`; the
  known seed-dependent SlotPolicy flake (#506) is mergeable-past when
  build/lint/dialyzer are green. Closing merged issues is manual.
- **Unstick with a message, not resume:** a paused/idle worker that is not
  converging (frozen HEAD, no file edits, not load-throttled, not
  attention-flagged) needs `scripts/aiurdev message <id> "<directive>"` to
  inject a real turn; resume alone re-pauses. Post durable directives as
  issue comments — message-queue text is lost on restart.
- **Finalization wedge:** a worker that committed but never pushes gets its
  work pushed by you from its workspace once the tree is clean; its own later
  push becomes a no-op.
- **Hand-fix the last mile in a worktree:** when nudges fail on lint/dialyzer
  or a small must-fix, take over — always in a fresh `git worktree`, never
  the main working tree (it holds the live `.aiur/config`) and never a live
  agent's workspace mid-edit. Verify Elixir edits with
  `Code.string_to_quoted!/1` and run `make lint` before pushing.
- **Restarts are branch-safe:** the checkout logic re-fetches an existing
  remote ticket branch, so recycling a wedged worker (bloated thread,
  CI-poll loop) loses only the unproductive turn, never committed work.
- **Old-branch skill-path collisions:** an older ticket branch can collide
  with turn-injected skill paths when merging the newly landed skill commit.
  Pause that worker, clean only artifacts verified as injected, merge current
  `main`, restore the tracked tree, and only then resume it.
- **Capacity:** track real CPU (`vmstat` id%), not 1-minute load; the
  observed thrash ceiling is ~8–11 concurrent agents on a 12-core box with
  `max_concurrent_builds: 2` as the true protector. Ramp `set max-agents`
  into measured idle, not optimism.
- **Review discipline:** dual review (correctness + adversarial) on every
  substantive PR, front-loaded in parallel; only `must_fix_before_merge`
  findings block a merge — downgrade the rest to the deferred ledger. Drive
  rework with `gh issue comment` (issue_comment), not `gh pr review`.
- **Hygiene:** commit subjects 3–7 word imperative, no AI/model mentions or
  attribution trailers anywhere; never edit `src/test/aiur/regression/`;
  patch labels via the REST API when `gh issue edit` hits the
  classic-Projects GraphQL error; never paste credentials into files,
  commands, or issues.

## Recovery and Aiur defects

Monitor workers, alerts, Commands, PRs, reviews, CI and machine capacity. First
message/retry or return the owning worker to rework. Take over a critical ticket
only when an Aiur defect or hard operational failure makes that the economical
backstop.

With debug authorization, file a sanitized Aiur issue for a reproducible Aiur
failure. Without it, ask the user first. Always remove credentials, tokens,
private content, account identifiers, environment values, local paths/hosts and
irrelevant source context.

## Terminal condition

Stop only when all 54 members — BO-001 through BO-020 and DASH-001 through
DASH-034 — are implemented, reviewed, green on the
current configured integration branch, merged, documented, cleaned up and
proven after merge.

BO-015 owns the acceptance matrix, real published-root dogfood, synthetic
cycle/invalid/degraded/20/50/100 fixtures and post-merge smoke, and closes the
root only after DASH-033's dashboard-parity proof and the Build Order
acceptance evidence both land. The Executor
runs the canonical real CLI/TUI flow from the Executor repository root because
issue workspaces cannot bypass the `--test` guard. Proof also covers the
authenticated browser, selection/deep links, LKG degradation, live activity,
context/dependency navigation, keyboard/touch/pan/zoom, light/dark/reduced
motion, mobile safe area, 200% zoom and preservation of Units, Commands and
Analytics.

After proof, BO-015 closes the GitHub root with state reason `COMPLETED`. The
loop ends there; it does not continue until every discovered reliability or
optimization opportunity is exhausted.

## Adjacent delivery that must not be lost

PR #1065 delivered the isolated `/aiur-build` and bounded Executor skill
rewrite. Its final reviewed source head is
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f`; it was squash-merged to `main`
as `ed1846c4bc76d4657095da57951a0dbf3e914c3d`. Record both commits and verify
the landed skills before dispatch. Never merge mixed research PR #1064 merely
to recover skill files already present on `main`.
