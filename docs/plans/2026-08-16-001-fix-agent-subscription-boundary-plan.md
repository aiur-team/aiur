---
title: "fix: Enforce the agent subscription boundary"
created_at: 2026-08-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Enforce the Agent Subscription Boundary

## Goal Capsule

- **Objective:** Prevent ticket agents from observing Executor control-plane or fleet-wide event traffic while preserving explicit watches of individual tickets.
- **Authority:** Issue #2031 and the repository's existing trusted-publisher boundary are authoritative; existing automatic own-ticket, base-branch, CI, review, and blocker bindings remain unchanged.
- **Stop conditions:** Do not weaken the Executor namespace or the generic exchange, and do not remove valid automatic subscriptions.
- **Tail ownership:** Implementation includes persisted-state cleanup, regression tests, skill/docs corrections, scoped validation, and PR self-review.

---

## Product Contract

### Summary

Agent-created subscriptions become ticket-scoped. The low-level exchange remains principal-neutral, while the agent tool rejects patterns that could span the fleet or match the Executor namespace. Persisted unsafe manual bindings are removed and reported when a ticket store attaches.

### Problem Frame

`aiur_subscribe` currently applies only topic syntax checks before persisting `manual:agent` bindings. A less-trusted ticket agent can therefore bind `executor.#`, `#`, or another wildcard-rooted pattern and receive control-plane or fleet-wide traffic. The Executor is separately constrained, so enforcing this at the generic exchange would conflate principals and break trusted consumers.

### Requirements

- **R1. Agent boundary:** A manual agent subscription must name one literal ticket identifier under `ticket.<id>...`; `executor.*`, `system.*`, bare wildcards, wildcard ticket identifiers, and arbitrary namespaces are refused.
- **R2. Legitimate watches:** Per-ticket patterns such as `ticket.42.#` and exact per-ticket topics continue to work.
- **R3. Automatic compatibility:** Existing own-ticket, CI, review, base-branch, and blocker auto-subscriptions remain unchanged because they do not enter through the manual agent policy.
- **R4. Persisted state:** On store attach, previously persisted unsafe `manual:agent` entries are pruned before Exchange registration, persisted back to disk, and reported in a warning that identifies the ticket and removed topics.
- **R5. Unsubscribe cleanup:** Unsubscribe remains able to remove any syntactically valid exact pattern so legacy entries can still be cleaned up explicitly.
- **R6. Documentation:** The agent skill and coordination docs describe the ticket-scoped manual policy and no longer advertise fleet-wide patterns.

### Acceptance Examples

- **AE1:** Given `executor.#`, `#`, `*`, `ticket.*.branch.push`, or `system.main.branch.push`, when an agent calls `aiur_subscribe`, the tool returns a policy error and never calls the subscriber closure.
- **AE2:** Given `ticket.42.#` or `ticket.42.branch.push`, the tool calls the subscriber closure and returns success.
- **AE3:** Given a persisted unsafe `manual:agent` binding beside valid automatic and ticket-scoped entries, attaching the store removes only the unsafe manual entry, writes the cleaned snapshot, and registers only retained topics.
- **AE4:** Given an unsafe legacy pattern, `aiur_unsubscribe` still forwards it to the cleanup closure.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — Enforce at the principal-aware boundary.** Put the reusable policy beside event subscriptions and invoke it from the agent dynamic tool. Keep `Aiur.Events.Exchange` syntax-only because Executor and system consumers legitimately use other namespaces and broad bindings.
- **KTD2 — Allow literal per-ticket watches only.** A literal `ticket.<id>` prefix preserves the documented sibling-ticket watch use case without granting fleet-wide access through one binding or access to trusted namespaces. Authorization of which unrelated tickets an agent may watch is a separate policy question; this change narrows each binding but does not add relationship checks or quotas.
- **KTD3 — Migrate by reason.** Prune only persisted entries whose reason is `manual:agent`; automatic and trusted bindings retain their current behavior even when their namespace is outside the manual allowlist.
- **KTD4 — Fail closed before side effects.** Policy validation precedes the injected subscriber callback and persistence path, so rejected patterns cannot transiently bind or survive restart.

### Scope Boundaries

- The Executor binding allowlist and blocking listener work in #2030 remain separate.
- This change does not alter AMQP wildcard matching or publishing permissions.
- No current or historical active-run subscription file inspected on 2026-08-16 contained a `manual:agent` or over-broad agent binding; startup pruning protects installations where one does exist.

### Risks & Dependencies

- A compromised agent can still accumulate visibility by adding many literal per-ticket watches. The existing tool intentionally supports non-blocker sibling-ticket watches, and issue #2031's acceptance boundary targets Executor/fleet wildcard bindings rather than introducing relationship authorization or a manual-subscription quota.

### Sources & Research

- `src/lib/aiur/codex/dynamic_tool/subscriptions.ex` owns the agent tool's current syntax-only validation.
- `src/lib/aiur/agent_runner/tool_executor.ex` assigns the `manual:agent` persistence reason.
- `src/lib/aiur/events/subscription_store.ex` restores persisted bindings before returning from attach.
- `src/lib/aiur/orchestrator/auto_subscriptions.ex` and `src/lib/aiur/events/universal_subscriptions.ex` define legitimate automatic topics.
- No `CONCEPTS.md` or `docs/solutions/` institutional-learning corpus exists in this checkout. External research was skipped because this is a repository-specific principal policy with established local exchange and persistence patterns.

---

## Implementation Units

### U1. Define and enforce the manual agent policy

- **Goal:** Reject unsafe new agent bindings before calling the persistence closure.
- **Requirements:** R1, R2, R5
- **Files:** `src/lib/aiur/events/agent_subscription_policy.ex`, `src/lib/aiur/codex/dynamic_tool/subscriptions.ex`, `src/lib/aiur/codex/dynamic_tool/errors.ex`, `src/test/aiur/codex/dynamic_tool/subscriptions_test.exs`, `src/test/aiur/codex/dynamic_tool/errors_test.exs`
- **Approach:** Add a pure validator for literal ticket-scoped patterns, call it only on subscribe, return a specific tool error explaining the allowed shape, and replace the generated tool description's fleet-wide example with a literal-ticket watch.
- **Test Scenarios:** Accept literal ticket identifiers with exact or wildcard suffixes; reject Executor, system, custom, bare-wildcard, and wildcard-ticket patterns; prove rejection does not invoke the callback; prove unsubscribe still forwards legacy patterns; assert the exposed tool spec no longer advertises forbidden patterns.
- **Verification:** Dynamic-tool subscription and error tests pass.

### U2. Prune and report unsafe persisted manual bindings

- **Goal:** Ensure an upgrade cannot re-register a binding the new tool would refuse.
- **Requirements:** R3, R4
- **Files:** `src/lib/aiur/events/subscription_store.ex`, `src/test/aiur/events/subscription_store_test.exs`
- **Dependencies:** U1
- **Approach:** Filter loaded `manual:agent` entries through the shared policy before Exchange registration, persist only when pruning changes state, and log the removed topics with the ticket identifier. If cleanup persistence fails, retain the safe filtered in-memory state, never register removed topics, report the write failure, and allow attach to continue so a later attach retries cleanup.
- **Test Scenarios:** A mixed persisted snapshot retains automatic and valid manual bindings, removes unsafe manual bindings, writes the cleaned disk state, and never registers removed topics; a clean snapshot is unchanged; a cleanup write failure still prevents unsafe Exchange registration without making the entire store unavailable when the persistence seam can be exercised without broad refactoring.
- **Verification:** Subscription-store and auto-subscription tests pass.

### U3. Correct the documented agent contract

- **Goal:** Make agent-facing guidance match the enforced boundary.
- **Requirements:** R6
- **Files:** `.claude/skills/aiur-agent/SKILL.md`, `.claude/skills/aiur-agent/overview.md`, `.claude/skills/aiur-agent/emit-and-subscribe.md`, `website/docs-app/concepts/coordination.md`
- **Dependencies:** U1
- **Approach:** Replace fleet-wide examples with literal sibling-ticket watches and state that Executor, system, wildcard-rooted, and wildcard-ticket patterns are unavailable to agents.
- **Test Scenarios:** Documentation searches find no agent guidance advertising `*.*.branch.push`; existing Executor CLI documentation remains unchanged.
- **Verification:** Documentation diff matches the implemented policy.

---

## Verification Contract

| Gate | Command / evidence | Covers |
|---|---|---|
| Compile | `cd src && mise exec -- mix compile --warnings-as-errors` | U1-U2 |
| Format | `cd src && mise exec -- mix format --check-formatted` | U1-U2 |
| Deterministic scope | `cd src && mise exec -- mix aiur.affected_tests` | U1-U3 |
| Affected tests | Run every emitted test command with `mix test --max-cases 4` | U1-U2 |
| Contract audit | Search the generated tool description and agent skill/docs for obsolete fleet-wide subscription examples | U1, U3 |

---

## Definition of Done

- All R1-R6 requirements and AE1-AE4 examples are covered by implementation or tests.
- Rejected subscribe requests have no callback or persistence side effect.
- Persisted unsafe manual bindings cannot re-register after attach and are visibly reported.
- Automatic subscription tests remain green.
- The scoped compile, format, and affected-test gates pass.
- The final diff contains no abandoned policy variants or unrelated #2030 changes.
