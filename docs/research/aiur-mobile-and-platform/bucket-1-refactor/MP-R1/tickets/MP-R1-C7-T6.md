---
ticket_id: MP-R1-C7-T6
feature_id: MP-R1
chunk_id: MP-R1-C7
bucket: 1-refactor
title: Declare the GitHub family as one logical component and remove its upward edges (KTD11, no new package)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-R1-C1-T3, MP-R1-C1-T5, MP-R1-C5-T3, U5-typed-outcomes, MP-E1-C1]
prior_units: [U5, U3]
prior_boundaries: [GHC, GHB, GHR, GHD, ING, BO, ORC]
prior_features: []
prior_findings: [codebase-02, codebase-05, codebase-10, github-a-01, github-b-02]
size_owner: GH_ACCESS (quota.ex, transport.ex 860, read_cache/*); GH_TRUST (issues.ex 1,248 — not edited); other edited files < 500. Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T2)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C7-T6 — GitHub family as one logical component

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C7 (migration step S8; prior §7
  step 4 "GitHub caching layer (7) and budget governor (6) … inside an `aiur_github`
  umbrella app, with the client (5) and domain (8). Invert the webhook-mode read in
  `ReadCache.Policy`").
- **Reconciled with KTD11 (binding):** the September plan says "use the existing
  in-process GitHub access layers as the first seam; do not add a new service, package
  or facade by default … After U5 … U7 may propose a physical package only if dependency
  and release evidence shows an ownership benefit." Therefore this ticket creates the
  **logical** `github` component (manifest entry, facade census, checker rules) and
  removes upward edges. It creates **no** Mix umbrella app, no new process, no new facade
  module, and does not change `Aiur.Application` start order (`src/lib/aiur.ex:324-384`).
  A physical `aiur_github` package is only proposed later through the promotion test
  (`migration-plan.md` §5) and U7.
- **User value:** none visible. Clients and later features get a declared GitHub
  boundary; the checker stops new code from reaching into GitHub internals.
- **Deliverable:**
  1. Manifest entry `github` with paths, census-derived facade list and allowlist.
  2. Removal of the github → executor-attention, orchestration, build-orders and
     github-listeners edges listed below, except `Issues → DispatchPolicy` (deferred,
     see Non-goals).
- **Non-goals:** U5's typed outcomes, trust snapshot and pagination repairs (U5 owns
  them; this ticket waits for them); `Issues → Orchestrator.DispatchPolicy`
  (`issues.ex:23,952,1132`) — it is label-state policy that U2's single lifecycle owner
  and MP-E1-C1 (RC-19) both touch; it stays allowlisted with reason "U2 state-label
  contract" and is proposed for MP-R1-C9-T9 (see README-C6-C11 open item G-1); GitHub listeners (C9-T1..T4); removing
  Dispatcher calls (C7-T7/T8).

## Dependencies and blockers

- **Owner gate:** DESIGN-R1 §1.
- **Predecessors:** MP-R1-C1-T1/T3/T5 (manifest, rules, ratchet in CI);
  MP-R1-C5-T3 (`Signal.emit/2`).
- **U5 first (KTD11, RC-21):** `U5-typed-outcomes` = U5's exit: one complete
  issue-comment reader, typed complete/held/unknown outcomes in `Transport`/`Client`,
  monotonic `ResourceStore` writes, the KTD9 trust snapshot, and the U5 `MembershipAccess`
  contract (`2026-09-29-001` plan U5 paragraph on `ed742aec`). The facade census must be
  taken **after** U5, because U5 removes duplicate access paths and changes which
  modules callers use.
- **MP-E1-C1 (RC-19):** E1-C1-T1 edits `github/labels.ex` (`@marker_suffixes`,
  `label_set/2`) and `github/issues.ex` (`queued?` at ingestion). This ticket rebases
  over E1-C1, does not edit either file, and lists `Aiur.GitHub.Labels` and the
  `Issue.queued?` producer as facades the build queue may rely on only through
  `Aiur.Tracker` (component-map §4).
- **U3:** `webhooks/mode_table.ex` is read on every cacheable request
  (`read_cache/policy.ex:532-537`); U3 owns event ordering, not this table. No conflict.
- **Concurrent with:** C7-T1, C7-T2, C7-T3, C7-T5, C7-T7, C7-T8 (disjoint files). C7-T7/T8
  should land after this ticket so their facade use is checked.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/github/**`: 68 files (plan: 25,691 lines †). Census at base: 99 files
  under `src/lib` outside `github/` reference `Aiur.GitHub` (grep
  `Aiur\.GitHub\b` plus grouped aliases; orchestrator 19, build_order 18, events 12, …).
  The prior survey counted 64 modules across 18 non-GitHub boundaries at `0972f0297`
  (`synthesis/architecture-verification.md`); the counts differ by method (alias
  prefixes counted here), so the ratchet uses the C1 checker's own count, not either
  number.
- 42 distinct `Aiur.GitHub.*` modules are referenced from outside `github/`; top:
  `Config` 45, `ResourceStore` 20, `Client` 14, `ViewStateSweep` 11, `Transport` 9,
  `Tracker` 9, `Errors` 6, `CodeOwners` 6, `AgentMarker` 6.
- Upward / cross-component edges **from** `github/`:

| File | Line | To | Treatment here |
|---|---|---|---|
| `app_token_refresher.ex` | 101 | `&Aiur.Alerts.emit_custom/3` default | `Signal.emit/2` |
| `code_owners.ex` | 126 | `&Aiur.Alerts.emit_custom/3` default | `Signal.emit/2` |
| `connectivity.ex` | 107 | `&Aiur.Alerts.emit_custom/3` default | `Signal.emit/2` |
| `credential_headroom.ex` | 26, 229 | `Alerts.emit_system/2` default | `Signal.emit/2` |
| `quota.ex` | 1225-1232 | `send(Aiur.Orchestrator, :github_quota_recovered)` | configured recovery target |
| `transport.ex` | 467, 477 | `self() == GenServer.whereis(Aiur.Orchestrator)` | configured poll-owner name |
| `view_state_sweep.ex` | 85, 91-93 | `@sources [Aiur.BuildOrder.PackStatus]`, `Aiur.Webhooks` | sources list at composition root |
| `issue_relationships.ex` | 4, 68 | `BuildOrder.TicketDetail.DestinationNormalizer.max_pull_requests/0` | constant moves into github |
| `read_cache/policy.ex` | 182, 506, 534 | `Aiur.Webhooks.ModeTable`, `Webhooks.DeliveryMode` type | `ModeTable` reassigned to `github` |
| `issues.ex` | 23, 952, 1132 | `Orchestrator.DispatchPolicy` | **deferred** (allowlist, C9-T9 proposed, open item G-1) |

- `ModeTable` (`webhooks/mode_table.ex`) is a passive ETS view written by
  `ModeRegistry` and read only by `ReadCache.Policy` (its moduledoc). Prior advice:
  "Ingestion publishes mode into a cache-owned freshness port" (`feature-boundaries.md`
  §3.2 `GHR ⇄ ING`).
- `view_state_sweep.ex:87-90` comment: sources are "named here rather than
  self-registering, so the set … is readable in one place". The design keeps one
  readable list, at the composition root.
- `quota.ex:1225-1232`: the orchestrator handles `:github_quota_recovered` at
  `orchestrator.ex:216`.

## Chosen design

1. **Manifest.** `github` component: paths `src/lib/aiur/github/**`,
   `src/lib/aiur/agent_github_guard.ex`, `src/lib/aiur/codeowners.ex`,
   `src/lib/aiur/github_cost_cli.ex`, `src/lib/aiur/github_usage_cli.ex`,
   `src/lib/aiur/webhooks/mode_table.ex`, `src/priv/github_budget.py` (verify each at
   the head). Facades = the census of `Aiur.GitHub.*` modules referenced from other
   components at the implementation head, **frozen** as the facade list (no new facade
   module). Rule: a new external reference to a non-facade GitHub module fails the
   checker. The list is expected to shrink as C7-T7/T8 and C9 land.
2. **Signals.** Five `Alerts` defaults → `Signal.emit/2`; topic strings and fields unchanged.
3. **Orchestrator name → configuration.** `quota.ex` reads
   `Application.get_env(:aiur, :github_quota_recovery_target)` and `transport.ex`
   reads `Application.get_env(:aiur, :github_poll_owner)`; both set to `Aiur.Orchestrator`
   in `src/config/config.exs`. Same message, same identity comparison.
4. **ViewStateSweep sources** → `config :aiur, :view_state_sources, [Aiur.BuildOrder.PackStatus]`
   in `config.exs`, with the "readable in one place" comment moved there.
5. **`max_pull_requests/0`** → constant in `Aiur.GitHub.IssueRelationships`;
   `DestinationNormalizer.max_pull_requests/0` delegates to it (build-orders → github is
   a downward edge).
6. **ModeTable** → manifest-reassigned to `github` (no code move, no rename). Listeners
   writing it is a downward edge.

## Implementation steps

1. Rebase over U5 and MP-E1-C1; run the C1 census; write the `github` manifest entry.
2. Apply design items 2–6 (≈60 production lines).
3. Add allowlist rows only for the deferred `Issues → DispatchPolicy` edge, each with
   reason `"U2 state-label contract; MP-R1-C9-T9 (G-1)"`.
4. Record in the PR body: external-reference count before/after, facade list size.

## Non-happy paths

- **Recovery target absent (no orchestrator in a future run shape):** nil config → no
  send, same as `Process.whereis/1` returning nil today.
- **Poll-owner name absent:** `orchestrator_process?` becomes false; that changes request
  attribution (`transport.ex:467`) — so `config.exs` must always set it; test 3 guards it.
- **ModeTable missing:** unchanged fail-safe (`:polling`, moduledoc "Failing safe").
- **RC-19 hooks:** `labels.ex` and `issues.ex` are untouched; test 5 asserts the E1 hook
  tests still pass.
- **Startup order:** no child spec changes; `rest_for_one` order in `aiur.ex` is
  untouched (KTD11). Test 4 is a guard.

## Compatibility and rollout

- No operator config change; new application config keys in `src/config/config.exs`.
- Rollback: revert (manifest + code together).
- `website/docs-app/apis/github.md` is not changed (no behaviour change); the
  implementer reads it first per AGENTS.md.

## Verification

```bash
env -C src mise exec -- mix test test/aiur/github test/aiur/orchestrator/github_budget_pause_test.exs \
  test/aiur/application_test.exs test/aiur/build_order
make -C src fmt-check && make -C src lint
python3 scripts/check-components.py && bash scripts/test-check-components.sh   # MP-R1-C1 (PROPOSED)
```

Tests:

1. Checker fixture: a module in `orchestration` referencing a non-facade
   `Aiur.GitHub.PollSnapshots` fails `check-components.py`. **Mutation:** add
   `PollSnapshots` to the facade list; fixture passes → test fails.
2. `github/quota_test.exs` "recovery notifies the configured target" — register a test
   process name via `put_env`; assert `:github_quota_recovered`. **Mutation:** hard-code
   `Aiur.Orchestrator`; fails.
3. `application_test.exs` (new case) "github_poll_owner,
   github_quota_recovery_target and view_state_sources are set" — reads
   `Application.get_env/2` in test env. **Mutation:** delete one key; fails.
4. Guard (passes at base, labelled as regression guard): the child-spec order list from
   `Aiur.Application.child_specs/1` is unchanged against a literal fixture.
5. RC-19 guard: `test/aiur/github/labels_test.exs` (MP-E1-C1 cases) green; `git diff`
   shows no change to `github/labels.ex` or `github/issues.ex`.

Manual: foreground `scripts/aiurdev --test`; observe that GitHub-backed rows load in
the AgentList and one chat pane opens; then `aiur github-cost` prints per-caller rows as
before (attribution unchanged).

## Completion and handoff

- [ ] `github` manifest entry merged; checker enforces facades.
- [ ] `git grep -nE 'Aiur\.(Alerts|Orchestrator|BuildOrder|Webhooks)\b' -- src/lib/aiur/github` returns only comments, `issues.ex` DispatchPolicy rows (allowlisted) and none else.
- [ ] Before/after counts in PR body; mutation results for tests 1–3.
- **Docs:** none required.
- **Dependents:** C7-T7, C7-T8 (Dispatcher uses only facades), MP-R1-C9-T1..T4 (listeners
  package boundary), MP-R1-C9-T9 (DispatchPolicy edge, G-1), U7 (physical package decision),
  MP-R4 (relay provider boundary reads `github` component config ownership).
