---
ticket_id: MP-R2-C1-T01
feature_id: MP-R2
chunk_id: MP-R2-C1
bucket: 1 (refactor)
title: Characterize which published events reach the per-ticket IssueLog event history
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U3]
prior_boundaries: [BUS #10, RUN #18]
prior_features: []
prior_findings: []
size_owner: n/a (test-only; issue_log.ex 1049 lines is LIFECYCLE_STATUS, not touched)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C1-T01 — IssueLog persistence matrix (characterization)

## Identity and outcome

- **Bucket 1, MP-R2, chunk C1 (characterize today's bus), ticket T01.**
- **Value.** It fixes, in a test, which events become durable per-ticket history
  today. Later chunks (C2-T03 HistoryStore sink, MP-E4 anchors) must preserve or
  knowingly change this. It settles plan RQ-1 with a witness, not with reading.
- **Deliverable.** One new test file,
  `src/test/aiur/events/issue_log_persistence_characterization_test.exs` (PROPOSED).
- **Non-goals.** No production change. No change to which events are written.
  Widening the IssueLog to GitHub/CI/PR events (plan alternative E) is out of scope.

## Dependencies and blockers

- DESIGN-R2 §1 (owner gate; implementation blocked until approved).
- No predecessor ticket. May run concurrently with C1-T02..T06 (disjoint test files).
- Consumers of the result: C2-T03 (HistoryStore sink), MP-E4-C3 (anchor resolver
  uses `IssueLog.event_history/2`), contract `events-and-replay.md` §6 `logged` class.

## Verified starting point (45a290e3)

- `Publisher.do_publish/3` and `publish_persisted/4` call `record_emit_marker/3`
  for every topic with a `ticket.<id>.` prefix (`src/lib/aiur/events/publisher.ex:220-234,257-271,337-357`).
  Kind is `:self` for `ticket.<id>.agent.*` or `opts[:self_emit]`, else `:emit` (`:348-353`).
- `IssueLog.record_event/3` sends to a writer only when `event_identity/2` returns
  `{:ok, identity}`: the event carries a `%TicketObservation{status: :joinable}`
  whose `tracker_identity` is `TrackerIdentity.joinable?/1` and whose
  `identifier` equals the topic's ticket, and a writer is registered at that path
  (`src/lib/aiur/issue_log.ex:545-560,573-581,616-621`). Otherwise it returns `:ok`
  and writes nothing.
- Writers exist only after `IssueLog.attach/1` (`issue_log.ex:53-70`) and live until
  BEAM exit (`issue_log.ex:1-13`).
- Only agent paths pass a trusted identity to the Publisher:
  `agent_runner/tool_executor.ex:441` (`identity:` for `emit_event`) and `:123`
  (`observation_identity:` for agent alerts, through `alerts.ex:307-313`). GitHub
  firehose, comments poller, webhook, `ci_lifecycle.ex:361-362`, DecisionStore
  (`decision_store.ex:2558,4608`) pass no identity.
- `IssueLog.event_history/2` default kinds are `[:emit, :emit_alert]`; `:self` and
  `:consumed` need `kinds:` (`issue_log.ex:143-203`).
- Existing fixture pattern to reuse: `src/test/aiur/issue_log_event_history_test.exs:17-35`
  (setup), `:203-266` (configured repo via `write_workflow_file!`, `IssueLog.attach(identity)`,
  `:sys.get_state(writer)` barrier), `:308-319` (joinable `%TrackerIdentity{}` helper).

## Chosen design

Drive the **real** `Aiur.Events.Publisher.publish/3` (the shared test app runs it,
`aiur.ex:374`) with production-shaped options, and read back with
`IssueLog.event_history(identity, kinds: [:emit, :emit_alert, :self, :consumed])`.

Matrix (ticket `N` = unique integer per test, configured repo `owner/repo`):

| Row | Publish options | Writer attached? | Topics published |
| --- | --- | --- | --- |
| A joinable + writer | `identity: identity(identifier: N)` | yes | `ticket.N.agent.progress`, `ticket.N.pr.merged`, `ticket.N.ci.failed`, `system.main.branch.push` |
| B joinable, no writer | same | no | same |
| C unattributed (production GitHub/CI shape) | `issue_number: N` only, no identity | yes | same |
| D identity for another ticket | `identity: identity(identifier: N+1)` | yes (for N) | `ticket.N.pr.merged` |

Expected (the characterization):

| Row | Written to N's history |
| --- | --- |
| A | `agent.progress` as `:self`; `pr.merged` and `ci.failed` as `:emit`; `system.main.branch.push` never (no ticket prefix) |
| B | nothing (`{:error, :missing_source}` or `{:ok, []}`) |
| C | nothing, for every topic: this is the production shape of GitHub/CI events |
| D | nothing (identity mismatch, `issue_log.ex:576`) |

Row C is the evidence for contract §6: GitHub, CI and PR events are `live`, not
`logged`. Row A shows the gate is identity-based, not topic-based.

## Implementation steps

1. Create the test module `Aiur.Events.IssueLogPersistenceCharacterizationTest`,
   `use Aiur.TestSupport`, `async: false` (shared Publisher, IssueLog registry).
2. Copy the setup from `issue_log_event_history_test.exs:17-35` and the
   `identity/1` and `writer_pid/1` helpers (`:308-325`). Write the workflow file
   with `tracker_repo: "owner/repo"` as at `:210-213`.
3. Publish with `Aiur.Events.Publisher.publish(topic, %{"n" => 1}, opts)`; pass
   `issue_number: nil` where needed so the tracked-set gate (`publisher.ex:199-201`)
   cannot filter. Assert each call returns `{:ok, id, _}` and collect the ids.
4. Barrier: `:sys.get_state(writer_pid)` after the last publish (record_event is a
   `send`, `issue_log.ex:551`).
5. Assert the exact set of `{id, topic, kind}` per row using `event_history/2`
   with all four kinds. Assert equality of lists, not pattern `%{}` matches.
6. Module doc and each test name end with "(characterization)" and a comment:
   "Deliberately green on main; pins existing behaviour for C2-T03 and MP-E4."

## Non-happy paths

- Writer replaced on repo change (`issue_log.ex:583-602`): out of scope; covered by
  the existing test at `:203`.
- Publisher filter gates must not hide the result: use unique ticket numbers and no
  `:dedup_key` / `:resource`, so `publisher.ex:188-218` returns `nil` (no rejection).
- Never touches `~/.aiur`: `TestSupport` isolates `:log_file`; assert
  `IssueLog.event_log_path(identity)` starts with the test tmp root.

## Compatibility and rollout

n/a — test-only; no config, no migration, no runtime change.

## Verification

Test cases (file `src/test/aiur/events/issue_log_persistence_characterization_test.exs`):

- `"joinable agent and ticket events reach history when a writer exists (characterization)"` — row A.
- `"joinable events without a writer are not persisted (characterization)"` — row B.
- `"unattributed GitHub/CI-shaped events never reach history (characterization)"` — row C.
- `"an identity for another ticket is not persisted (characterization)"` — row D.
- `"system topics never write a per-ticket marker (characterization)"` — `system.main.branch.push` across A–C.

Command (clean worktree; HOME is a temp dir and GitHub tokens are unset because a
local `mix test` can overwrite `~/.aiur/github-budget/agent-token`):

```bash
env -C <worktree>/src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= \
  mise exec -- mix test test/aiur/events/issue_log_persistence_characterization_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check (characterization form): these tests guard existing behaviour and
are not change coverage. Prove they can fail: in a worktree, change
`issue_log.ex:576` to accept `:unattributed` observations; row C must fail. Revert
`publisher.ex:351` (`:self` branch) to `:emit`; row A must fail. `git status
--porcelain` must show only that edit. Record both commands in the PR body.

## Completion and handoff

- [ ] Five tests green on main; both mutations make the named rows fail.
- [ ] PR body states "characterization, deliberately green on main" and lists the
      mutation commands.
- [ ] Result linked from contract §6 (`logged` and `live` rows) by the C4-T05 docs ticket.
- Docs: none (no user-facing change; AGENTS.md "Docs ship with the change" does not apply).
- Dependents: C2-T03 (must keep these green), C4-T03 (runs the C1 suite as acceptance).
