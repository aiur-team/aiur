---
ticket_id: MP-N1-C4-T06
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: Native header over WebView pages — Back, instance name, freshness pill with age, capability-gated Executor-chat button
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N3, DESIGN-E3, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T02, MP-N1-C3-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-E3, MP-N3]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T06 — Native WebView header

Not a Phase B candidate ticket; split out of N1-C4 because DESIGN-N1 D-N1-5 defines a native
header on every WebView page (surface-boundary row 4) and no other ticket owns it.

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4.
- **User value:** on any dashboard page the user sees which instance they are on, how fresh the
  data is, and can reach Executor chat as a secondary action (brief §3: dashboard first, chat
  second), and get back to the instance list.
- **Deliverable:** `src/shell/InstanceHeader.tsx` rendered above the WebView:
  - Back → previous screen (instance list).
  - Title: `owner/name` (+ root-basename disambiguator when two clones share a repo, contract §1).
  - Freshness pill: `live` / `stale <age>` / `unreachable <age>` from the capability store
    (age always shown when not live; AGENTS.md "if a surface computes an age, it renders the age").
  - Executor-chat button: shown when `executor.conversation` resolves `ready|degraded`; hidden when
    the client lacks support; shown **disabled with reason** when the server reports it
    `unavailable` (DESIGN-N1 surface 5 decides hidden vs disabled-with-reason; contract default is
    disabled with reason). Target route from the capability entry / MP-E3 route, never hard-coded.
  - No "ping Executor" or combined-inbox control (brief N3).
- **Non-goals:** the instance list (MP-N3-C4), Executor chat itself (MP-E3, WebView row 5).

## Dependencies and blockers

- DESIGN-N1 (D-N1-5 header contents; surface 2 pill wording), DESIGN-N3 (shared state terms),
  DESIGN-E3 (Executor chat entry). RQ-TRANSPORT / MP-N2-C10-T01 (RC-15; it sits on a WebView page).
- MP-N1-C4-T02 (screen), MP-N1-C3-T02 (store).
- MP-E3 for the Executor route; until it exists the capability is `unavailable`
  (`executor_not_managed`) and the button follows the unavailable rule.

## Verified starting point (base 45a290e3)

- No Executor route exists (MP-N3 plan G8; baseline E3); capability `executor.conversation`
  is registered by MP-E3 (`bucket-1-refactor/MP-R1/capability-matrix.md` §2 row
  `executor.conversation`).
- Page title already names the repo (`layouts.ex:312-317`), confirming `owner/name` as the
  identity users recognise.

## Chosen design

- Header reads only the capability store and the registry entry; no WebView scraping
  (surface-boundary §2 rule 5).
- Pill states map 1:1 from resolver states for affordance `instance_row`
  (`ready` → live, `stale`, `unreachable`, `unknown` → "unknown" text, never "live").
- Accessibility: the pill exposes its full text (e.g. "Stale, updated 3 minutes ago") as the
  accessibility label.

## Implementation steps

1. `InstanceHeader.tsx` + `freshnessLabel(state, ageMs)` pure helper.
2. Wire into `InstanceScreen` (MP-N1-C4-T02) via React Navigation `header` option.
3. Tests.

## Non-happy paths

- Capability store empty (first load) → pill "loading", button absent until resolved.
- Executor route missing in the capability entry while state is `ready` → button disabled with
  reason `unknown` (collapsed cause rule), plus a debug log.
- Revoked → screen leaves (MP-N1-C4-T02 handles navigation).

## Compatibility and rollout

- Client-only.

## Verification

- `npm --prefix packages/aiur-mobile test -- test/shell/InstanceHeader.test.tsx`:
  - `stale shows age text` and `unreachable shows age text`. Mutation: render "Live" for
    `stale` → fails.
  - `unknown never renders as live`. Mutation: map `unknown` to `live` → fails.
  - `executor chat hidden for unsupported client, disabled with reason for server unavailable,
    enabled for ready` (three fixtures). Mutation: hide on server `unavailable` when DESIGN-N1
    keeps "disabled with reason" → fails.
  - `no control labelled ping or inbox exists` (inventory of pressables).
- **Device:** part of DV-P6 (header does not cover dashboard controls at 320 px and 430 px) on
  iPhone A (iOS 17.x) and Android phone A (Android 13+); DV-P5 (pill shows unreachable/stale with
  age after turning the tailnet off).

## Completion and handoff

- [ ] DESIGN-N1 D-N1-5 implemented as approved; DV-P5/DV-P6 header checks recorded.
- **Docs:** `guide/mobile.md` screenshot/description of the header (after design approval).
- **Dependents:** MP-N3-C4-T04 (list-level Executor button uses the same gating helper).
