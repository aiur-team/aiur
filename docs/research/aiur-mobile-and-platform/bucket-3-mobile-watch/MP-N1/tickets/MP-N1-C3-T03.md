---
ticket_id: MP-N1-C3-T03
feature_id: MP-N1
chunk_id: MP-N1-C3
bucket: 3-mobile-watch
title: Swift and Kotlin ports of the affordance resolver in the native cores, driven by the same fixture table
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C3-T01, MP-N1-C2-T04]
prior_units: []
prior_boundaries: []
prior_features: [MP-N7]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C3-T03 — Native affordance resolvers

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C3.
- **User value:** the watch shows the same truthful states as the phone even when the phone's
  JavaScript runtime is not loaded (the iOS app woken in the background by WatchConnectivity,
  MP-N7 plan §3; the Android `WearableListenerService`).
- **Deliverable:** `CapabilityResolver.swift` in `AiurClientKit` and `CapabilityResolver.kt`
  in `aiur-client-core`: line-for-line ports of `src/capability/resolve.ts` and
  `requirements.ts`, plus fixture-table tests over `fixtures/capability/cases.json`
  (MP-N1-C3-T01). Only the affordances the watch uses are required: `instance_row`,
  `commands_count`, `build_progress`, `answer_command`, `mic_dictate_server`,
  `mic_dictate_system`, `mic_converse`; the port includes the full table anyway, because a
  partial table would silently answer `hidden` for the rest.
- **Non-goals:** caching (the broker fetches on demand, MP-N7-C1), rendering.

## Dependencies and blockers

- DESIGN-N1; MP-N1-C3-T01 (source of truth and fixtures); MP-N1-C2-T04 (generated report
  models for the inputs).
- Concurrent with MP-N1-C3-T02.

## Verified starting point (base 45a290e3)

- Contract: `client-capability-model.md` §7 "The watch never resolves capabilities. The phone
  resolves them" — with the broker in native code, "the phone" includes the native layer, hence
  this port. §9 conformance: "Each client implementation (TS phone, Swift and Kotlin brokers)
  runs the same fixture table".
- No existing code (baseline N1/N7).

## Chosen design

- **Single source of truth = the fixture table**, not the TS code. A CI step fails if any of
  the three implementations disagrees on any case (all three run the same file).
- Requirements table generated, not hand-ported: `scripts/gen-requirements.mjs` (PROPOSED)
  emits `Requirements.generated.swift` and `Requirements.generated.kt` from `requirements.ts`
  (exported as JSON by a tiny TS entry point), so only the ~60-line precedence function is
  ported by hand.
- Same output type: `AffordanceState(state: String, reason: String?, reasons: [String],
  ageMs: Int64?)`; `state` values identical strings.

## Implementation steps

1. Export `REQUIREMENTS` as JSON from TS (`scripts/dump-requirements.ts`); generate the Swift
   and Kotlin tables; add `check:requirements` diff check to CI `js` job.
2. Port `resolve` to Swift and Kotlin.
3. Tests read `fixtures/capability/cases.json` (copied into test resources by the build).

## Non-happy paths

- Port drift: the shared fixture table and generated requirements catch it in CI.
- A fixture case the native port cannot express (e.g. TS-only affordance): the table marks
  `platforms: ["ts"]`; native tests skip only those, and the skip count is asserted to equal
  the number of so-marked cases (no silent skips).

## Compatibility and rollout

- Internal. Rollback n/a.

## Verification

- `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone
  16,OS=latest' -only-testing:AiurClientKitTests/CapabilityResolverTests`
- `./gradlew :aiur-client-core:testDebugUnitTest --tests '*CapabilityResolverTest*'`
- `npm --prefix packages/aiur-mobile run check:requirements`
- Mutations (each in Swift and in Kotlin, each must fail ≥1 case): `unknown → ready`;
  `unavailable → ready`; drop the `min_client_versions` step; treat unknown reason as
  `not_configured`. Record runs in the PR body.
- `skipped cases equal ts-only marked cases` — mutation: skip one more case → fails.

## Completion and handoff

- [ ] Three implementations agree on the full table in CI.
- **Docs:** none.
- **Dependents:** MP-N1-C3-T04, MP-N7-C1-T02, MP-N7-C1-T03.
