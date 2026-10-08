---
ticket_id: MP-N1-C2-T05
feature_id: MP-N1
chunk_id: MP-N1-C2
bucket: 3-mobile-watch
title: AiurNative Expo module — the only JS-visible API over the native cores, with no secret-returning method and host-restricted signedFetch (AC6)
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C2-T03, MP-N1-C2-T04]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C2-T05 — `AiurNative` Expo module

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C2.
- **User value:** the React Native UI can pair, list machines and call daemons, while keys and
  tokens stay in native code (R-secret).
- **Deliverable:** a local Expo module `packages/aiur-mobile/modules/aiur-native/` (PROPOSED)
  with Swift and Kotlin implementations backed by MP-N1-C2-T01..T03, and a TS facade
  `src/api/native.ts`:

```ts
type MachineSummary = { machineId: string; label: string; endpoints: string[];
                        state: "paired" | "unreachable" | "revoked"; pairedAt: string };
pair(qrUri: string): Promise<{ machineId: string; label: string; keyFingerprint: string; relinked: boolean }>;
listMachines(): Promise<MachineSummary[]>;
forgetMachine(machineId: string): Promise<void>;         // local wipe; server revoke is MP-N2-C7 via signedFetch
signedFetch(target: { machineId: string } | { instanceId: string },
            req: { method: "GET" | "POST" | "PUT" | "DELETE"; path: string; body?: unknown;
                   idempotencyKey?: string }): Promise<{ status: number; json: unknown }>;
onMachineEvent(cb: (e: { machineId: string; kind: "revoked" | "endpoints_changed" }) => void): Subscription;
```

  `bootstrapWebSession` is added by MP-N1-C4-T02; `pushToken`/registration by MP-N4-C4-T05 /
  MP-N4-C5; `watchLink.*` by MP-N7-C1.
- **Non-goals:** any screen.

## Dependencies and blockers

- DESIGN-N1; MP-N1-C2-T03 (protocol), MP-N1-C2-T04 (models for typed returns).
- Concurrent: MP-N1-C3-T01 (TS resolver can be built against fixtures without this module).

## Verified starting point (base 45a290e3)

- Nothing exists (baseline N1). Plan §3.2 lists the intended API; this ticket narrows it:
  the plan's `bootstrapWebSession(instanceId) → cookie` returned a cookie to JS, which
  contradicts AC6; here the cookie never reaches JS (MP-N1-C4-T02).
- External (accessed 2026-10-06): Expo Modules API — local modules created with
  `npx create-expo-module@latest --local`, Swift `Module` definition DSL and Kotlin `Module`
  class, `AsyncFunction`, `Events`
  (<https://docs.expo.dev/modules/overview/>; SDK 57 docs set).

## Chosen design

- **Host restriction (security invariant):** `signedFetch` resolves the base URL itself:
  `{machineId}` → the machine's current gateway endpoint (MP-N1-C2-T03 `EndpointSelector`);
  `{instanceId}` → the `dashboard.url` from the last signed `GET /v1/instances` for that
  machine. JS supplies only a **path** (must start with `/`, no `//`, no scheme, no `..`
  segments). JS can therefore never send the bearer to an arbitrary host.
- The native side adds `Authorization: Bearer <token>`, `Content-Type`, and for instance
  writes the headers MP-N2-C6-T03 requires (the device path bypasses `:api_write`'s browser
  Origin rule by the device-auth plug design; this module sends nothing browser-specific).
- **Errors** are typed (`code` strings from MP-N1-C2-T03 plus `path_rejected`,
  `instance_unknown`), never raw native exceptions.
- **Idempotency:** `idempotencyKey` is passed as the MP-E2 answer field / header MP-E2
  defines; the module does not generate one (the caller owns the "submit intent", MP-N6).
- Responses larger than 1 MiB are rejected (`response_too_large`) to bound memory.

## Implementation steps

1. `npx create-expo-module@<pinned> --local aiur-native`.
2. iOS `AiurNativeModule.swift`: `AsyncFunction("pair")` … delegating to `AiurClientKit`.
3. Android `AiurNativeModule.kt`: same over `aiur-client-core`; register the core as a Gradle
   dependency of the module so prebuild includes it.
4. `src/api/native.ts`: typed facade + path validation duplicated in TS (fail fast) — native
   validation remains authoritative.
5. `src/api/native.test.ts` and native unit tests (below).

## Non-happy paths

- **Machine revoked during a call:** native wipes, rejects with `device_revoked`, emits
  `onMachineEvent(revoked)`; the UI removes the machine after one notice (capability `revoked`).
- **Instance URL unknown** (registry not fetched yet): `instance_unknown`; callers fetch
  `GET /v1/instances` first.
- **Locked before first unlock:** `locked`, no network.
- **Path injection:** `"//evil.example/x"`, `"https://…"`, `"/../x"` → `path_rejected`.

## Compatibility and rollout

- Internal API. Versioned by the app build. Rollback: n/a.

## Verification

- Jest `src/api/native.test.ts` (native module mocked through `jest-expo`'s module registry):
  - `exported API has exactly the documented functions` — snapshot of `Object.keys` of the
    module facade. Mutation: add `getToken` → fails.
  - `no return type mentions token, secret or key material` — a type-level test with
    `tsd`-style assertions (`expectTypeOf<ReturnType<…>>`) that `MachineSummary` and the
    `signedFetch` result have no `token|secret|privateKey` keys. Mutation: add `token` to
    `MachineSummary` → fails.
  - `rejects absolute and protocol-relative paths`.
- Swift `AiurNativeModuleTests` / Kotlin `AiurNativeModuleTest`:
  - `signedFetch_never_uses_caller_host`: mock transport records the URL; a path of
    `//evil.example/a` is rejected and no request is made. Mutation: remove native path
    validation → request recorded → fails.
  - `bearer_added_only_for_known_endpoints`.
- Commands: `npm --prefix packages/aiur-mobile test -- src/api`, the two native commands from
  MP-N1-C2-T01/T02.
- **Static check (AC6):** `npm --prefix packages/aiur-mobile run check:no-secrets-in-js`
  (PROPOSED script) greps `src/**` for `SecItem`, `KeyStore`, `access_token`, `Authorization`
  and fails on a match outside `src/api/native.ts` comments.

## Completion and handoff

- [ ] AC6 tests green; mutations fail.
- **Docs:** none user-facing.
- **Dependents:** MP-N1-C3-T02 (fetch layer), MP-N1-C4-T02, MP-N2 app screens, MP-N3-C4,
  MP-N6 native Command screen.
