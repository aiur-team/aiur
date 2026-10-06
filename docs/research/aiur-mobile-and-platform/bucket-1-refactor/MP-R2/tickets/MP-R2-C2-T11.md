---
ticket_id: MP-R2-C2-T11
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Assign the non-bus modules under events/ to their owning components in components.json (no file moves)
status: blocked
blocked_by: [DESIGN-R2 §1, MP-R1-C1-T1 (manifest exists), coordinator answer to CONTRACT-REQUESTS.md CR-R2-1, MP-R2-C2-T05]
prior_units: [U7]
prior_boundaries: [BUS #10, ING #9, ORC #12, RUN #18, GHD #8]
prior_features: [MP-R1]
prior_findings: []
size_owner: n/a (manifest JSON only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T11 — Manifest reassignment of non-bus modules

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No code or user-visible change.
- **Replaces plan tickets C2-T04/T05** ("re-home EventTopics/AutoSubscriptions
  to ORC", "move BranchRefStore to ING"). Phase C found no code edge to cut:
  - `Orchestrator.EventTopics` and `Orchestrator.AutoSubscriptions` already
    live in `src/lib/aiur/orchestrator/` and no bus module references them
    (`git grep "EventTopics|AutoSubscriptions"` hits only `orchestrator*` files).
  - `Events.BranchRefStore` is used only by ingestion producers
    (`github_comments_poller.ex`, `github_webhook/normalizer.ex`,
    `ls_remote_ticker.ex`), `orchestrator/push_routing.ex` and its
    supervision entry (`aiur.ex:360`).
  - `Events.CommentFilter` is used only by `github_comments_poller.ex` and
    `github_webhook/normalizer.ex`.
  - `EventPublicationLog` is used only by `agent_runner/tool_executor.ex`.
  - `Events.Sanitizer` is called only by producers and presenters, never by
    `Publisher`, `Exchange` or `SubscriptionStore`.
  - `Events.DebugLog` becomes the default trace implementation in C2-T05.
  MP-R1-KD1 makes a component a manifest entry, and RQ-8's answer forbids
  rename churn, so the right change is a manifest assignment, not a move.
- **Deliverable:** `components.json` entries assign these files to their
  owning components; the `event-bus` entry lists only true members.

## Dependencies and blockers

- **MP-R1-C1-T1** (manifest schema and initial manifest).
- **CR-R2-1** in `MP-R2/tickets/CONTRACT-REQUESTS.md`: MP-R1's component-map
  row for `event-bus` omits `debug_log.ex` and leaves `sanitizer.ex`,
  `branch_ref_store.ex`, `comment_filter.ex`, `event_publication_log.ex`
  unassigned. The coordinator (or MP-R1) confirms the target components
  below before this ticket runs.
- **C2-T05** (DebugLog is no longer called by the bus core).

## Verified starting point (45a290e3)

| File | Users (non-test) | Proposed component |
| --- | --- | --- |
| `src/lib/aiur/events/sanitizer.ex` | ING producers, `orchestrator/command_scan.ex`, `orchestrator/ci_lifecycle.ex`, `executor_events.ex`, `agent_runner/comment_context.ex`, `issue_context.ex`, `external_content.ex`, `build_order/ticket_detail_normalizer.ex`, `live_conversation/normalizer.ex`, presenters | `github-listeners` (ING #9), the producer side of untrusted GitHub text; trust port from C2-T02 |
| `src/lib/aiur/events/branch_ref_store.ex` | `github_comments_poller.ex`, `github_webhook/normalizer.ex`, `ls_remote_ticker.ex`, `orchestrator/push_routing.ex`, `aiur.ex:360` | `github-listeners` (prior #10 recommendation) |
| `src/lib/aiur/events/comment_filter.ex` | `github_comments_poller.ex`, `github_webhook/normalizer.ex` | `github-listeners` |
| `src/lib/aiur/event_publication_log.ex` | `agent_runner/tool_executor.ex` | `agent-runner` (RUN #18) |
| `src/lib/aiur/orchestrator/event_topics.ex`, `orchestrator/auto_subscriptions.ex` | `orchestrator.ex`, `orchestrator/issue_sync.ex`, `orchestrator/operator_messages*.ex` | `orchestration` (already by path glob `orchestrator/**`, component-map row) |
| `src/lib/aiur/events/debug_log.ex` | `publisher.ex`, `subscription_store.ex` (until C2-T05), `agent_list/app.ex`, `opencode/session_writer.ex`, `opencode/chat_completions/turn_stream.ex`, `agent_runner/events_digest.ex` | `tui` (debug ticker is TUI plumbing; contract R-5) |

MP-R1 component map event-bus row:
`bucket-1-refactor/MP-R1/component-map.md:92`; github-listeners row `:102`.

## Chosen design

Edit `components.json` only:

- `event-bus.paths` = `src/lib/aiur/events/{exchange,topic,publisher,id_generator,subscription_store,subscription_store_supervisor,universal_subscriptions,agent_subscription_policy,delivery,history_store,trace,source_policy,trust_classifier}.ex`,
  `src/lib/aiur/events.ex`, `src/lib/aiur/ticket_observation.ex` (plus C3/C5/C6
  modules as they land).
- Add the files in the table to the named components' `paths`.
- Record `events.codeowners_refresh_seconds` under the `github` component's
  owned config (name unchanged; MP-R1-C4 registration moves the schema field
  when it runs).

## Implementation steps

1. Confirm CR-R2-1 answer; edit `components.json`.
2. Run `python3 scripts/check-components.py` (MP-R1-C1) and update its
   ratchet baseline only if the count goes **down**.
3. In `test/aiur/events/bus_boundary_test.exs` (C1-T06), align `@members`
   with the manifest.

## Non-happy paths

- The checker may report new violations once files change component (for
  example `github-listeners → event-bus` is allowed, `event-bus →
  github-listeners` is not). Any new violation means a code edge was
  missed; stop and file it against the matching C2 seam ticket rather than
  allowlisting it.

## Compatibility and rollout

No runtime effect. Rollback: revert the manifest edit.

## Verification

1. `scripts/test-check-components.sh` (MP-R1-C1-T6) green.
2. `python3 scripts/check-components.py` exits 0 with a violation count ≤
   the baseline before this PR (paste both counts in the PR body).
3. `bus_boundary_test.exs` green with the updated member list.

```text
python3 scripts/check-components.py
bash scripts/test-check-components.sh
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/events/bus_boundary_test.exs
```

Mutation check: add `src/lib/aiur/events/sanitizer.ex` back to
`event-bus.paths` → the checker reports the `event-bus → github`
(`CodeOwners`, before C2-T02) or `event-bus → github-listeners` edge;
remove → clean.

## Completion and handoff

- [ ] Every file in the table has exactly one owning component.
- [ ] `event-bus` lists only true members.
- [ ] Docs: none (the public component directory page, MP-R1-C10, is
      generated from the manifest).
- Dependents: C4-T01.
