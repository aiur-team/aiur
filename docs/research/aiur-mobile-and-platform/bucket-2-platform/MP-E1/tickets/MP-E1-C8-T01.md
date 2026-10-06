---
ticket_id: MP-E1-C8-T01
feature_id: MP-E1
chunk_id: MP-E1-C8
bucket: 2-platform
title: Read-only build-queue dashboard view with every state
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C6-T01, MP-E1-C7-T02]
prior_units: [U6]
prior_boundaries: [WEB #34]
prior_features: [MP-N3]
prior_findings: [MP-E1 F9]
size_owner: n/a (new LiveView; router/route_registry small)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C8-T01 — Queue view (read-only)

> **Plan refresh (wave 0).** After MP-R1 the view belongs to the `build-queue`
> component's web surface (component map row `build-queue`, dashboard optional).
> **Blocked on the DESIGN-E1 dashboard approval** (§4 and §6): placement,
> layout and every state copy. Do not improvise any of them.

## Identity and outcome

- Bucket 2, MP-E1, C8, T01. D7 (read-only view).
- **User value:** the operator sees every queue, its progress, items in start
  order, why each waits, open attentions and data age, without a terminal.
- **Deliverable:** per DESIGN-E1 placement, either PROPOSED
  `src/lib/aiur_web/live/build_queue_live.ex` at `/queue`, or a panel inside
  `BuildOrderLive` at `/build-orders`; it renders `Aiur.BuildQueue.show/1`
  (same read model as the CLI) and updates on PubSub.

## Dependencies and blockers

- DESIGN-E1 (dashboard approval), C6-T01 (read model), C7-T02 (progress).

## Verified starting point (`45a290e3`)

- Routes: `src/lib/aiur_web/router.ex:144-145` (`/build-orders`).
- Navigation registry: `aiur_web/operator_control_center/route_registry.ex:27-37`
  (id, label, icon, path, owner, availability); test
  `src/test/aiur_web/operator_control_center/route_registry_test.exs`.
- LiveView test precedent: `src/test/aiur_web/live/build_order_live_test.exs`.
- AGENTS.md "Computed ages": a surface that computes an age must render it;
  unknown-path mutation rule.

## Chosen design

- Subscribe to `"build_queue:changed"` (C3-T03) and `"build_progress"`
  (C7-T01); re-read `show/1` on each message (coalesced 500 ms).
- States (DESIGN-E1 §4): loading, empty (CLI hint), disabled,
  unsupported tracker, stale (age shown, readiness dimmed), unknown,
  error (store unavailable / writes paused), every item state from contract
  §2.3, resolved attentions, offline (existing disconnected state).
- Every source line renders `observed_at`, age and freshness.
- No buttons that mutate (D7).

## Implementation steps

1. LiveView (or panel) + function components for queue, item row, chips.
2. Route + `route_registry.ex` entry if a new page.
3. Tests below. Docs and browser checks in C8-T02.

## Non-happy paths

Server absent → `disabled` state; read model call timeout → `unknown` state,
never zeros.

## Compatibility and rollout

Dashboard only; no API change. Respects existing dashboard auth.

## Verification

| Test (`src/test/aiur_web/live/build_queue_live_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| one test per DESIGN-E1 §4 state with a fixture read model | approved copy present | each branch |
| "unknown source renders unknown, never 0 or ready" — then replace the branch with `0` | test fails under replacement | the unknown branch |
| "stale source shows its age" | `age` text from `age_ms` | age rendering |
| "a build_queue:changed message re-renders" | new item appears | the subscription |
| `route_registry_test.exs` (if new page) | registry includes `/queue` | the entry |

Mutation check: as listed (unknown → `0`, drop subscription).

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur_web/live/build_queue_live_test.exs test/aiur_web/operator_control_center/route_registry_test.exs
```

## Completion and handoff

- [ ] Every approved state rendered; ages rendered.
- Dependents: C8-T02; MP-N3 (meta-dashboard counts reuse the read model).
