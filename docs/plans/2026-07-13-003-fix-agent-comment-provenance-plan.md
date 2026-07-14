---
title: fix: Preserve CI wait after agent replies
type: fix
status: active
date: 2026-07-13
---

# fix: Preserve CI wait after agent replies

## Summary

Record the exact GitHub comment identity at every agent-owned public-write
boundary, then carry the durable provenance through bootstrap, live polling,
publisher replay, and wake routing. Comment wake routes will ignore only those
recorded agent replies. A fresh trusted comment from the same shared GitHub
login remains actionable, so CODEOWNERS trust and the normal human-comment
wake path stay intact.

---

## Requirements

- R1. An agent-authored PR conversation or review-resolution comment must not
  move its own `ci-wait` or `human-review` ticket to `rework`.
- R2. A new trusted human comment must still wake the ticket when the human and
  agent use the same GitHub login.
- R3. A terminal CI failure after an agent reply must be observed and emitted
  once while the ticket remains in the CI polling set.
- R4. The provenance decision must be visible in inbound events and lifecycle
  logs without relying on comment-body heuristics.
- R5. The regression must reproduce reply, CI wait, self-comment ingestion,
  then later CI failure.
- R6. Bootstrap and replay paths must treat the production `:agent` origin as
  non-actionable while retaining external comments from the shared login.
- R7. A successful public comment write cannot become visible to the poller
  before its identity is durably recorded; an origin persistence failure must
  be surfaced as actionable.
- R8. Codex, Claude, review-thread, and partial GraphQL reply paths must retain
  the exact mutation identity rather than inferring it from a later fetch.
- R9. A self-comment must not suppress a later human reply in the same review
  thread, and publisher replay must reapply the canonical origin guard.

---

## Scope Boundaries

- Do not configure `github.bot_account` for the shared operator/agent login or
  change `Publisher.bot_self_loop?/1`.
- Do not weaken CODEOWNERS trust, infer origin from a GitHub username, or
  suppress all comments from the shared login.
- Do not change CI terminal-event deduplication; preserve the existing
  ticket/outcome/head behavior once the issue remains eligible for polling.
- Preserve the existing nil-lifecycle, queue-drain, failed-reply, and
  completed-runner repairs already on this branch.

### Deferred to Follow-Up Work

- Provenance for comments created outside Aiur's verified agent reply path.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/github/review_threads/reply.ex` verifies the latest GitHub
  comment and returns its identifier after a successful agent reply.
- `src/lib/aiur/codex/dynamic_tool/review_threads.ex` is the agent-tool seam
  where that verified result can be recorded before success reaches the agent.
- `src/lib/aiur/events/github_comments_poller.ex` constructs the inbound
  issue, PR-conversation, and review-thread comment events.
- `src/lib/aiur/agent_runner/comment_context.ex` rebuilds comment context on
  bootstrap and must normalize the same durable origin shape as live polling.
- `src/lib/aiur/agent_runner/message_handler.ex` observes Codex and Claude
  command streams, while `src/lib/aiur/agent_runner/tool_executor.ex` binds
  ticket-local origin persistence.
- `src/lib/aiur/events/publisher.ex` and
  `src/lib/aiur/events/subscription_store.ex` form the persisted/replayed
  inbound-delivery boundary.
- `src/lib/aiur/orchestrator/comment_wake.ex` makes the trusted-comment
  transition decision; `pr_anchored.ex` and delivery policy reuse its trust
  predicates.
- `src/lib/aiur/orchestrator/ci_lifecycle.ex` polls only `ci-wait` and
  `human-review`, and already deduplicates terminal CI outcomes by head.
- `src/lib/aiur/ci_approval_store.ex` and `src/lib/aiur/json_store.ex`
  demonstrate the repository's durable JSON state pattern.

---

## Key Technical Decisions

| Decision | Rationale |
| --- | --- |
| Match origin by verified comment ID plus ticket, not actor login | The identity is stable across shared-login agent and operator comments. |
| Persist the record before reporting the reply tool as successful | A restart or poll between reply and lifecycle transition must not lose the guard. |
| Attach a positive `agent` origin marker only to exact recorded comments | Unrecorded same-login comments continue through existing CODEOWNERS trust. |
| Centralize comment actionability in `CommentWake` | All lifecycle and routing callers apply the same provenance rule and log reason. |
| Preserve mutation identities across every public-write path | Later shared-login comments must never be mistaken for the agent write. |
| Treat origin persistence failure as a failed agent write | A visible but unrecorded comment is unsafe to report as a successful operation. |

---

## High-Level Technical Design

*This illustrates the intended approach and is directional guidance for review,
not implementation specification. The implementing agent should treat it as
context, not code to reproduce.*

```mermaid
sequenceDiagram
  participant Agent
  participant WriteBoundary
  participant OriginStore
  participant Poller
  participant Wake
  participant CI

  Agent->>WriteBoundary: comment or review reply
  WriteBoundary->>OriginStore: persist exact mutation identity before release
  Poller->>OriginStore: resolve inbound comment identity
  OriginStore-->>Poller: agent origin marker
  Poller->>Wake: trusted comment event with provenance
  Wake-->>Wake: ignore agent-origin comment; retain CI wait
  CI->>Agent: one terminal CI failure event
```

---

## Implementation Units

### U1. Persist verified agent-reply provenance

**Goal:** Durably associate a ticket with the exact comment GitHub verified as
an agent-authored reply.

**Requirements:** R1, R2, R4, R6, R9

**Dependencies:** None

**Files:**

- Modify: `src/lib/aiur/github/agent_comment_origins.ex`
- Modify: `src/lib/aiur.ex`
- Modify: `src/lib/aiur/codex/dynamic_tool/review_threads.ex`
- Test: `src/test/aiur/github/agent_comment_origins_test.exs`
- Test: `src/test/aiur/codex/dynamic_tool/review_threads_test.exs`

**Approach:** Follow the durable JSON store convention to save only the
ticket-scoped verified comment identity and minimal origin metadata. Inject
recording from the review-reply dynamic tool so a successful verified reply is
recorded before it can be followed by the poller.

**Patterns to follow:** `Aiur.CIApprovalStore`, `Aiur.JsonStore`, and the
verified reply result in `Aiur.GitHub.ReviewThreads.Reply`.

**Test scenarios:**

- Happy path: a verified reply stores an exact comment identity for its ticket.
- Edge case: a comment with the same shared-login actor but an unrecorded
  identity is not agent-origin.
- Durability: a newly started store reads a previously written origin record.
- Integration: the dynamic tool calls its recorder only after GitHub verifies
  the reply.

**Verification:** Provenance is durable, exact-ID scoped, and does not use the
GitHub actor as a discriminator.

### U2. Annotate inbound comments and apply the central wake guard

**Goal:** Make agent origin observable on GitHub comment events and prevent it
from taking any trusted-human wake route.

**Requirements:** R1, R2, R4, R6, R9

**Dependencies:** U1

**Files:**

- Modify: `src/lib/aiur/events/github_comments_poller.ex`
- Modify: `src/lib/aiur/agent_runner/comment_context.ex`
- Modify: `src/lib/aiur/events/publisher.ex`
- Modify: `src/lib/aiur/events/subscription_store.ex`
- Modify: `src/lib/aiur/orchestrator/comment_wake.ex`
- Modify: `src/lib/aiur/orchestrator/pr_anchored.ex`
- Modify: `src/lib/aiur/orchestrator/operator_messages/delivery_policy.ex`
- Test: `src/test/aiur/events/github_comments_poller_test.exs`
- Test: `src/test/aiur/agent_runner/comment_context_test.exs`
- Test: `src/test/aiur/events/publisher_test.exs`
- Test: `src/test/aiur/events/subscription_store_test.exs`
- Test: `src/test/aiur/orchestrator/comment_wake_test.exs`

**Approach:** Resolve the inbound comment against durable provenance and add an
explicit origin field to the event payload. Extend the shared comment
actionability predicate so agent-origin events are skipped with a structured,
reason-bearing log while ordinary trusted comments, including those from the
same login, retain their current behavior.

**Patterns to follow:** existing comment sanitization and trust stamping,
`CommentWake.trusted_comment_event?/1`, and caller-side benign-comment checks.

**Test scenarios:**

- Happy path: the poller emits an agent-origin marker for a recorded review
  reply.
- Shared-login path: an otherwise identical unrecorded trusted comment remains
  actionable.
- Lifecycle path: an agent-origin comment does not transition a deactivated
  `ci-wait` or `human-review` ticket to `rework`.
- Observability: the skip reason is present in lifecycle logging and the
  accepted/ignored origin remains present on the event.

**Verification:** Every comment consumer uses the same origin-aware predicate,
and the shared GitHub account is not globally filtered.

### U3. Lock the reply-to-CI-failure ordering in regression coverage

**Goal:** Prove that a self-comment cannot evict the ticket before terminal CI
failure polling and delivery.

**Requirements:** R1, R3, R5

**Dependencies:** U1, U2

**Files:**

- Modify: `src/test/aiur/orchestrator_ci_lifecycle_test.exs`
- Modify: `src/test/aiur/orchestrator_deactivate_test.exs`

**Approach:** Model the production ordering with the ticket held in the CI
wait state after an agent reply, ingest the marked self-comment, then provide
a later failed terminal CI result. Assert the ticket remains pollable and the
waiting agent receives one CI-failed event despite repeated polling.

**Patterns to follow:** existing CI lifecycle terminal-failure and deactivated
comment-wake regressions.

**Test scenarios:**

- Integration: reply provenance, CI wait, self-comment ingestion, and later
  failure leave the ticket in the CI lifecycle path.
- Deduplication: a second poll of the identical failed head does not emit a
  second terminal event.
- Control: a new trusted human comment still triggers existing rework behavior.

**Verification:** Focused lifecycle tests prove one delivery for the retained
CI-wait ticket and preserve the trusted-human transition.

### U4. Make top-level comment writes atomic and backend-neutral

**Goal:** Persist exact provenance for top-level comment writes before the
poller can observe them, including Claude's split command/result stream.

**Requirements:** R1, R4, R7, R8

**Dependencies:** U1

**Files:**

- Modify: `src/lib/aiur/agent_runner/message_handler.ex`
- Modify: `src/lib/aiur/agent_runner/tool_executor.ex`
- Modify: `src/lib/aiur/github/agent_comment_origins.ex`
- Test: `src/test/aiur/agent_runner/message_handler_test.exs`
- Test: `src/test/aiur/agent_runner/tool_executor_test.exs`
- Test: `src/test/aiur/github/agent_comment_origins_test.exs`

**Approach:** Introduce one ticket-bound public-write seam that correlates
command intent with its completion identity for both backend event shapes. Keep
the origin lock across mutation visibility and durable persistence, and return
an actionable failure whenever the public write cannot be recorded.

**Patterns to follow:** `Aiur.GitHub.AgentCommentOrigins.with_lock/1` and the
backend-neutral transcript extraction boundary.

**Test scenarios:**

- Integration: a successful top-level comment is persisted before a concurrent
  poller classification proceeds.
- Error path: parsing or persistence failure after a visible comment produces
  an explicit agent-visible failure.
- Integration: split Claude Bash command and result notifications correlate to
  the same exact persisted comment identity.

**Verification:** No supported backend can report a public comment success
without a durable, ticket-scoped identity record.

### U5. Preserve exact review-thread mutation identities

**Goal:** Record the mutation-returned review reply identity through partial
GraphQL success and read-after-write verification without capturing a later
human comment.

**Requirements:** R1, R2, R7, R8, R9

**Dependencies:** U1, U4

**Files:**

- Modify: `src/lib/aiur/github/review_threads/reply.ex`
- Modify: `src/lib/aiur/codex/dynamic_tool/review_threads.ex`
- Modify: `src/lib/aiur/github/review_threads.ex`
- Test: `src/test/aiur/github/reply_test.exs`
- Test: `src/test/aiur/codex/dynamic_tool/review_threads_test.exs`
- Test: `src/test/aiur/events/github_comments_poller_test.exs`

**Approach:** Carry `published_comment` from GraphQL mutation data even when
errors are present, record that identity before exposing verification failure,
and compare verification against the mutation identity rather than whichever
comment happens to be latest.

**Patterns to follow:** the existing failed-reply provenance result and
`ReviewThreads.Reply.published_comment/1` normalization.

**Test scenarios:**

- Error path: mutation data plus GraphQL errors still records the visible reply
  identity before returning the failure.
- Race: a later shared-login human comment is not recorded as agent origin.
- Integration: an ignored agent reply followed by a human reply in the same
  thread leaves the human reply actionable.

**Verification:** Review-thread retries, partial success, and later human
replies preserve exact provenance and trusted-human wake behavior.

---

## System-Wide Impact

```mermaid
flowchart TB
  A[Verified agent reply] --> B[Durable origin record]
  B --> C[GitHub comment poller]
  C --> D[Comment event with origin]
  D --> E[Comment wake and delivery policy]
  E --> F[Ticket remains ci-wait]
  F --> G[CI lifecycle failure event]
```

- Agent tooling gains a narrow provenance write at the verified GitHub response
  boundary.
- The poller preserves source and CODEOWNERS trust while adding origin context.
- Orchestration consumes that context consistently; CI lifecycle code remains
  responsible only for terminal outcome polling and one-event delivery.

---

## Risks & Mitigation

| Risk | Mitigation |
| --- | --- |
| A process restart loses provenance before polling | Persist the verified comment record before tool success. |
| A human and agent share a login | Match only the stored ticket/comment identity, never the actor. |
| A new comment route bypasses the guard | Reuse the centralized actionability predicate in every current caller. |
| CI event delivery duplicates after retries | Keep and exercise the existing head/outcome deduplication path. |

---

## Assumptions

- The verified response from the supported review-reply tool contains a stable
  GitHub comment identity that matches the poller's comment representation.
- The visible production ordering is represented by current comment wake and
  CI lifecycle test helpers; implementation may refine test placement without
  changing the acceptance scenarios.

---

## Sources & References

- Issue: #1151
- Production evidence: #1087 / PR #1145 (2026-07-14)
- Related code: `src/lib/aiur/events/github_comments_poller.ex`
- Related code: `src/lib/aiur/orchestrator/ci_lifecycle.ex`
