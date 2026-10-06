---
ticket_id: MP-N1-C7-T01
feature_id: MP-N1
chunk_id: MP-N1-C7
bucket: 3-mobile-watch
title: "Demo mode data layer: fixture-backed adapter behind the same typed client (conditional on a public listing)"
status: blocked
blocked_by: [DESIGN-N1, "OQ-N1-1 (= public listing)", "D-N1-7", MP-N1-C2-T05, MP-N1-C3-T02, MP-N3-C3-T02, MP-N3-C5-T01, MP-N6-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N3, MP-N6]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C7-T01 — Demo data adapter

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C7 "Demo mode".
- **User value:** an App Review or Play reviewer, who cannot reach a private aiur machine, can
  exercise every native surface (instance list, Command response, diagnostics, settings) with
  synthetic data. Required only for a public listing (App Review Guideline 2.1(a)).
- **Deliverable:** `src/api/demoAdapter.ts` (PROPOSED) implementing the same TS interface as the
  `AiurNative` facade (`listMachines`, `signedFetch`, `pushToken`, …) from bundled fixtures:
  two synthetic machines, the MP-N3-C3-T02 meta-row scenarios, two open Commands per the MP-N6
  device Command API shape, and one capability report per state. Answers mutate in-memory state
  only and return realistic outcomes (`delivered`, `conflict`).
- **Non-goals:** a fake WebView dashboard (WebView surfaces show a static "Demo — dashboard opens
  on a real machine" page, per DESIGN-N1 D-N1-7); entry UI and badge (T02).

## Dependencies and blockers

- **Conditional:** only if OQ-N1-1 = public listing and DESIGN-N1 D-N1-7 says yes. Otherwise closed.
- MP-N1-C2-T05 (facade interface), MP-N1-C3-T02 (cache), MP-N3-C3-T02 / MP-N3-C5-T01 (scenario
  fixtures), MP-N6-C1-T01 (Command view-model shape).

## Verified starting point (base `45a290e3`)

- App Review Guidelines 2.1(a) (accessed 2026-10-06, page undated,
  <https://developer.apple.com/app-store/review/guidelines/>): "…you may include a built-in demo
  mode in lieu of a demo account with prior approval by Apple. Ensure the demo mode exhibits your
  app's full features and functionality." (framework-evidence.md §3).
- Play internal testing avoids standard review for ≤ 100 testers (S28).

## Chosen design

- One switch: `ApiProvider` chooses `nativeAdapter` or `demoAdapter`; screens never check the mode.
- Demo state lives in memory and resets on app restart; nothing is written to the keychain or the
  meta cache (MP-N3-C4-T05), so demo data can never mix with a real machine.
- Demo machine ids use a reserved prefix `demo-` that the native adapter refuses (assert).

## Implementation steps

`src/api/demoAdapter.ts`, `src/api/ApiProvider.tsx`, fixture bundle `fixtures/demo/`. About 200 lines.

## Non-happy paths

Real and demo data mixing (prevented by the prefix and storage rule); fixtures out of date with the
contract (schema check from MP-N3-C3-T02 runs on `fixtures/demo/` too).

## Compatibility and rollout

Bundled always; reachable only through the T02 entry point.

## Verification

Jest `src/api/__tests__/demoAdapter.test.ts`: `demo_never_writes_native_storage` (mock module
asserts zero calls; mutation: call `cachePut` → fails), `native_adapter_rejects_demo_ids`,
`answer_returns_conflict_on_second_answer`. The full UI suite runs once with the demo provider
(`npm --prefix packages/aiur-mobile test -- --testPathPattern screens -- --demo`).

```bash
npm --prefix packages/aiur-mobile test -- src/api/__tests__/demoAdapter.test.ts
```

## Completion and handoff

- [ ] Tests pass. Docs: mobile guide "Demo mode" (what it shows, that it is synthetic).
- [ ] Dependents: MP-N1-C7-T02, MP-N1-C8-T02 (review notes describe demo mode).
