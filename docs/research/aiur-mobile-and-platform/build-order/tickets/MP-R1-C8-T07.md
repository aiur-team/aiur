---
ticket_id: MP-R1-C8-T07
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Build-orders component — cut the GitHub family's references into build-order modules
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T03, MP-R1-C1-T05, U5 (prior unit, GitHub access contract)]
prior_units: [U5, U2]
prior_boundaries: [BO #30, GHC #5, GHD #8, CLI #31]
prior_features: []
prior_findings: [github-a-01, github-b-02]
size_owner: GH_ACCESS (github/client.ex — confirm row) and BO_RUNTIME — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T07 — GitHub family no longer references build-orders

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S12 "build orders as a
  component", lower-layer half).
- **User value:** none visible. `github` (L2, required whenever the GitHub tracker is
  configured) stops referencing `build-orders` (L3, optional), so build orders can
  later be left out without breaking GitHub polling.
- **Deliverable:** three edges removed:
  1. `GitHub.Client.fetch_build_order_catalog/1` and `fetch_build_order_selected_root/2`
     (`github/client.ex:6,92-99`) — production pass-throughs with **no production
     caller** — are deleted; their two test callers call `Aiur.BuildOrder.GitHubGraph`
     directly.
  2. `GitHub.IssueRelationships` takes the linked-PR page size from its caller
     (`opts[:limit]`) instead of reading
     `Aiur.BuildOrder.TicketDetail.DestinationNormalizer.max_pull_requests/0`
     (`github/issue_relationships.ex:4,68`).
  3. `GitHub.ViewStateSweep`'s source list (`view_state_sweep.ex:91-93`,
     `[Aiur.BuildOrder.PackStatus]`) moves to its child spec in the composition root
     (`aiur.ex:441`).
- **Non-goals:** the `Aiur.BuildOrder.Bounded` references from `github/issues.ex:8,375`
  and `global_config_startup.ex:3,71` are MP-R1-C5-T02's (kernel primitives); the
  `Config` → `BuildOrder.Cadence` edge (`config.ex:8,616-657`) is MP-R1-C4's
  (build-order section registration). Both are listed here only so the C8 count is honest.

## Dependencies and blockers

- DESIGN-R1 §1; MP-R1-C1 rules and ratchet.
- **U5 first** for `src/lib/aiur/github/` (KTD11: first seam stays in-process; typed
  outcomes land before moves). This ticket edits two GitHub files by ≤10 lines and
  must rebase over U5. RC-19: MP-E1-C1 hooks in `github/labels.ex` and
  `github/issues.ex` are not touched.
- Read `website/docs-app/apis/github.md` before editing (AGENTS.md); this change
  alters no read, cadence or budget, so the page needs no edit.
- May run concurrently with C8-T01..T06. Not with C8-T08 (same manifest entry); T07 first.

## Verified starting point (45a290e3)

- `github/client.ex:6` aliases `BuildOrder.GitHubGraph`, `BuildOrder.ProviderResult`;
  `:92-99` define the two pass-throughs. `git grep fetch_build_order_ 45a290e3 -- src`
  finds only the definitions and three test calls:
  `src/test/aiur/build_order/github_graph_test.exs:1450,1469`,
  `src/test/aiur/github_client_test.exs:2187`.
- `github/issue_relationships.ex:38-60` `fetch_linked_pull_requests/3`; the only
  production caller is `build_order/ticket_detail_repository.ex:81-84`, reached from
  `build_order/ticket_detail.ex:32`. The limit constant is
  `build_order/ticket_detail_destinations.ex:8-11` (`@max_pull_requests 20`), also used
  for validation at `:39`.
- `github/view_state_sweep.ex:87-93` (comment: "Named here rather than
  self-registering, so the set of things that can generate view-state traffic is
  readable in one place"), `:108-109` `sources/0`, `:148`
  `sources: Keyword.get(opts, :sources, @sources)`. Test
  `src/test/aiur/github/view_state_sweep_test.exs:154,170` asserts
  `ViewStateSweep.sources() == [Aiur.BuildOrder.PackStatus]`.
- Child spec: `aiur.ex:441` `Aiur.GitHub.ViewStateSweep` (bare module).

## Chosen design

- **Edge 1 — delete.** A function with no production caller is not an interface. The
  GraphQL implementation already lives in `GitHubGraph`; the tests move to it.
- **Edge 2 — caller supplies the limit.** `ticket_detail_repository.ex` passes
  `limit: DestinationNormalizer.max_pull_requests()`; `IssueRelationships` uses
  `Keyword.fetch!(opts, :limit)` for the query variable. `fetch!` (not a default) so a
  caller that forgets the limit fails loudly instead of silently querying a different
  page size than the normalizer validates (`ticket_detail_destinations.ex:39`).
- **Edge 3 — list at the composition root.** Child spec becomes
  `{Aiur.GitHub.ViewStateSweep, sources: [Aiur.BuildOrder.PackStatus]}`; `@sources`
  becomes `[]` default. This keeps the "readable in one place" property (the list is
  in `aiur.ex`, which already names every child) and leaves the composition root as
  the only place that knows both components. `sources/0` is deleted: at base only
  `view_state_sweep_test.exs:154,170` calls it.

## Implementation steps

1. Delete `client.ex:92-99` and the two aliases at `:6` if now unused; update the three
   test calls to `Aiur.BuildOrder.GitHubGraph.fetch_catalog/1` / `fetch_selected_root/2`.
2. `issue_relationships.ex`: drop the alias at `:4`; `"limit" => Keyword.fetch!(opts, :limit)`.
   `ticket_detail_repository.ex:84`: add `Keyword.put(opts, :limit, DestinationNormalizer.max_pull_requests())`.
3. `view_state_sweep.ex`: `@sources []`; keep `Keyword.get(opts, :sources, @sources)`;
   remove or rework `sources/0` per design; `aiur.ex:441` passes the list.
4. Update `view_state_sweep_test.exs:154,170` to assert the child spec from
   `Aiur.Application.child_specs/1` contains `sources: [Aiur.BuildOrder.PackStatus]`.
5. Manifest: remove the three allowlist entries. ≈40 changed production lines.

## Non-happy paths

- **Missing limit:** `Keyword.fetch!` raises `KeyError` inside the ticket-detail task;
  the coordinator's task-lifecycle already maps task crashes to a failure snapshot
  (`ticket_detail_coordinator_task_lifecycle.ex`); verify at head that a crash shows
  as unavailable, not as "no linked PRs". If it would show as empty, return
  `{:error, :limit_required}` instead of raising.
- **Sweep with empty sources** (a composition without build orders): the sweep still
  runs its divergence watermark and broadcasts `{:view_state_diverged, repo}` to
  event-sourced listeners; with no polled source it reconciles nothing. Check at head
  that an empty list does not skip the broadcast — the broadcast is what
  `OpenTicketSource` and `AdHocSource` rely on.
- **GitHub budget:** no new or removed read; same query, same page size.

## Compatibility and rollout

No config, no data change, no quota change (no saving is claimed). Revert is a plain revert.

## Verification

New/changed tests:

1. `src/test/aiur/github/issue_relationships_test.exs` (new or existing, check head):
   `test "linked PR query uses the caller's limit"` — inject `request_fun` capturing
   variables; call with `limit: 7`; assert `variables["limit"] == 7`.
   **Mutation:** restore `DestinationNormalizer.max_pull_requests()` in the query → the
   captured value is 20 and the test fails.
2. `test "linked PR fetch without a limit fails loudly"` → `assert_raise KeyError` (or
   `{:error, :limit_required}` per the non-happy-path decision).
3. `view_state_sweep_test.exs`: `test "composition root wires PackStatus as the only sweep source"`
   — asserts the child spec. **Mutation:** drop `sources:` from `aiur.ex` → fails.
4. `test "sweep with no sources still broadcasts divergence"` — start with
   `sources: []`, force a divergence via the existing test seam, `assert_receive {:view_state_diverged, _}`.

Commands:
`env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/github/view_state_sweep_test.exs test/aiur/github_client_test.exs test/aiur/build_order/github_graph_test.exs test/aiur/github/issue_relationships_test.exs test/aiur/build_order`;
`make -C src fmt-check lint`; `python3 scripts/check-components.py` (three fewer violations).
Mutations run in a clean worktree; PR body lists exact commands.

Manual: foreground `scripts/aiurdev --test`; open a ticket context dialog with linked
PRs and the Build Orders page; identical before/after captures.

## Completion and handoff

- [ ] No module under `src/lib/aiur/github/` references `Aiur.BuildOrder.*` except the
  two `Bounded` sites owned by MP-R1-C5-T02 (allowlisted with that ticket named).
- [ ] Tests 1–4 pass; mutations 1 and 3 fail as described.
- **Docs:** none (`apis/github.md` unaffected; stated in PR).
- **Dependents:** MP-R1-C8-T08; MP-R1-C7-T05 (GitHub umbrella) starts from a GitHub
  family with no build-order references.
