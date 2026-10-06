---
ticket_id: MP-R2-C4-T01
feature_id: MP-R2
chunk_id: MP-R2-C4
bucket: 1 (refactor)
title: Finalize the logical event-bus component in components.json (paths, narrowed facades, owned config and state); no Mix app, no file moves
status: blocked
blocked_by: [DESIGN-R2 §1, MP-R1-C1-T1, MP-R1-C1-T3, MP-R2-C2-T01, MP-R2-C2-T02, MP-R2-C2-T03, MP-R2-C2-T04, MP-R2-C2-T05, MP-R2-C2-T06, MP-R2-C2-T07, MP-R2-C2-T08, MP-R2-C2-T09, MP-R2-C2-T10, MP-R2-C2-T11, MP-R2-C3-T01, MP-R2-C3-T02]
prior_units: [U7, U8]
prior_boundaries: [BUS #10]
prior_features: [MP-R1 (KD1, KD2, KD7; C1 manifest and checker)]
prior_findings: []
size_owner: n/a (manifest edit; components.json is formatted by check-components.py --format, MP-R1-C1-T1)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C4-T01 — Register the `event-bus` component

## Identity and outcome

- **Bucket 1, MP-R2, chunk C4 (logical component and docs).**
- **Value.** After the C2/C3 seams, the bus can be described truthfully as
  one component with a small public surface. The manifest entry is what
  MP-R1's checker enforces and what the public component directory page
  (MP-R1-C10, MP-REQ4) lists.
- **Deliverable.** The `event-bus` entry in root `components.json` updated
  from MP-R1-C1-T1's initial "today's paths" version to its post-seam
  shape: exact member paths, a narrowed `facades` list with
  `facade_pending: null`, `requires`/`optional`, and `owns` (config section,
  state paths). The checker runs green with the event-bus ratchet count at
  zero.
- **RQ-8 resolved (decisions.md):** MP-R1-KD1/KD7 make a component a
  manifest entry; a physical Mix project only follows the promotion test
  (`bucket-1-refactor/MP-R1/migration-plan.md` §5). The plan's "create the
  `aiur_events` package" is therefore **not** done here: no Mix app, no file
  moves, no module renames. A later promotion ticket may propose
  `aiur_events` once the §5 conditions hold (zero allowlisted violations for
  two releases; boot order declared by the component; tests run without
  the whole app; config registered; a second consumer).
- **Non-goals.** No code change (if one is needed, the owning C2 ticket is
  incomplete). Config **registration** of `events.*` is MP-R1-C4's events
  ticket (former MP-R2-C4-T02, absorbed; decisions.md).

## Dependencies and blockers

- **MP-R1-C1-T1** (manifest + schema + ownership check exist) and
  **MP-R1-C1-T3** (module-reference rules: private module, layer,
  required→optional). Without T3 the narrowed facades are not enforced.
- All C2 seam tickets and C3-T01/T02: each removes one ratchet edge or adds
  a member file; this ticket fixes the final shape. (Per MP-R1-C1-T1, each
  of those PRs already adds its new files to `components.json`; this ticket
  narrows facades and removes `facade_pending`.)
- DESIGN-R2 §1.
- Concurrent with C4-T05 (docs).

## Verified starting point (45a290e3)

- No `components.json` at base (`MP-R1-C1-T1`: `git ls-tree 45a290e3 components.json` empty).
- MP-R1 entry shape (MP-R1-C1-T1 ticket): `id`, `name`, `layer`, `kind`,
  `paths`, `facades`, `facade_pending`, `requires`, `optional`,
  `owns{config, env, state, capabilities}`, `prior`.
- MP-R1 event-bus row (`component-map.md` §3 L1): paths
  `src/lib/aiur/events/{exchange,topic,publisher,id_generator,subscription_store*,universal_subscriptions,agent_subscription_policy}.ex`,
  `ticket_observation.ex`; requires kernel, config; owns `events.*`,
  `event-id.json`, `subscriptions/*.json`. It omits `debug_log.ex`, and
  assigns no owner to `sanitizer.ex`, `branch_ref_store.ex`,
  `comment_filter.ex`, `event_publication_log.ex` (CONTRACT-REQUESTS; C2-T11
  places them).
- External users of bus modules at base (`git grep` at `45a290e3`, outside
  `src/lib/aiur/events/`):

| Module | External callers (files) |
| --- | --- |
| `Events.SubscriptionStore` | orchestrator (`auto_subscriptions`, `comment_polling`, `operator_messages`, `push_routing`, `status_report`), agent_runner (`bootstrap_digest`, `session_resume`, `tool_executor`), agent_list (`roster`, `state`, `renderer/events_block`), `decision_attention`, `opencode/{event_row,session_writer}`, `issue_log`, `test_reset`, `aiur.ex` |
| `Events.IdGenerator` | `decision_store`, `alerts`, `executor_events`, `agent_runner/comment_context`, `orchestrator/{ci_lifecycle,pause_resume}`, `test_reset`, `aiur.ex` |
| `Events.UniversalSubscriptions` | `agent_runner/bootstrap_digest`, `orchestrator/{ci_lifecycle,comment_wake}`, `progress_checkin/worker` |
| `Events.AgentSubscriptionPolicy` | `codex/dynamic_tool/subscriptions.ex` |
| `Events.Topic` | `alerts`, `executor_bindings`, `executor_events`, `executor_listener`, `agent_runner/bootstrap_digest` |
| `Events.Exchange.bindings_for` | `executor_listener` |
| `TicketObservation` | `issue_log`, `ticket_activity`, `ticket_activity/projection`, `build_order/ticket_history_normalizer` |
| `Events.Publisher`, `Events.Exchange` (publish/subscribe) | migrated to the `Aiur.Events` facade by C2-T08..T10 |

## Chosen design

Final entry (values; formatting is the checker's):

```json
{
  "id": "event-bus", "name": "Event exchange and subscriptions", "layer": 1, "kind": "required",
  "paths": [
    "src/lib/aiur/events.ex",
    "src/lib/aiur/events/{exchange,topic,publisher,id_generator,subscription_store,subscription_store_supervisor,universal_subscriptions,agent_subscription_policy}.ex",
    "src/lib/aiur/events/{delivery,history_store,trace,source_policy,journal,journaled_publish,durable_consumer}.ex",
    "src/lib/aiur/events/source_policy/null.ex",
    "src/lib/aiur/events/durable_consumer/**",
    "src/lib/aiur/ticket_observation.ex"
  ],
  "facades": ["Aiur.Events", "Aiur.Events.Topic", "Aiur.Events.IdGenerator", "Aiur.Events.SubscriptionStore",
              "Aiur.Events.UniversalSubscriptions", "Aiur.Events.AgentSubscriptionPolicy", "Aiur.TicketObservation",
              "Aiur.Events.Delivery", "Aiur.Events.HistoryStore", "Aiur.Events.Trace", "Aiur.Events.SourcePolicy",
              "Aiur.Events.Journal", "Aiur.Events.DurableConsumer"],
  "facade_pending": null,
  "requires": ["kernel", "config"],
  "optional": [],
  "owns": {"config": ["events"], "env": [], "state": ["<runtime_state_dir>/event-id.json", "<runtime_state_dir>/subscriptions/*.json"], "capabilities": []},
  "prior": ["BUS"]
}
```

- If the manifest schema requires literal paths rather than brace globs,
  expand them (the checker's `--format` decides).
- `Aiur.Events.Publisher` and `Aiur.Events.Exchange` become **private**
  once C2-T08..T10 have migrated every caller; if any caller remains, keep
  them in `facades` and name the remaining batch in the PR (no
  `facade_pending` with a vague target).
- `TicketObservation` → `Aiur.TrackerIdentity`/`Aiur.OpaqueIdentifier`
  (C1-T06 "unassigned" row): resolved by MP-R1's answer to
  CONTRACT-REQUESTS. Default if MP-R1 places `tracker_identity.ex` in the
  `identity` component (component-map L1 row lists it there): add
  `"identity"` to `requires` (same layer; R-down allows it).
- `owns.config: ["events"]`: the section; `events.codeowners_refresh_seconds`
  keeps its name and stays in this section (renaming is a breaking config
  change), but MP-R1-C4's registration may let the GitHub component
  register that one key. Not this ticket's decision.
- Default adapters that live outside the bus (`Aiur.Orchestrator.EventDelivery`,
  `Aiur.GitHub.EventSourcePolicy`, `Aiur.GitHub.EventTrust`,
  `Aiur.IssueLog.EventHistorySink`, `Aiur.IdFloorSources`) are listed under
  their owning components by the tickets that created them.

## Implementation steps

1. Rebase on main with all blockers merged; run
   `python3 scripts/check-components.py` and list remaining event-bus
   violations (expected: none).
2. Edit the entry as above; run `python3 scripts/check-components.py --format`.
3. Delete any event-bus rows from the checker's ratchet allowlist (MP-R1-C1-T5).
4. Do **not** delete `src/test/aiur/events/bus_boundary_test.exs` here; C4-T03 does.

## Non-happy paths

- A C2 seam left one edge: checker fails on the private-module or layer
  rule. Fix belongs in the owning C2 ticket's follow-up, not by widening
  `facades`.
- A non-bus module imports a now-private module (e.g. a test helper in
  `src/lib/aiur/test_reset.ex` uses `IdGenerator` internals): checker
  failure names it; route it through a facade function.
- Manifest drift (new event file added later without an entry): MP-R1-C1-T1
  ownership rule fails CI.

## Compatibility and rollout

Manifest only. No runtime effect, no config, no packaging change. Rollback: revert.

## Verification

- `python3 scripts/check-components.py` exits 0; the event-bus ratchet count
  is 0 (printed by the checker, MP-R1-C1-T5).
- `bash scripts/test-check-components.sh` green (MP-R1's fixtures).
- Negative check (worktree, not committed): add
  `Aiur.Events.Publisher.publish("ticket.1.x", %{})` to
  `src/lib/aiur/orchestrator/comment_wake.ex` → checker exits 1 naming the
  private module; remove `"config"` from `requires` → checker exits 1 on
  `universal_subscriptions.ex → Aiur.Config`. Record both in the PR body.
- Full suite on the merge ref is C4-T03's job.

```text
python3 scripts/check-components.py
python3 scripts/check-components.py --format && git diff --exit-code components.json
bash scripts/test-check-components.sh
```

## Completion and handoff

- [ ] Entry final; `facade_pending: null`; ratchet rows for event-bus gone.
- [ ] Both negative checks recorded.
- [ ] Docs: the component directory page is generated from
      `components.json` (MP-R1-C10), so no hand edit; it goes live after the
      refactor (D20).
- Dependents: C4-T03 (CI gate swap), C4-T04 (plan refresh), MP-R1-C10
  (directory page), MP-R1-C11 (path map).
