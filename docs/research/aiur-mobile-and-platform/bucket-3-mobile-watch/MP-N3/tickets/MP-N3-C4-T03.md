---
ticket_id: MP-N3-C4-T03
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Row tap opens the instance dashboard in the WebView; secondary Executor-chat button gated by capability"
status: blocked
blocked_by: [DESIGN-N3, DESIGN-N1, DESIGN-E3, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C6-T02, MP-N1-C4-T02, MP-N1-C3-T01, MP-N3-C4-T02, MP-E3-C6-T1]
prior_units: [U6]
prior_boundaries: [WEB]
prior_features: [MP-N1, MP-N2, MP-E3]
prior_findings: [RC-15]
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T03 — Navigation to the instance dashboard and Executor chat

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4.
- **User value:** tapping an instance lands on its own dashboard (the default view), and Executor
  chat is one secondary tap away only when the instance supports it. The per-instance inbox stays
  where it is; there is no combined inbox.
- **Deliverable:** row tap → `navigate("instance", {instanceId, path: "/"})` handled by the MP-N1
  WebView host; a secondary "Executor chat" button → `navigate("instance", {instanceId, path:
  <executor route from the capability entry>})`; when `dashboard.reachable_for_devices` is false
  the row shows the reason instead of navigating.
- **Non-goals:** the WebView host itself (MP-N1-C4-T02), the device-session bootstrap
  (MP-N2-C6-T02), the Executor surface (MP-E3-C6).

## Dependencies and blockers

- RC-15: loads a dashboard in a WebView → **RQ-TRANSPORT** and **MP-N2-C10-T01** (HTTPS device URL).
- MP-N2-C6-T02 (device session), MP-N1-C4-T02 (WebView host), MP-N1-C3-T01 (resolver for the
  "Open instance dashboard" and "Executor chat button" affordances, client-capability-model.md §5).
- MP-E3-C6-T1 (Executor route) and DESIGN-E3; until then the button is hidden (capability
  `executor.conversation` is `unavailable: executor_not_managed`, MP-R1 capability-matrix.md).

## Verified starting point (base `45a290e3`)

- Instance dashboard routes: `/`, `/commands`, `/commands/:decision_id`, `/build-orders/:root_number`
  (`src/lib/aiur_web/router.ex:139-148`). No Executor route exists yet.
- Contract §6.3: `dashboard.url` is the device URL; `reason ∈ {loopback_only, not_bound,
  device_auth_off, tls_unavailable, cleartext_not_allowed, unknown}`.

## Chosen design

| Affordance state (resolver) | Row tap | Executor button |
|---|---|---|
| `ready` | open WebView at `dashboard.url` + `/` | shown if `executor.conversation` ready |
| `degraded` (`http_degraded`) | open, with the MP-N1 persistent warning | as above |
| `unavailable` with reason | no navigation; inline reason key (one per closed reason) | hidden |
| `unreachable` / `stale` | no navigation; "can't reach" with Retry (MP-N1 surface 17 link) | hidden |
| `unknown` | no navigation; "unknown" + Diagnostics link | hidden |

The route path for Executor chat is read from the capability entry (`executor.conversation.route`,
requested from MP-E3/MP-R1 — see CONTRACT-REQUESTS.md), never hard-coded.

## Implementation steps

1. Row `onPress` and secondary button; reason-key mapping. 2. Navigation params. About 90 lines.

## Non-happy paths

Session bootstrap fails (MP-N1 host retries once, then pairing error); device URL changed since
the list loaded (host re-resolves by `instance_id`); instance went `stopped` between list and tap
(host shows "can't reach"; list refreshes).

## Compatibility and rollout

App-internal.

## Verification

`packages/aiur-mobile/src/screens/meta/__tests__/navigation.test.tsx` (navigation mocked):

1. `"ready row navigates to / of that instance"`.
2. `"reachable_for_devices false shows its reason and does not navigate"` — one case per reason.
   Mutation: navigate anyway → fails.
3. `"unknown reason renders unknown, not loopback_only"`. Mutation: default to `loopback_only` → fails.
4. `"executor button hidden when capability unavailable, shown when ready"`.
5. `"no screen lists commands from two instances"` (route inventory test over the route table).

```bash
npm --prefix packages/aiur-mobile test -- src/screens/meta/__tests__/navigation.test.tsx
```

Device (iPhone iOS 17.x and 26.x; Android 13+ Pixel-class): with HTTPS (MP-N2-C10-T05 TR-1 setup),
tap each of two instances; confirm the dashboard loads without a password prompt (MP-N1 AC3) and
Back returns to the list.

## Completion and handoff

- [ ] Tests pass with mutation checks; device steps recorded.
- [ ] Docs: mobile guide "Opening an instance" (why "Open dashboard" can be unavailable).
- [ ] Dependents: MP-N6 (notification routes reuse the instance route).
