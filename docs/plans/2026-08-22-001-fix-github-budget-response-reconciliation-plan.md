---
title: GitHub Budget Response Reconciliation - Plan
type: fix
date: 2026-08-22
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# GitHub Budget Response Reconciliation

## Goal Capsule

Keep the host-local GitHub guard aligned with GitHub's billable rate windows: conditional `304` responses must not consume hourly actor budget, contradictory local holds must become visible to the Executor, and a local hold must defer the claimed ticket without spending tracker retries or surrendering its claim.

The change is complete when the broker reconciles completed admissions, the daemon and shell transport paths report the response outcome, local-vs-authoritative disagreement alerts are transition-deduplicated, local holds retain claims, and the default actor allocations fit the credential budget assumed by the documented eight-agent fleet.

## Product Contract

### Problem frame

The broker currently persists every admitted request for one hour. GitHub, however, prices an unchanged conditional request at zero. A conditional-request-heavy fleet can therefore hit its local actor ceiling while the same credential's fresh `/rate_limit` receipt shows almost all quota remaining. The resulting `{:aiur, :locally_held, hold}` is then counted as a tracker retry failure, so three self-clearing local holds release the issue claim.

### Requirements

- **R1 — Billable response accounting:** Keep admission and lease accounting for concurrency, coalescing, request-per-minute pacing, and stagger behavior, but remove the completed admission from hourly spend when the response is `304`.
- **R2 — Complete transport coverage:** Reconcile responses from both the Elixir transport and the agent-side `gh api` wrapper. Reconciliation must be idempotent and safe against an old database or a lease that has already disappeared.
- **R3 — Authoritative disagreement:** When an actor/shared hourly hold contradicts a fresh GitHub window for the same stable credential key and resource by more than a five-percent-of-limit margin, emit a needs-attention alert naming both meters. Deduplicate within the credential/resource/reset window and rearm after convergence or window rotation.
- **R4 — Claim preservation:** Treat `{:aiur, :locally_held, hold}` as backpressure. Retain the issue claim, do not increment `retry_poll_failures`, and schedule a bounded retry informed by the hold reset.
- **R5 — Safe default allocation:** Re-derive the per-agent defaults so the daemon reservation plus eight simultaneously configured agents fits a 5,000-unit GitHub resource window: Core `3000 + 8 * 250`, GraphQL `2000 + 8 * 375`. Explicit operator overrides remain supported.
- **R6 — Compatibility:** Existing broker databases migrate in place; token and consumer identities remain fingerprints; broker unavailability remains fail-closed; non-304 responses and genuine tracker failures retain their current behavior.

### Acceptance examples

- **AE1:** With actor Core limit `1`, acquire a REST request, observe a `304`, release it, then acquire again. The second acquire succeeds and broker hourly usage is zero after each refund.
- **AE2:** Replacing the refund condition with “never refund” makes AE1 fail.
- **AE3:** A fresh same-credential Core receipt reports `used=224/5000` while the local meter is over its actor limit by more than 250. One needs-attention alert is emitted for that credential/resource/reset window; repeat holds do not spam it.
- **AE4:** A retry poll returning a local hold leaves the claim present, preserves the prior failure count, and queues a future retry. Three such holds still do not release the claim.
- **AE5:** A genuine tracker error still increments the failure count and releases under the existing exhaustion policy.

### Scope boundaries

- Do not duplicate the timeline-fetch amplification fix owned by #2234.
- Do not change GitHub primary/secondary-rate-limit interpretation or GraphQL cost attribution.
- Do not remove request-per-minute pacing for `304`s; that meter controls traffic, not GitHub hourly spend.
- Do not introduce a new operator-facing config key.

## Planning Contract

### Key technical decisions

- **KTD1 — Link and price each admission:** Add nullable `lease_id` and a billable flag to `admissions`, generate the lease id before both inserts in the same `BEGIN IMMEDIATE` transaction, and associate the rows immutably. A new idempotent broker refund command marks only that linked admission unbilled. Actor-hour queries count billable admissions; request-per-minute queries continue counting every network attempt. The admission, lease, and cache claim otherwise keep their normal lifetimes, preserving traffic pacing and inflight/single-flight semantics.
- **KTD2 — Reconcile before release:** Extend `Budget.observe` to receive the lease, refund a successful response whose status is `304`, and then preserve the existing rate-hold observation. The shell wrapper parses the captured `HTTP/... 304` status and issues the same refund before release.
- **KTD3 — Compare receipts, not call estimates:** Use `CredentialHeadroom` only when its observation is fresh and keyed by the same credential/resource. Compare the local actor's billed admission count with GitHub's `used`; alert when the positive gap exceeds `max(1, ceil(limit * 0.05))`.
- **KTD4 — Transition-owned alert lifecycle:** Store the active disagreement signature in the credential-headroom owner (credential/resource/reset). Emit once on crossing, resolve/rearm on convergence or a new reset window, following the existing auth-preflight cause-signature pattern.
- **KTD5 — Non-failure retry class:** Intercept local holds before the generic retry-poll failure counter. Use a dedicated non-counting delay type and a reset-aware, bounded retry delay so the orchestrator rechecks without a busy loop and never releases the claim solely for local backpressure.
- **KTD6 — Defaults describe billed responses:** Update code comments and docs from “admitted requests” to billed responses after reconciliation. Set per-agent defaults to Core `250` and GraphQL `375`, derived from the existing daemon reservations and an eight-agent fleet against separate 5,000-unit credential windows.

### Risks and mitigations

- **Migration race or partial linkage:** `ALTER TABLE` is idempotent; legacy admissions default to billable and have no lease id, so they cannot refund and age out pessimistically. Fresh acquire inserts both linked rows in one transaction, and old wrapper processes can still write the original column set.
- **Double reconciliation:** The refund updates the linked admission's billable flag to zero; a repeated call is a no-op.
- **False disagreement alerts:** Require a fresh same-key headroom window and a five-percent margin; key alert state to reset time and clear it when the meters converge.
- **Long reset timers:** Bound the retry interval by the orchestrator's existing retry backoff ceiling while preserving the authoritative reset as metadata.
- **Shell status parsing:** Test the real wrapper capture shape with the fake `gh --include` response headers, including a `304` response.

## Implementation Units

### U1 — Reconcile billable admissions

**Goal:** Make a completed `304` free in local hourly budget without changing inflight coordination.

**Files:**

- `src/priv/github_budget.py`
- `src/lib/aiur/github/budget.ex`
- `src/lib/aiur/github/transport.ex`
- `src/priv/github_quota_guard.sh`
- `src/test/aiur/github/budget_test.exs`
- `src/test/aiur/github/transport_quota_test.exs`
- `src/test/aiur/agent_github_guard_test.exs`

**Approach:** Implement KTD1 and KTD2 test-first. Expose billed-response usage through the existing snapshot/usage surfaces, not a parallel ledger. Keep RPM queries on all admissions, including reconciled `304`s, because that meter controls network traffic; only actor-hour spend filters to billable admissions. Keep the lease live until release.

**Verification:** AE1 and AE2 execute through the public `Budget.acquire/observe/release` path; the shell regression executes the installed guard path twice at limit one.

### U2 — Surface authoritative meter disagreement

**Goal:** Alert instead of silently trusting a contradictory local hold.

**Files:**

- `src/lib/aiur/github/budget.ex`
- `src/lib/aiur/github/credential_headroom.ex`
- `src/test/aiur/github/budget_test.exs`
- `src/test/aiur/github/credential_headroom_test.exs`

**Approach:** On an actor/shared hourly hold, query local usage for the exact token/consumer/resource and compare it with a fresh `CredentialHeadroom` window. Implement KTD3/KTD4 with injectable alert hooks for deterministic tests. Include local used/limit, GitHub used/limit, resource, and reset in the alert reason; never log a raw token or workspace path.

**Verification:** AE3 plus tests for stale/wrong-resource windows, within-margin gaps, deduplication, recovery, and rearm.

### U3 — Defer local holds without releasing claims

**Goal:** Route local budget backpressure around tracker failure exhaustion.

**Files:**

- `src/lib/aiur/orchestrator/retry_engine.ex`
- `src/test/aiur/orchestrator/retry_engine_test.exs`
- `src/test/aiur/regression/orchestrator_dispatch_retry_test.exs`

**Approach:** Add the KTD5 local-hold clause before `handle_retry_poll_failure/5` increments its counter. Preserve claim and attempt metadata, store the hold resource/reset, and schedule a non-counting retry. Leave terminal membership and genuine provider-failure paths unchanged.

**Verification:** AE4 and AE5, including three consecutive local holds.

### U4 — Re-derive and document actor defaults

**Goal:** Make the shipped defaults internally consistent with the credential window.

**Files:**

- `src/lib/aiur/config/schema/tracker.ex`
- `src/lib/aiur/github/budget.ex`
- `src/test/aiur/config/schema_test.exs`
- `src/examples/workflows/github-codex.yaml`
- `src/examples/workflows/github-claude.yaml`
- `website/docs-app/reference/configuration.md`

**Approach:** Apply KTD6 consistently to schema defaults, fallback defaults, examples, tests, and the configuration reference. State the eight-agent derivation and that explicit overrides must reserve capacity across all actors sharing the credential.

**Verification:** Schema default and explicit-override tests pass; config documentation checker sees unchanged keys with corrected defaults.

## Verification Contract

Run from `src/` unless noted:

1. `mise exec -- mix compile --warnings-as-errors`
2. `mise exec -- mix format --check-formatted` after formatting touched files with `mise exec -- mix format`
3. `mise exec -- mix test --max-cases 4 test/aiur/github/budget_test.exs test/aiur/github/transport_quota_test.exs test/aiur/github/credential_headroom_test.exs test/aiur/agent_github_guard_test.exs test/aiur/orchestrator/retry_engine_test.exs test/aiur/regression/orchestrator_dispatch_retry_test.exs test/aiur/config/schema_test.exs`
4. From the workspace root, `cd src && mise exec -- mix aiur.affected_tests`; run every emitted affected-test command with `--max-cases 4`.
5. Inspect `git diff --check` and the final diff against `main`. Manual `aiurdev --test` is not required for this non-UI change and is prohibited inside an agent workspace.

## Definition of Done

- All R1–R6 and AE1–AE5 are covered by executable tests that were observed running.
- A mutation that disables the `304` refund fails the public budget regression.
- Existing databases migrate without losing leases, policies, or admissions.
- Local holds retain claims and do not burn tracker retry failures.
- Disagreement alerts are same-credential, margin-gated, needs-attention, deduplicated, and rearmed after recovery/window change.
- Defaults, workflow examples, and configuration docs agree on Core `250` / GraphQL `375` per agent and explain the eight-agent reservation.
- Scoped compile, format, tests, affected-tests, deletion guard, draft PR self-review, and CI handoff complete against `main`.
