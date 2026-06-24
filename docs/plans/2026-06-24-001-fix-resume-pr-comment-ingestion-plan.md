---
title: fix: Resume PR comment ingestion
type: fix
status: active
date: 2026-06-24
---

# fix: Resume PR comment ingestion

## Summary

This plan fixes missed GitHub comments when an Aiur agent starts or resumes after the comment was posted. It keeps the existing event digest model, but makes PR review comments address the originating ticket and lets fresh own-comment subscriptions replay already-recorded comment events.

---

## Requirements

- R1. A PR review comment on a PR whose head is `aiur/<ticket>` must route to `ticket.<ticket>.pr.review_comment`, not the PR number.
- R2. A fresh agent subscription to its own issue or PR comment topics must be able to replay already-recorded matching events at resume/start.
- R3. GitHub-sourced comment content must keep the existing sanitizer, CODEOWNERS trust, and `<external-content>` prompt isolation behavior.
- R4. The fix must include a regression shaped like ticket #35 / PR #49: the PR number differs from the ticket number.

---

## Scope Boundaries

- No new GitHub polling surface beyond the existing firehose and issue-log replay model.
- No changes to user-authored prompt instructions or the agent workflow loop.
- No broad terminal-action gate in this PR; this plan addresses the comment delivery path the terminal race depends on.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/events/github_firehose.ex` already re-keys PR-conversation `IssueCommentEvent` payloads through `fetch_pull_request_head_ref/1`.
- `src/lib/aiur/agent_runner.ex` auto-subscribes every agent to `ticket.<self>.issue.commented` and `ticket.<self>.pr.review_comment`, then builds a bootstrap digest from per-issue event logs.
- `src/lib/aiur/issue_log.ex` preserves `[event:emit]` source/trust flags so replayed GitHub comments still respect digest filtering.
- `src/test/aiur/events/github_firehose_test.exs` has the exact pattern for PR comment re-keying tests.

### Institutional Learnings

- `docs/plans/2026-05-27-001-feat-subscriptions-and-inbox-plan.md` defines bootstrap digest replay as the existing agent-facing missed-event mechanism.
- `docs/plans/2026-05-28-001-feat-deactivated-state-plan.md` records the distinction between PR review comments and issue/PR conversation comments.

---

## Key Technical Decisions

- Reuse the PR head-ref resolver for `PullRequestReviewCommentEvent`; this makes review comments match the ticket branch contract already used by PR open/merge events and PR-body comments.
- Add direct startup comment context from the current issue and its open `aiur/<ticket>` PR; this covers comments that never entered Aiur's firehose logs while the app or agent was offline.
- Keep event-log replay for durable event-bus gaps; current comments are delivered as synthetic `events_digest` entries so the agent-facing format, sanitizer, and CODEOWNERS filter remain unchanged.

---

## Implementation Units

### U1. Re-key PR review comments

**Goal:** Route `PullRequestReviewCommentEvent` to the ticket id derived from the PR head branch.

**Requirements:** R1, R3, R4

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/events/github_firehose.ex`
- Test: `src/test/aiur/events/github_firehose_test.exs`

**Approach:**
- Mirror the existing `IssueCommentEvent` PR resolution path for review comments.
- Keep fallback-to-raw-PR-number behavior when lookup fails or the head ref is not canonical.
- Preserve the existing publish options: actor, contamination behavior, and dedup key.

**Patterns to follow:**
- `resolve_comment_ticket_id/3` in `src/lib/aiur/events/github_firehose.ex`

**Test scenarios:**
- Happy path: PR #49 with head `aiur/35` publishes `ticket.35.pr.review_comment`.
- Error path: lookup failure keeps publishing `ticket.49.pr.review_comment`.
- Edge case: non-`aiur/<id>` head ref keeps publishing `ticket.49.pr.review_comment`.

**Verification:**
- Focused firehose tests pass.

### U2. Replay fresh own-comment subscriptions

**Goal:** Let resume/start bootstrap include existing own issue and PR comments even when they were posted before the agent subscribed or while Aiur was offline.

**Requirements:** R2, R3

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/agent_runner.ex`
- Test: `src/test/aiur/agent_runner_test.exs`

**Approach:**
- Add a test-facing helper around startup comment event selection so regression tests do not need to spin up the full runner.
- When `last_seen_event_id` exists, keep the current cursor-based replay.
- Fetch current issue comments, open-PR conversation comments, and open-PR review comments for `aiur/<ticket>` at startup and render them as synthetic digest events.

**Patterns to follow:**
- `bootstrap_events/2` and `publisher_ids_for_patterns/1` in `src/lib/aiur/agent_runner.ex`
- `Aiur.IssueLog.event_history/2` parsing and filtering

**Test scenarios:**
- Happy path: ticket #35 with PR #49 includes issue comments, PR conversation comments, and PR review comments under ticket #35 topics.
- Edge case: no open PR skips PR-specific fetches.
- Error path: fetch failures log and do not block the agent run.
- Security path: fetched comment bodies are sanitized before rendering.

**Verification:**
- Focused AgentRunner tests pass.

---

## System-Wide Impact

- **Interaction graph:** GitHub firehose routing feeds `Publisher`, `Exchange`, `SubscriptionStore`, `Orchestrator` queueing, and `AgentRunner` digest rendering.
- **Error propagation:** PR lookup failures continue to degrade to the previous raw-number topic rather than dropping comments.
- **State lifecycle risks:** Fresh bootstrap replay must avoid replaying unrelated historical events; limiting the nil-cursor path to own comment topics bounds the blast radius.
- **Unchanged invariants:** Sanitizer and CODEOWNERS trust remain downstream of routing and are not bypassed.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Existing users rely on raw PR-number review-comment topics | Keep fallback when branch resolution fails; canonical Aiur branches now receive the intended ticket topic |
| Fresh-subscription replay creates old-event noise | Limit nil-cursor replay to own comment topics and each binding's event-id floor |

---

## Sources & References

- Related issue: #485
- Related code: `src/lib/aiur/events/github_firehose.ex`
- Related code: `src/lib/aiur/agent_runner.ex`
