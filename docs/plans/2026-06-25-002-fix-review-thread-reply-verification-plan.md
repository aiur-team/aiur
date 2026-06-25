---
title: "fix: Verify review thread replies"
type: "fix"
date: "2026-06-25"
---

# fix: Verify review thread replies

## Summary

Add an Aiur-native GitHub review-thread reply path that posts a reply, logs the GraphQL result, re-fetches the exact thread, and only reports success when the latest thread comment is the agent's reply. Prevent the ticket from moving to human review while handled review threads remain unverified.

---

## Problem Frame

Issue #643 reports a live dogfood failure where an agent attempted ten PR review-thread replies, but only seven persisted on GitHub. The missing replies were still latest-authored by the reviewer, so Aiur needs a read-after-write postcondition instead of trusting an attempted command, agent narration, event emission, or generic GraphQL response success.

---

## Requirements

- R1. GitHub review-thread events must include the stable review thread node id (`PRRT_...`) so agents can reply to the exact thread and deduplicate thread work even when comment `databaseId` is nil.
- R2. Aiur must expose a first-class `aiur_reply_review_thread` dynamic tool that posts an `addPullRequestReviewThreadReply` mutation and returns the raw mutation/query response details needed for diagnosis.
- R3. A reply is successful only when re-fetching the exact thread shows the latest comment was authored by the configured agent account and its body matches the requested reply.
- R4. The reply helper must retry boundedly on transient postcondition mismatches or GitHub connectivity failures and return a classified error when verification never succeeds.
- R5. A ticket must not transition to `agent:human-review` while its current open PR has actionable review threads whose latest comment is still from an authoritative reviewer.

---

## Key Technical Decisions

- **Verify in the GitHub client, not in prompts:** The postcondition belongs next to the GraphQL mutation so every agent surface receives the same behavior and error payload.
- **Use review thread node ids as the unit of work:** Thread node ids are stable across replies, while review comment database ids can be nil in the GraphQL path.
- **Guard human-review through tracker state updates:** Agents move issues by label, so the GitHub tracker update path is the narrow structural point where Aiur can refuse a premature ready-for-review transition.
- **Reuse the existing GitHub error taxonomy:** `Aiur.GitHub.Client.classify_error/1` already distinguishes DNS, timeout, TLS, auth, rate limit, and HTTP failures, so this plan uses that shape instead of inventing a second taxonomy.

---

## Implementation Units

### U1. Carry review thread ids through fetched comments

- **Goal:** Include the GraphQL review thread node id in unaddressed review-thread comment payloads and deduplicate those events by thread id.
- **Requirements:** R1.
- **Dependencies:** None.
- **Files:** `src/lib/aiur/github/client.ex`, `src/lib/aiur/events/github_comments_poller.ex`, `src/test/aiur/github_client_test.exs`, `src/test/aiur/events/github_comments_poller_test.exs`.
- **Approach:** Add `id` to the `reviewThreads.nodes` selection, copy it into normalized thread comments as `review_thread_id`, and prefer that id for the unaddressed-thread poller's dedup key.
- **Patterns to follow:** Existing `normalize_thread_comment/2`, `GithubKeys.comment_dedup_key/4`, and the current unaddressed-thread poller tests.
- **Test scenarios:** A fetched unresolved authoritative thread includes `review_thread_id`; the poller deduplicates unaddressed thread events by thread id when comment `id` is nil.
- **Verification:** Existing PR review comment polling still publishes under `ticket.<id>.pr.review_comment`.

### U2. Add verified GitHub review-thread reply helper

- **Goal:** Add a GitHub client function that posts to a review thread and verifies the latest thread comment with bounded retry.
- **Requirements:** R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `src/lib/aiur/github/client.ex`, `src/test/aiur/github_client_test.exs`.
- **Approach:** Add `addPullRequestReviewThreadReply` and single-thread re-query GraphQL operations. Return `{:ok, %{verified: true, ...}}` only when the latest comment author matches the configured bot account and body matches the submitted body; otherwise retry a small fixed budget and return `{:error, {:review_thread_reply_not_verified, detail}}`.
- **Patterns to follow:** Existing `github_graphql/4`, request-fun injection in `github_client_test.exs`, and `classify_error/1` for transport/HTTP failures.
- **Test scenarios:** Successful mutation plus re-query verifies latest agent reply; mutation GraphQL errors return a failure with errors preserved; latest reviewer comment after mutation exhausts retries and returns a classified verification error; transient GitHub transport errors use the existing taxonomy.
- **Verification:** Tests assert the request bodies contain the mutation, the thread re-query, and diagnostic response payloads.

### U3. Expose `aiur_reply_review_thread` dynamic tool

- **Goal:** Give Codex and Claude agents a dedicated tool that uses U2 instead of asking them to hand-roll GitHub GraphQL.
- **Requirements:** R2, R3, R4.
- **Dependencies:** U2.
- **Files:** `src/lib/aiur/codex/dynamic_tool.ex`, `src/test/aiur/dynamic_tool_test.exs`.
- **Approach:** Add a tool spec with `review_thread_id` and `body`, execute it through an injectable GitHub reply function, and return success only for the verified client result.
- **Patterns to follow:** Existing dynamic tool specs and `execute_linear_graphql/2` delegation shape.
- **Test scenarios:** Tool specs advertise the new contract; a verified reply returns success with the verification payload; an unverified or unavailable helper returns `success: false` with the classified error.
- **Verification:** `DynamicTool.supported_tool_names/0` includes `aiur_reply_review_thread`.

### U4. Refuse premature human-review transitions

- **Goal:** Prevent `agent:human-review` label transitions when actionable review threads remain latest-authored by an authoritative reviewer.
- **Requirements:** R5.
- **Dependencies:** U1, U2.
- **Files:** `src/lib/aiur/github/client.ex`, `src/test/aiur/github_client_test.exs`.
- **Approach:** Before applying the `human-review` state update, find the open PR for `aiur/<issue>`, fetch unaddressed review-thread comments, and refuse the state update if any remain. Keep non-human-review state updates unchanged.
- **Patterns to follow:** Existing `update_issue_state/3`, `fetch_open_pull_request_for_branch/2`, and injected request-fun tests.
- **Test scenarios:** Human-review transition is refused when unaddressed authoritative review threads remain; human-review transition proceeds when no open PR exists or no unaddressed threads remain; non-human-review transitions do not perform the guard query; GitHub fetch errors abort the transition instead of silently allowing it.
- **Verification:** Focused GitHub client tests prove the guard runs before label swapping.

---

## Scope Boundaries

- This plan does not implement GitHub workspace connectivity preflight from #617 beyond reusing the already-present error taxonomy.
- This plan does not add a second comment poller or redesign review-comment reactivation.
- This plan does not change CODEOWNERS trust rules; it relies on the current authoritative-review classification.

---

## Risks & Dependencies

- The human-review guard runs from the GitHub tracker state-update path, so Linear and memory trackers remain no-ops for review-thread verification.
- Verification compares the latest comment author to the configured bot account; misconfigured `github.bot_account` will make replies fail closed.
- GitHub GraphQL can be eventually consistent after mutation, so the helper uses bounded retry rather than a single re-query.
