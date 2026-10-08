---
ticket_id: MP-E4-C4-T01
feature_id: MP-E4
chunk_id: MP-E4-C4
bucket: 2-platform
title: "Jump-point catalogue: kinds, labels (push with short sha), icons and default visibility"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C3-T02]
prior_units: [U6]
prior_boundaries: [PRJ]
prior_features: [MP-R2 (topic catalog R2-C5 registers the topics)]
prior_findings: [contract conversations-transcripts-anchors §10 "Jump-point catalogue (v1)"; DESIGN-E4 decision 2]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C4-T01 — Jump-point catalogue

## Identity and outcome

- Bucket 2 · MP-E4 · C4 · T01.
- **User value:** the event list names what happened in plain words —
  "Progress 60%", "Pushed 3f9a1c0", "PR #51 opened", "PR #51 merged",
  "Command requested", "CI failed" — and shows the kinds the operator chose by
  default.
- **Deliverable:** `Aiur.Conversation.JumpPoints` grows from `kind_for/1`
  (C3-T02) to the full catalogue: `entry/1` (kind, label, icon key, default
  visibility, best precision), `label/2` (payload-aware), `kinds/0`.
- **Non-goals:** rendering (C5-T03); changing `AgentEventFeed` labels (the Stream
  Deck shows those; MP-R6 promises no deck change).

## Dependencies and blockers

- **DESIGN-E4 decision 2** fixes `default_visible` per kind (are CI and
  comments noise?) and the icon set. Until then the values are not to be
  invented.
- MP-E4-C3-T02 (module exists with `kind_for/1`).
- Concurrent with: C4-T02, C3-T03.

## Verified starting point

- Topic labels today: `AgentEventFeed @topic_labels` (`src/lib/aiur/agent_event_feed.ex:52-72`):
  progress, check-in, phase change, blocked/unblocked, paused/resumed, pause
  requested, remote control, tokens exhausted, comment, PR opened/merged,
  review comment, CI passed/failed, decision requested/seen/resolved. Fallback
  humanizes unknown topics (`topic_label/1`, `agent_event_feed.ex:120-140`).
  **Missing:** `branch.push`, `executor.*` (plan §2.3).
- Push payload `%{ref, sha}` (`events/ls_remote_ticker.ex:173-180`); PR payload
  `%{action, pr, timestamp}` (`events/github_firehose.ex:392-411`).
- Contract §10 catalogue v1 lists ten kinds.

## Chosen design

```elixir
@type kind :: :progress | :phase | :push | :pr_opened | :pr_merged | :ci | :review_comment
            | :command_requested | :command_resolved | :attention | :executor_progress
@spec kind_for(String.t()) :: kind() | nil
@spec entry(kind()) :: %{kind: kind(), label: String.t(), icon: atom(), default_visible: boolean(),
                         best_precision: :exact | :causal | :observed}
@spec label(kind(), map()) :: String.t()     # payload-aware, bounded to 60 chars
@spec kinds() :: [kind()]
```

| Kind | Topics (`ticket.<id>.` stripped) | `label/2` |
| --- | --- | --- |
| `progress` | `agent.progress`, `agent.progress.checkin` | "Progress <pct>%" when payload has an integer percent, else "Progress" |
| `phase` | `agent.progress.phase`, `agent.phase.*` | "Phase: <phase>" |
| `push` | `branch.push` | "Pushed <sha[0..6]>" |
| `pr_opened` | `pr.opened` | "PR #<n> opened" |
| `pr_merged` | `pr.merged` | "PR #<n> merged" |
| `ci` | `ci.passed`, `ci.failed` | "CI passed" / "CI failed" |
| `review_comment` | `pr.review_comment`, `issue.commented` | "Review comment" / "Comment" |
| `command_requested` / `command_resolved` | `agent.decision.requested` / `agent.decision.resolved` | "Command requested" / "Command answered" |
| `attention` | `agent.attention.*`, `agent.blocked` | AgentEventFeed label |
| `executor_progress` | `executor.*` | "Executor: <humanized topic>" |

- `default_visible` and `icon` come from DESIGN-E4's approved table, copied
  into a module attribute with a comment naming the design revision.
- Labels never include comment bodies, PR titles or command text (the events
  contract's attrs rule: ids and enums only).
- `AgentEventFeed` is untouched; `JumpPoints` calls `AgentEventFeed.topic_label/1`
  only as the fallback for `attention`.

## Implementation steps

1. Extend `jump_points.ex` with the table, `entry/1`, `label/2`, `kinds/0`.
2. Make the resolver (C3-T02) store `label/2` in each anchor's `label`.
3. Test that every contract §10 topic maps to a kind and every kind has an
   entry.

## Non-happy paths

- Unknown topic → `nil` kind → not a jump point (the resolver ignores it);
  never a guessed kind.
- Missing payload fields (no percent, no PR number) → the label without the
  number; never "PR #nil".
- `executor.*` topics carry Executor-chosen names; the label humanizes the last
  segments and truncates to 60 chars.

## Compatibility and rollout

- Additive. If MP-R2-C5's topic catalog exists, add a test that each kind's
  topic patterns are registered there.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/jump_points_test.exs test/aiur/agent_event_feed_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "every catalogue topic maps to a kind" (table from contract §10) | all non-nil | the topic table |
| "push label uses a 7-char sha" | "Pushed 3f9a1c0" | `label(:push, _)` |
| "PR label without number has no #nil" | "PR opened" | nil guard |
| "default visibility matches DESIGN-E4 table" | equals the approved map | the attribute (pins the owner decision) |
| "unknown topic is not a jump point" | `nil` | no catch-all clause |
| agent_event_feed_test (unchanged) | green | — guard that deck labels did not change |

## Completion and handoff

- [ ] Catalogue merged with DESIGN-E4's visibility table cited.
- Dependents: MP-E4-C5-T03 (filters), MP-N6 (notification deep links name kinds).
- Docs: the kinds and their meaning go into the C8-T02 concepts page.
