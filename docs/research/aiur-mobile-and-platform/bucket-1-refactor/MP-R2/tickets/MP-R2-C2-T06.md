---
ticket_id: MP-R2-C2-T06
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Move the Publisher's GitHub-specific gates behind an Aiur.Events.SourcePolicy behaviour, gate order unchanged
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T06]
prior_units: [U5, U7, U8]
prior_boundaries: [BUS #10, GHD #8, GHR #7, ING #9]
prior_features: []
prior_findings: [MP-R2 Phase C finding "Publisher holds GitHub-domain gates"]
size_owner: EVENTS (publisher.ex 539 lines; must shrink); re-check at start per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T06 — `SourcePolicy` for the Publisher's GitHub gates

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change.
- **New finding (not in plan.md):** the Publisher, the bus's single publish
  boundary, embeds GitHub-domain policy: the bot self-loop filter
  (`Aiur.GitHub.Config`, `Aiur.GitHub.AgentMarker`), the restart-durable
  resource dedup (`Aiur.GitHub.ResourceStore`) and webhook-silence
  corroboration (`Aiur.Webhooks.record_activity/2`). These are the
  remaining non-kernel edges of `publisher.ex` after C2-T03/T05.
- **Deliverable:** behaviour `Aiur.Events.SourcePolicy` with four callbacks;
  the GitHub bodies move verbatim to a default implementation in the GitHub
  component; `Publisher.rejection/3` keeps the **same order of the same
  checks**. `publisher.ex` shrinks by about 90 lines (from 539).
- **Non-goals:** no change to any gate's logic or to the outcome atoms;
  no reordering; no change to option names (`:actor`, `:resource`,
  `:resource_version`, `:resource_source`, `:dedup_key`, `:issue_number`,
  `:bypass_contamination`).

## Dependencies and blockers

- DESIGN-R2 §1; C1-T06.
- **U5 interplay:** U5 owns `github/resource_store.ex` ("monotonic resource
  writes"). This ticket calls `ResourceStore.processed?/2` and
  `mark_processed/3` exactly as today; if U5 changes those signatures first,
  the adapter follows U5. No hard ordering; check at start.
- File overlap on `publisher.ex` with C2-T03 (line 355), C2-T05 (lines 232,
  268), C2-T08 (facade). Recommended merge order T03 → T05 → T06 → T08.

## Verified starting point (45a290e3)

| Gate / hook (order in `rejection/3`, `publisher.ex:188-218`) | Owner today | Evidence |
| --- | --- | --- |
| 1 durable decision topic → `{:error, :decision_requires_durable_publish}` | bus | `:190-191,285-287`, `@durable_decision_names :57` |
| 2 `executor.*` from GitHub source → error | bus (string/atom match only, no module) | `:193-194,273-278` |
| 3 bot self-loop → `:filtered` | **GitHub**: `GitHubConfig.daemon_account/0`, `single_account?/0`, `AgentMarker.marked?/1`, `marker/0` | `:196-197,405-495` |
| 4 untracked issue → `:filtered` | bus (`tracked_fn` persistent_term) | `:199-201,497-504` |
| 5 resource already processed → `:deduped` | **GitHub**: `ResourceStore.processed?/2` | `:209-210,236-238` |
| 6 dedup window → `:deduped` | bus (ETS) | `:212-213,506-534` |
| after publish: mark resource processed | **GitHub**: `ResourceStore.mark_processed/3` | `:231,240-246` |
| before branching: webhook corroboration (skips `:deduped`) | **GitHub/Webhooks**: `Webhooks.record_activity/2` for `:poll` resources | `:115-116,124-180` |
| `:resource` requires `:resource_source` (raises `KeyError`) | bus (option contract) | `:114,182-184` |

Load-bearing comment: `deduped?/1` must be evaluated exactly once and
`Aiur.Orchestrator.CiLifecycle` branches on `:deduped`, so the order of
gates is behaviour (`publisher.ex:156-164`).

Tests: `test/aiur/events/publisher_test.exs`,
`test/aiur/events/publisher_identity_mode_test.exs`,
`test/aiur/orchestrator_ci_lifecycle_test.exs`,
`test/aiur/events/webhook_poll_reconciliation_test.exs`,
`test/aiur/events/github_comments_poller_test.exs`.

PROPOSED: `src/lib/aiur/events/source_policy.ex`,
`src/lib/aiur/github/event_source_policy.ex`,
`src/test/aiur/events/source_policy_test.exs`.

## Chosen design

```elixir
defmodule Aiur.Events.SourcePolicy do
  @callback self_authored?(topic :: String.t(), actor :: String.t() | nil, payload :: map()) :: boolean()
  @callback already_processed?(opts :: keyword()) :: boolean()
  @callback mark_processed(opts :: keyword()) :: :ok
  @callback observe(outcome :: term(), opts :: keyword()) :: :ok
end
```

- `Aiur.Events.SourcePolicy.Null` (in the bus): `false`, `false`, `:ok`,
  `:ok` — used when no policy is configured (reusable-bus shape).
- `Aiur.GitHub.EventSourcePolicy` (default via `src/config/config.exs`
  `config :aiur, Aiur.Events.SourcePolicy, Aiur.GitHub.EventSourcePolicy`):
  - `self_authored?/3` = today's `filtered_bot_self_loop?/3` with its
    helpers (`bot_self_loop?/1`, `authoritative_merge_topic?/1`,
    `ours_by_provenance?/1`, `comment_provenance/1`, …) moved verbatim,
    including their comments.
  - `already_processed?/1` = `ResourceStore.processed?(opts[:resource], opts[:resource_version])`.
  - `mark_processed/1` = today's `mark_resource_processed/1`.
  - `observe/2` = today's `record_webhook_activity/2` with the long
    corroboration comment (`:124-170`) moved alongside it.
- `Publisher.rejection/3` becomes:

```elixir
cond do
  durable_decision_topic?(topic) -> {:error, :decision_requires_durable_publish}
  executor_topic_from_github?(topic, payload, opts) -> {:error, :executor_namespace_rejects_github_source}
  policy().self_authored?(topic, Keyword.get(opts, :actor), payload) -> :filtered
  not Keyword.get(opts, :bypass_contamination, false) and not tracked?(Keyword.get(opts, :issue_number)) -> :filtered
  policy().already_processed?(opts) -> :deduped
  deduped?(Keyword.get(opts, :dedup_key)) -> :deduped
  true -> nil
end
```

  `publish/3` calls `policy().observe(outcome, opts)` where it calls
  `record_webhook_activity/2` today; `do_publish/3` calls
  `policy().mark_processed(opts)` at the same position (after the Exchange
  publish and the history marker, before the trace). `policy/0` reads the
  app env once per call (ETS read).
- **Invariants:** same evaluation order; `deduped?/1` still evaluated at
  most once per publish; marking still happens strictly after
  `Exchange.publish`; `observe` still runs before branching and still
  receives `:deduped` (and ignores it inside the GitHub policy, as
  `:171` does today).

## Implementation steps

1. Add the behaviour, the `Null` policy and `Aiur.GitHub.EventSourcePolicy`
   with the moved bodies (no edits beyond the function heads).
2. Edit `publisher.ex` as above; delete moved functions and the
   `AgentMarker`, `GitHubConfig`, `ResourceStore`, `Webhooks` aliases.
3. Config default.
4. Remove the four GitHub/Webhooks rows for `publisher.ex` from the C1-T06 allowlist.

## Non-happy paths

- `ResourceStore` not running: today `processed?/2`/`mark_processed/3`
  handle it ("with no store running, publishing is exactly as it was
  before", `publisher.ex:86-87`) — unchanged because bodies move verbatim.
- `Webhooks.record_activity` raising `ArgumentError` from config read: the
  comment at `:166-170` explains why the repo comes from the resource key;
  unchanged.
- Policy module misconfigured: `UndefinedFunctionError` on every publish.
  Fail loud is acceptable here (the default exists; a broken custom policy
  must not silently disable the self-loop filter). Covered by test 4.

## Compatibility and rollout

Internal app env only. No option rename. Rollback: revert.

## Verification

1. `source_policy_test.exs` `"the configured policy decides self-authored filtering"` —
   app env → `FakePolicy` with `self_authored?` true for actor `"bot"`;
   `Publisher.publish("ticket.1.issue.commented", %{}, actor: "bot")` →
   `:filtered`. **Fails without step 2** (today the real GitHub config is
   consulted; with no daemon account configured in the test it publishes).
2. `"already_processed? runs before the dedup window"` — FakePolicy
   `already_processed?` → true and records the call; publish with
   `dedup_key: {"o/r","comment","9"}` returns `:deduped`; then switch
   `already_processed?` to false and publish the same key → `{:ok, _, _}`
   (window was not polluted by the first call). Guards gate order 5→6 and
   the "evaluated once" rule; **fails if the two `cond` arms are swapped**.
3. `"mark_processed runs after fan-out"` — FakePolicy `mark_processed`
   asserts the test process already received `{:event, %{id: id}}` (the test
   is subscribed to the topic). **Fails if the call moves before
   `Exchange.publish`.**
4. `"Null policy publishes with no GitHub filtering"` — app env → `Null`;
   actor equal to the configured daemon account still publishes.
5. Existing suites listed above unchanged and green; in particular
   `orchestrator_ci_lifecycle_test.exs` (`:deduped` branching) and
   `webhook_poll_reconciliation_test.exs` (corroboration).

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/source_policy_test.exs test/aiur/events/publisher_test.exs \
  test/aiur/events/publisher_identity_mode_test.exs test/aiur/orchestrator_ci_lifecycle_test.exs \
  test/aiur/events/webhook_poll_reconciliation_test.exs test/aiur/events/github_comments_poller_test.exs \
  test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: revert the `publisher.ex` hunk only → test 1 fails;
swap the two `:deduped` arms → test 2 fails; move `mark_processed` before
`Exchange.publish` → test 3 fails. Restore after each.

## Completion and handoff

- [ ] `publisher.ex` references no `Aiur.GitHub.*` or `Aiur.Webhooks` module and is shorter than 539 lines.
- [ ] Gate order identical (reviewer diff of `rejection/3`).
- [ ] Tests 1–4 added and mutation-checked.
- [ ] Docs: none. `website/docs-app/apis/github.md` describes ResourceStore
      dedup; behaviour is unchanged, so no edit (AGENTS.md: keep that page
      current only when behaviour changes).
- Dependents: C2-T08 (facade), C4-T01, MP-R1-C7 (GitHub component owns
  `Aiur.GitHub.EventSourcePolicy`).
