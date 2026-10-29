---
ticket_id: MP-N5-C2-T04
feature_id: MP-N5
chunk_id: MP-N5-C2
bucket: 3-mobile-watch
title: Opt-in rules — PR merged, agent retry exhausted, CI failed
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C2-T01, MP-N5-C1-T02]
prior_units: []
prior_boundaries: [EXE #26, new #41 candidate push-relay]
prior_features: []
prior_findings: [executor_bindings.ex:25,29,32; A-R2-1 (pr.merged is live-class)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C2-T04 — Opt-in rules

## Identity and outcome

Bucket 3, MP-N5, chunk C2. Rule module `Aiur.Push.Policy.Rules.OptIn` (PROPOSED) for the
three opt-in sources offered in v1 (N5 plan §5.3; D18 off by default):

| Option | Topic (confirmed at refresh SHA) | Intent kind | dedup_key | target |
| --- | --- | --- | --- | --- |
| `pr_merged` | `ticket.*.pr.merged` | `pr.merged` | `pr:<repo>#<n>:merged` | `conversation` (ticket worker) |
| `optin.agent_retry_exhausted` | `ticket.*.agent.retry_exhausted` | `optin.agent_retry_exhausted` | `rx:<ticket>:<event id>` | `conversation` |
| `optin.ci_failed` | `ticket.*.ci.failed` | `optin.ci_failed` | `ci:<ticket>:<head sha or event id>` | `conversation` |

All `urgency: normal`, `expires_at = now + 6 h`. Commit pushes and comments are **not**
offered (DESIGN-N5 D-3 proposal); if D-3 = yes, a new ticket adds them.

## Dependencies and blockers

- C2-T01, C1-T02. DESIGN-N5 no-UI release (copy of the option names is C4).

## Verified starting point

Path refresh at `3b00b8f2cd0bfc9acdffe3b07ee5f1c6ca2ab56a` (2026-10-27).
See [plan §10](../plan.md#10-notification-policy-starting-point) for the complete
mapping, topic catalog and integration gates. Historical `base_sha` is retained.
All `policy/**`, `Aiur.Push.*` and push test paths here are **PROPOSED** under
`push-relay`; this refresh does not assert they shipped.

- Current topic catalog: `src/lib/aiur/events/catalog/entries.ex:33-40`
  (merge/CI live-class, exported); `events/catalog/ticket_entries.ex:44`
  (`ticket.*.agent.retry_exhausted`, ledgered).
- `src/lib/aiur/executor_bindings.ex` retains these default bindings.
- CI producer moved to `src/lib/aiur/orchestrator/ci_lifecycle/terminal_event.ex:19-29`;
  `head_sha`/`pr_number` remain available. Merge producer:
  `src/lib/aiur/events/github_firehose/pull_request.ex`.
- Export retains observed events; it cannot recover a merge never observed while down.

## Chosen design

- The merge may be observed twice (webhook and poller): dedup key per PR (AC-N5-9).
- CI failure payloads carry `head_sha` and `pr_number`
  (`Aiur.Orchestrator.CiLifecycle.TerminalEvent.publish_ci_terminal_event/4`,
  `orchestrator/ci_lifecycle/terminal_event.ex:19-29`);
  key on `head_sha`, falling back to the event id when it is `nil`. The payload's
  `failure_excerpt` is free text and is **never** copied into a summary.
- No free text from events goes into summaries except ticket number and PR number (the bus
  carries no free text by rule; events-and-replay §4).

## Implementation steps

`policy/rules/opt_in.ex` (PROPOSED) + tests.

## Non-happy paths

Event without a ticket attribution → ignored (cannot build a destination).

## Compatibility and rollout

Off by default per device.

## Verification

`src/test/aiur/push/policy/rules/opt_in_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"merge produces nothing until opted in"` (AC-N5-9) | 0 | default on |
| `"merge seen by webhook and poller notifies once"` (AC-N5-9) | 1 | key by event id |
| `"retry exhausted honours its own toggle"` | only when on | share pr_merged toggle |
| `"comment and push topics never produce intents"` | 0 | subscribe broadly |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/rules/opt_in_test.exs`.

## Completion and handoff

- [ ] AC-N5-9 covered. Dependents: C3-T02 (cap applies to these).
