---
ticket_id: MP-R1-C8-T4
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Projections component — remaining edges (observability topic, orchestrator snapshot read, configured repository) and manifest reassignments
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C8-T3, "#3009 fix merged or explicitly deferred"]
prior_units: [U6, U2, U5]
prior_boundaries: [PRJ #28, ORC #12, BUS #10, GHD #8, TRK #3]
prior_features: []
prior_findings: [web-occ-07]
size_owner: LIFECYCLE_STATUS (open_ticket_source.ex 509, progress_retention.ex 532, ticket_activity/projection.ex 605 — reassigned only in the manifest, not edited) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T4 — Projections: remaining edges and manifest reassignments

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S10).
- **User value:** none visible. After this ticket the projections component has only
  declared, downward or same-layer dependencies, and the ambiguous modules have one
  owner each.
- **Deliverable:**
  1. `AiurWeb.ObservabilityPubSub` (27 lines, a `Phoenix.PubSub` topic helper used by
     core modules) moves to `Aiur.ObservabilityPubSub` (PROPOSED
     `src/lib/aiur/observability_pubsub.ex`), owned by `event-bus` as an
     internal-invalidation topic (MP-Q5 answer: PubSub carries internal invalidation).
  2. `CurrentRunProjections.State` reads the orchestrator snapshot only through the
     declared orchestration facade `Aiur.Orchestrator.SnapshotStore.read/3`, and reads
     the configured repository through `Aiur.TrackerIdentity` / tracker instead of
     `Aiur.GitHub.Config` — **only if** an equivalent exists at head (see steps); else the
     edge is allowlisted with reason and handed to MP-R1-C7 (tracker split).
  3. Manifest: `current_run_membership/**` → `orchestration`; `open_ticket_source*` →
     `github`. (Build-order ticket-detail/history modules go to a new `ticket-context` component in C8-T8, not to projections: they read GitHub.)
- **Non-goals:** no behaviour change. In particular the live bug **#3009**
  (`CurrentRunProjections` matches the bare atom `:observability_updated`,
  `current_run_projections.ex:145`, while `ObservabilityPubSub.broadcast_update/1`
  sends the tuple `{:observability_updated, event_id}`, `aiur_web/observability_pubsub.ex:22`)
  is **not** fixed here; this move must keep the same message shapes.

## Dependencies and blockers

- DESIGN-R1 §1; MP-R1-C8-T3 (projections manifest entry exists).
- **#3009:** if its fix is open at pickup, land it first so this PR is a pure move; if
  it is still unassigned, proceed and leave the mismatch untouched. Either way the PR
  states which.
- MP-R2 owns `event-bus`; the `ObservabilityPubSub` placement is recorded for MP-R2's
  bus-ownership table (contract request to MP-R2 via the coordinator).
- U2 owns `current_run_membership/` (reassignment is manifest-only). U5 owns
  `github/`; `open_ticket_source.ex` is reassigned, not edited.
- May run concurrently with C8-T1, T2, T5, T6, T7.

## Verified starting point (45a290e3)

- `AiurWeb.ObservabilityPubSub` users (`git grep -l ObservabilityPubSub 45a290e3 -- src/lib`):
  `agent_pubsub.ex`, `alerts.ex`, `current_run_projections.ex:163`,
  `orchestrator/snapshot_store.ex`, `recent_merge_store.ex`,
  `aiur_web/live/dashboard_live.ex`. Five of six are core modules referencing the web
  namespace (L1/L2/L3 → L4).
- `current_run_projections/state.ex:7-9` aliases `Aiur.GitHub.Config`,
  `Aiur.Orchestrator.SnapshotStore`; `:98-108` default readers
  `&SnapshotStore.read/3`, `Aiur.Orchestrator` (process name),
  `&GitHubConfig.configured_repo/0` (`github/config.ex:54`).
- `open_ticket_source.ex` outgoing references: `Aiur.BuildOrder.AdHocSource`,
  `Aiur.Config`, `Aiur.Events.GithubWebhook`, `Aiur.GitHub`, `Aiur.GitHub.ResourceStore`,
  `Aiur.GitHub.ViewStateSweep`, `Aiur.Issue`, `Aiur.Webhooks.ModeRegistry`. Child spec
  `aiur.ex:436` (`poll_on_start: … dashboard?`).
- `current_run_membership/**` (13 files) is written from
  `orchestrator/{membership_lifecycle,issue_sync,reconciler,retry_engine,comment_wake}.ex`.
- Tests: `src/test/aiur/current_run_projections_test.exs`, `src/test/aiur/open_ticket_source_test.exs`,
  any `observability_pubsub` test (`git ls-tree -r 45a290e3 -- src/test | grep -i observability_pubsub` — none found; it is covered through `dashboard_live_test.exs`).

## Chosen design

- **Move + rename** `AiurWeb.ObservabilityPubSub` → `Aiur.ObservabilityPubSub`, same
  topic string `"observability:dashboard"` and message shape. All six callers renamed;
  no shim (all callers in-repo).
- **SnapshotStore:** declare `Aiur.Orchestrator.SnapshotStore` as an orchestration
  facade and `orchestration` as a required dependency of `projections` (same layer,
  declared). No code change at `state.ex:98-99`.
- **Configured repository:** at head, check whether `Aiur.TrackerIdentity` or
  `Aiur.Tracker` exposes the configured repository. If yes, switch the default reader
  (one line). If not, keep `GitHubConfig.configured_repo/0` and allowlist
  `projections → github` with reason "configured repository; replaced by tracker
  CodeHost port in MP-R1-C7-T1". Do not add a new tracker function here.

## Implementation steps

1. `git mv src/lib/aiur_web/observability_pubsub.ex src/lib/aiur/observability_pubsub.ex`;
   rename the module; update six callers (≈12 changed lines).
2. Steps for the repository reader as above (≤3 lines).
3. `components.json`: `event-bus` gains `src/lib/aiur/observability_pubsub.ex`
   (facade); `orchestration` gains `current_run_membership*/**`; `github` gains
   `open_ticket_source*`; `projections.requires` gains `orchestration`; remove the
   allowlist entries this cures.
4. Record checker counts before/after in the PR body.

## Non-happy paths

- **PubSub absent at boot:** `broadcast_update/1` already returns `:ok` when the pubsub
  process is not registered (`observability_pubsub.ex:18-25`); unchanged.
- **Orchestrator down:** `SnapshotStore.read/3` returns stale/unavailable;
  `read_current_snapshot/3` maps both to `:unavailable` (`state.ex:124-130`); unchanged.
- **#3009 interplay:** if #3009 lands concurrently, whichever PR merges second rebases;
  the rename does not alter the matched pattern.

## Compatibility and rollout

No config or on-disk change. Revert is a plain revert.

## Verification

- Existing suites, renamed references only:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/current_run_projections_test.exs test/aiur/open_ticket_source_test.exs test/aiur_web/live/dashboard_live_test.exs test/aiur/alerts_test.exs`
  (confirm the `alerts_test.exs` path at head).
- New `src/test/aiur/observability_pubsub_test.exs`:
  `test "broadcast_update delivers {:observability_updated, id} on observability:dashboard"`
  — subscribe, broadcast, `assert_receive {:observability_updated, id} when is_integer(id)`.
  Characterization guard for the message shape that #3009 depends on; passes on main
  after the rename; **not counted as covering a behaviour change**.
- Checker mutation: re-add `AiurWeb.ObservabilityPubSub` to `alerts.ex` in a scratch
  branch (with the old module restored) → `check-components.py` reports an L1→L4 edge.
- `make -C src fmt-check lint`; `python3 scripts/check-components.py`.
- Manual: foreground `scripts/aiurdev --test`; dashboard home updates when an agent
  changes state (same as before); capture before/after.

## Completion and handoff

- [ ] No core module references `AiurWeb.ObservabilityPubSub`.
- [ ] Manifest reassignments applied; checker count ≤ baseline.
- [ ] PR body states the #3009 status.
- **Docs:** none.
- **Dependents:** MP-R2 (bus-ownership table gains the observability topic);
  MP-R1-C7-T1 (tracker CodeHost port retires the repository allowlist entry if used).
