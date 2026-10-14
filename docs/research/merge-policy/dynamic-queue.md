# Dynamic merge-queue tuning: decision and scope

Research for #4280, dated 2026-10-11. No production implementation or live ruleset write. Includes the operator's reusable-component addition from the issue comment.

## Decision

Build a small standalone recommendation package and an Aiur observation/status adapter. **Default mode: `recommend`**, with `off` available; defer `apply` until a measured trial and a separate credential/security decision. Recommendation mode can explain congestion without granting a worker or the existing daemon App Administration permission.

Keep the operator's current setting for the observation trial: minimum merge entries 3, wait 10 minutes, maximum merge entries 5, build concurrency 5, HEADGREEN. This is a provisional starting point, not a measured optimum. Do not promise that it reduces merge-group CI runs. An operator can choose minimum 1/wait 0 for latency-sensitive work after inspecting the recommendation.

The key correction: **merge limits do not combine merge-group builds**. GitHub builds cumulative queue prefixes; the minimum/maximum merge limits govern landing tested entries. Raising the minimum can amortize downstream main-push/deployment activity, but does not mean one Actions run validates exactly that many PRs. Build concurrency controls speculative checks separately. [GitHub queue semantics](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue).

## Evidence and reproducible queries

All measured figures below use UTC half-open windows. Cutoff is **2026-10-11T17:14:00Z**. Before: `[12:34,16:34)`; after: `[16:34,17:14)`, on that date. Cohorts are assigned by run creation time; landing counts are assigned by merge time. These are different populations.

The companion [evidence.json](evidence.json) stores the selected run, PR, timeline and job fields used in this census. It avoids depending on host scratch files or changing API results. Queries ran during this research turn; job/timeline records read later are filtered back to the cutoff. It is a research snapshot, not a new collector or production telemetry subsystem.

Query identifiers used by every measured figure:

- **Q1 — Actions runs:** `gh api 'repos/aiur-team/aiur/actions/runs?event=merge_group&created=2026-10-11T12:34:00Z..2026-10-11T17:14:00Z&per_page=100' --paginate`. Filter `name == "ci"`, queue branch targeting main, and half-open creation windows. Count distinct run IDs; attempt count is recorded separately. The response fits one page and every run has attempt 1.
- **Q2 — landed PRs:** `gh api 'repos/aiur-team/aiur/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=P'` for P=1 and P=2. Filter `merged_at` into the windows. Both pages contain 200 closed PRs; the oldest update is 2026-10-09T16:19:54Z, before the census begins. A merged PR cannot have an update older than its merge, so this covers the landing window. Join `merge_commit_sha` to Q1 `head_sha` for exact tip attribution, with merge time before cutoff.
- **Q3 — queue timelines:** one `gh api graphql -f query=...` with `repository(owner:"aiur-team",name:"aiur")`, aliased `pullRequest(number:N)` for the union of PR numbers parsed from Q1 queue branches and Q2 window landings. Select `number`, `mergedAt`, `timelineItems(first:100,itemTypes:[ADDED_TO_MERGE_QUEUE_EVENT,REMOVED_FROM_MERGE_QUEUE_EVENT,MERGED_EVENT])`, nodes' `__typename`, `createdAt`, removal `reason`, and `pageInfo.hasNextPage`. All connections report false. The exact query is stored in evidence.json.
- **Q4 — job waits:** `gh api 'repos/aiur-team/aiur/actions/runs/R/jobs?per_page=100'` for each Q1 run ID R, latest attempt. Each response fits one page. Retain jobs with a nonzero `runner_id` and `started_at` before cutoff; wait is `max(0, started_at - created_at)`. This includes dependency scheduling and dispatch overhead, so call it job scheduling wait, not pure runner saturation. Exclude unassigned jobs, whose wait is censored. Quantile is sorted index `floor(0.9*(n-1))`; median averages the middle pair.
- **Q5 — live settings:** read-only `gh api repos/aiur-team/aiur/rulesets/16519832` during the turn; observed minimum 3, wait 10, maximum merge/build 5/5, HEADGREEN, SQUASH and check timeout 360 minutes. The checked-in `docs/security/main-merge-queue-ruleset.json` instead declares minimum 1/wait 0; all other listed fields agree. The switch time 16:34Z is the operator report in #4280, not inferred from Actions.
- **Q6 — operator baseline:** Executor `meta/20261011T1540Z-hourly.md`, “Merges” and “PRs”: reports 83 merges since 00:52Z, rounded 5.6/hour at 15:40Z, and 44 approved PRs among 86 open at that census. Approval count is not a count of green, conflict-free, eligible heads. Those baseline figures are historical operator observations, not recomputed by Q1.

Observed counts and timings:

| Metric / source | Before | After |
| --- | --- | --- |
| Duration / window definitions | 4 hours | 40 minutes |
| Created merge-group runs / Q1 | 22 | 2 |
| Run conclusions at cutoff / Q1 | 15 success, 2 failure, 5 cancelled | 0 terminal, 2 incomplete |
| PR landings / Q2 | 13 | 3 |
| Landings/hour / Q2, window duration | 3.25 | 4.50 |
| Landing count / created run count, descriptive only / Q1+Q2 | 0.591 | 1.500 |
| Successful run tips exactly matching a landed PR SHA / Q1+Q2 | 15 of 15 | Not yet observable |
| Final queue-entry-to-merge median / Q3 | 34.43 minutes, 13 PRs | 40.15 minutes, 3 PRs |
| Non-merge queue exits in sampled timelines / Q3 | 5: 4 manual, 1 merge_conflict | 0 |
| Started assigned jobs / Q4 | 334 | 24 |
| Job scheduling wait median / Q4 | 4.19 minutes | 7.41 minutes |
| Job scheduling wait p90 / Q4 | 15.72 minutes | 16.30 minutes |

The after landings are #4267 at 16:34:34Z, #4271 at 16:56:00Z and #4274 at 17:04:54Z (Q2). Their runs began at 16:02:46Z, 16:16:08Z and 16:21:42Z respectively (Q1): **all were built before the switch**. Thus the after ratio is not PRs per successful new batch, and the rate change is not evidence of a tuning benefit.

For Q1's before creation cohort, all 15 successful tips match distinct landed PRs by the cutoff (Q2); 12 landed within the before window and 3 afterward. The remaining before-window landing, #4242, matches a failed tip: its changes land at the same second as successful descendant #4259, consistent with HEADGREEN cumulative validation. Exact-tip association demonstrates participation, not exclusive group membership; Actions `pull_requests` is empty for every sampled merge-group run.

The before cohort's completed successful-run elapsed median is 31.72 minutes (Q1, creation to updated_at, 15 runs). Its failed runs took 35.38 minutes (38141713316) and 44.72 minutes (38155658609). This is elapsed time to terminal update, not billed runner-minutes. No money or quota saving is claimed.

Sampled non-merge exits (Q3): #4249 manual at 13:03:56Z and 14:16:02Z; #4254 manual at 12:44:03Z; #4256 manual at 14:24:13Z; #3894 merge_conflict at 15:47:31Z. A removal with `reason=merged` is normal landing, even if its timestamp differs slightly from Q2. Cancelled Actions runs are not evidence of ejection or flakiness.

### Measurement limits and next experiment

The timeline census covers 20 PRs represented by the sampled runs/landings, not every PR ever queued. Entries removed before creating a run can be absent. Group membership and exclusive PRs-landed-per-group cannot be reconstructed from empty Actions PR arrays alone. The measured exact-tip match and calendar ratio above deliberately avoid that claim.

The job-after sample is small and right-censored: still-queued jobs do not enter its median. Queue wait measures the final successful entry, not initial approval-to-main or earlier retries. Workflow failure is not necessarily failure of a required check; required-check verdicts must drive recovery. The recorded failure is not automatically a flake.

First follow-up should retain queue-entry identity, ordered member SHAs and required-check outcomes at observation time, plus initial eligibility, retries, runner job creation/start/end and main-push runs. Compare mature creation cohorts before/after a fixed setting over comparable backlog/CI-load periods. Report eligible-to-main p50/p90, PRs/hour, job-minutes per landed PR, rebuilds and non-merge exits. Include the population reaching each rule; no saving claim until measured against real data.

Do not block the design on the short after window, or declare the current setting superior. The historical run/queue data already justify making congestion visible; they do not justify automatic writes.

## What the knobs actually buy

Based on the [queue documentation](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) and [rules API](https://docs.github.com/en/rest/repos/rules):

- `min_entries_to_merge`: holds tested entries for a landing group. A larger minimum can delay a lone green PR and amortize main-triggered work; it does not reduce merge-group run creation by that factor.
- `min_entries_to_merge_wait_minutes`: allows undersized landing after the deadline. It bounds waiting for the minimum, not total CI or queue latency; congestion can exceed it.
- `max_entries_to_merge`: caps simultaneous landing size and downstream deployment exposure. Lowering it does not necessarily stop cumulative candidate builds; a failed prefix can still invalidate descendant candidates.
- `max_entries_to_build`: limits dispatched merge-group builds, not runner jobs. Each workflow fans out into jobs shared with PR and push runs. Higher concurrency may hide CI latency or just create waiting/speculative work that is rebuilt after a failure.
- `HEADGREEN`: requires the combined head of a group to pass required checks. `ALLGREEN` also requires each constituent candidate's checks. Preserve HEADGREEN; a velocity tuner must not change safety policy, required contexts, merge method, bypass actors or check timeout.

A failing required group can eject an entry and recreate successors against a different prefix. Cost depends on active speculative descendants and consumed jobs, not just configured merge size. Q1's failure elapsed times illustrate expensive unsuccessful work; they do not quantify all downstream rebuild cost.

## Reusable package boundary

Proposed standalone Mix package: `packages/elixir/queue_tuner/`, app `:queue_tuner`, facade `QueueTuner`. Follow `packages/elixir/voice_converse`'s `mix.exs`, `lib/`, `test/`, README and `ports/` layout. No Aiur module references, GitHub clients, credentials, application supervisor or network dependency in the core. A different repository or queue provider can use it independently.

Pure facade: `recommend(observation, bounds, previous_state)` returns either a validated recommendation and next state, or a structured invalid-input error. The host supplies monotonic elapsed time and observation identity; the core does not read a clock. Inputs contain eligible backlog, current settings, ordered distinct required-batch results, job-wait window with sample count, freshness/coverage, and a safety hold. Provider IDs remain opaque.

Output contains provider-neutral minimum/maximum landing entries, landing wait and build concurrency, plus reason atoms and supporting observations, validity/age and next controller state. Unknown input yields `hold` with explicit unavailable causes, never a fabricated zero. Bounds and pins are validated at the boundary. The same observation/state replay is idempotent.

Package behaviours define two ports:

- `QueueTuner.Ports.ObservationSource.observe(target, cursor)` returns a complete observation plus next cursor, or a typed unavailable/partial error. Providers own API translation and cumulative group membership; the core does not guess membership from branch names.
- `QueueTuner.Ports.SettingSink.publish(target, recommendation, expected_revision)` publishes advice or applies it according to the host's authorized mode; returns a receipt or typed conflict/denied error. Publishing is not proof that a setting was applied. An apply receipt requires read-back confirmation.

Aiur owns the GitHub observation adapter, read-only recommendation publisher, future privileged apply adapter, `merge_policy.*` schema/accessors, scheduling, daemon-owned persistence/audit and `aiur status` rendering. The package owns only types, ports and pure controller policy/state transitions. Adapters implement package behaviours, depending inward on the facade; package code never imports Aiur.

Add a `components.json` provider component and declared Aiur dependency with the implementation; run the component gate. Package tests run from its own Mix project without starting Aiur. Avoid adding a generic orchestration framework around two behaviours.

## Simple control rule and stability

These values are **proposed control constants**, not measurements. Optimize eligible-to-main latency subject to avoiding speculation; never use raw approvals as eligibility. Eligible means non-draft, approved at the current head, required checks green, correct target, no known conflict and allowed by Executor enqueue policy. Include already-queued eligible entries once.

Start with two healthy landing profiles: latency `(min=1, wait=0)` and backlog `(min=3, wait=10 minutes)`, retaining `max_merge=5`. Enter backlog at eligible backlog ≥6; leave at ≤2; between these thresholds retain the last profile. Initial middle-band state chooses latency. Require three distinct fresh observation windows and a 30-minute dwell for healthy profile changes.

On a **new terminal required-batch failure**, enter recovery `(min=1, max_merge=1, wait=0, builds=1)` immediately, even during dwell. Only two distinct subsequent required-batch successes release recovery; cancelled, unknown or partial results neither count as passes nor trigger recovery. Deduplicate immutable terminal batch identities, including superseded attempts. New failures reset the recovery pass streak once.

Healthy build concurrency starts at the operator's current value, bounded to 1–5. Job-wait p90 ≥10 minutes for three distinct fresh windows reduces builds by one step after the 30-minute dwell. Increase one step only with p90 ≤2 minutes, backlog ≥6 and three fresh windows after dwell. Middle-band or insufficient samples hold. A wait window needs at least 20 started assigned jobs; expose censored jobs separately so this is not treated as a capacity guarantee.

Each window spans 10 minutes; reject observations older than 10 minutes. No decision advances counters just because status was read again. Missing eligibility/membership/verdict coverage holds all settings. Missing runner-wait evidence freezes build concurrency while valid backlog evidence may still change landing profile. A main-red safety hold freezes healthy changes; entering recovery on a proven new failure remains allowed. Pin overrides all transitions.

With constant complete input, backlog cannot satisfy both entry and exit thresholds; runner wait cannot satisfy both high and low thresholds. Dwell and distinct windows prevent polling chatter. Each concurrency change is monotone toward a bound, and a consumed failure cannot repeatedly re-enter recovery. The controller therefore reaches a fixed point under constant input. Changing real traffic or new outcomes can reverse direction; the rule limits that frequency rather than pretending feedback can never change.

Pure tests must cover bounded output; constant-input convergence from every valid state; duplicate/reordered observations; failure replay; two-pass recovery; pins; dwell edges; hysteresis boundary equality; missing/stale input; and invalid bounds. Generate traces across finite profile/backlog/wait classes with ExUnit enumerations, or use an existing package property-test dependency if present. Tests must run with `mise exec -- mix test --max-cases 4` inside the package, without Aiur. Mutation checks replace the clamp, deduplication and hysteresis branches and must fail.

## Proposed config, visibility and authority

This is a proposal, **not supported configuration today**. Implementing tickets must ship reference docs and all annotated templates in the same PR.

| Proposed `merge_policy` key | Default / contract |
| --- | --- |
| `queue_tuning.mode` | `recommend`; accepts `off`, `recommend`; reserve `apply` for the separately approved write feature |
| `queue_tuning.bounds.max_merge_entries` | 5; integer 1–5; recovery minimum is 1; healthy minimum clamps to this cap |
| `queue_tuning.bounds.max_build_entries` | 5; integer 1–5; recovery minimum is 1 |
| `queue_tuning.bounds.max_wait_minutes` | 10; integer 0–10; backlog wait clamps to this cap |
| `queue_tuning.pin` | null; otherwise a complete fixed setting within bounds; publishes pinned reason and suppresses writes |

Keep cadence, streak lengths, observation windows and dwell as versioned package policy constants initially. Do not expose every controller detail as a config knob. Invalid bounds or an incomplete pin fail config validation. `off` performs no tuner-specific reads or writes; recommend uses shared observations and bounded missing-data collection. No hidden operator opt-in is needed to see advice, but stale or unsupported providers report unavailable.

`aiur status` should show mode, observed live settings, recommended settings, reason, observation time, age/freshness, sample completeness and pin. In recommend mode an operator applies a reviewed change using existing repository-admin tooling; Aiur never implicitly invokes it. Config docs belong in `website/docs-app/reference/merge-policy.md` and its configuration index link, CLI output docs in `reference/cli.md`, safety model in the existing security docs.

Changing a repository ruleset requires **Administration write** using an installation token or a fine-grained PAT. [GitHub REST authority](https://docs.github.com/en/rest/repos/rules#update-a-repository-ruleset). Current Aiur App guidance expressly excludes Administration (`website/docs-app/apis/github.md`); do not broaden that App or use an agent credential.

If apply is later authorized, use a separate operator-owned, repository-scoped App with Administration write, isolated in the daemon's credential broker and never inherited by workers. Its installation must be explicitly approved by an administrator. Credential wiring/environment names require their own security design and docs; none are introduced here. Recommendation mode needs no new privileged credential.

Before every future apply: acquire one repository writer lease, re-read the entire ruleset, verify target/invariants and expected revision/hash, alter only the allowlisted numeric queue fields within hard bounds, and journal intent plus old/new hashes and sanitized payload. PUT must preserve every other field. Re-read and compare before recording success, including actor, time, policy version and evidence IDs. Lost responses reconcile before retry; denied or conflicting writes hold and raise attention.

The rules API does not offer a documented compare-and-swap guarantee for this full ruleset update. A local lease cannot prevent an administrator editing concurrently. Require exclusive operational ownership for apply and stop on unexpected drift; this residual race is another reason to default to recommend. Never auto-restore an old full ruleset over a newer human edit. Rollback is an operator-reviewed numeric change.

Operator pin is durable and survives restart; any external unexpected edit also suspends apply pending operator acknowledgment. No tuner path approves PRs, enqueues/dequeues entries, reruns/cancels jobs, changes required checks or bypasses the human merge identity gate.

## Interaction and ticket breakdown

#3892 already supplies schema/accessor, CLI visibility and capability patterns (`Aiur.MergePolicy`, `Aiur.MergePolicyCLI`, provider). Extend those rather than create a second merge-policy section. #3880 owns the human-authorized `aiur pr merge` path: consume its eligibility evidence where available and keep all of its gates. #3881 owns main-watch: consume its base health and inherited-failure evidence; when absent, use explicit unavailable status, not an invented green base.

#4075 repaired exact ruleset drift checking. Its committed minimum/wait currently disagree with Q5; automatic apply would deliberately trigger that guard. Recommendation mode does not require weakening it. Before apply, retain exact checks for safety fields and validate mutable numbers against an operator-approved envelope plus durable actor/receipt evidence. A bounds-only check would silently accept unauthorized manual edits and is insufficient.

Executor lander still owns which feature/fix enters next and all approval/identity rules. It must not adjust queue parameters behind the controller; external numeric edits suspend apply. A tuner cannot make 44 approved PRs eligible (Q6) or cure shared-runner congestion by bypassing CI.

Ticket contracts below are proposed, not newly filed issues; dependencies are implementation ordering, not blockers for this research PR.

| Ticket | Scope and acceptance | Depends on |
| --- | --- | --- |
| DQ1 — queue observation census | Aiur GitHub adapter and daemon-owned bounded ledger; preserve queue members/head/entry identity, typed required outcomes, waits and partial coverage. Add replay fixtures in `src/test/aiur/queue_tuning/observations_test.exs`; reconcile real mature cohorts and report counted population and all metrics above. No ruleset writes or saving claim. | Existing GitHub transport; reuse #3881 evidence when available, with fallback unavailable |
| DQ2 — standalone pure policy | `packages/elixir/queue_tuner/{mix.exs,README.md,lib/,test/}`; facade, two ports, controller and state; component ownership. `test/queue_tuner_test.exs` checks properties/trace scenarios above and isolated mutation failures. No Aiur or HTTP dependency. | None; observation contract agreed with DQ1 |
| DQ3 — recommend integration | Config/accessor/provider/status, pin, bounded scheduling and advice audit; defaults above. `src/test/aiur/queue_tuning/recommendation_test.exs` and config/CLI/provider mirrors cover replay, stale paths and rendered ages. Update schema docs/templates, CLI docs and GitHub read-cost page. | DQ1 + DQ2; extends #3892 |
| DQ4 — fixed-setting trial | Executor-administered trial with counted eligible population and mature windows; compare latency, throughput, consumed job-minutes and failed-prefix rebuilds. Decide whether automatic numeric changes beat manual settings enough to warrant privilege. No software writes required. | DQ3 |
| DQ5 — optional audited apply | Separate admin App/broker, exclusive writer ownership, reconciliation and receipts; drift envelope plus actor verification, pin/kill switch. `src/test/aiur/queue_tuning/apply_test.exs` tests concurrent human edits, denied PUT, lost response and read-back mismatch. Security/docs accompany code; real writes verified only in an explicitly authorized sandbox. | DQ4 approval; DQ3; #4075 guard compatibility; #3880/#3881 integration contracts |

DQ1 and DQ2 may develop in parallel after agreeing the observation contract; DQ3 joins them. DQ4 is the evidence gate. DQ5 is optional and must not be pre-authorized by this document.

## What not to build

Do not build reinforcement learning, PID control, time-of-day prediction, per-feature knobs, a new distributed scheduler, a generic provider plugin registry or an automatic credential escalation. Time of day is a weak proxy for observed traffic and runner wait. Flake rate is useful diagnosis only when a same-head failed attempt subsequently passes; aggregate workflow failures cannot identify it.

Do not dynamically switch HEADGREEN/ALLGREEN, relax required CI, auto-enqueue approvals or fight the lander by cancelling runs. Do not infer a multiplicative cost saving from minimum merge size. First improve observation quality and recommend a small finite policy. If DQ4 shows no material benefit beyond manual settings, stop at DQ3 and keep the reusable package as an advisory component.
