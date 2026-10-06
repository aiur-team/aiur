---
ticket_id: MP-E7-C1-T01
feature_id: MP-E7
chunk_id: MP-E7-C1
bucket: 2-platform
title: "Khala: extract the listener reference package (@khala/listener) without changing Khala behaviour"
status: blocked
repo: khala (cross-repo)
khala_ref: origin/main 99e72a43
wave: 3
blocked_by: [DESIGN-E7, E7-D1]
prior_units: [U3, U4]
prior_boundaries: [MSG (16), CA (20)]
prior_features: [integrations-43]
prior_findings: []
size_owner: n/a (Khala repository; Khala keeps its own file-size rules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C1-T01 — Extract the listener reference package in Khala

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C1 (shared listener specification).
- **Cross-repo:** this ticket changes the **Khala** repository
  (`aiur-team/khala`), not aiur. The Khala checkout is read-only for research;
  every Khala citation is at `origin/main` `99e72a43` (2026-10-06).
- **User value:** one home for the steer/sync/async vocabulary and the hook
  delivery decision, so aiur and Khala cannot drift (D13).
- **Deliverable:** a new pnpm workspace package `packages/listener`
  (workspace name `@khala/listener`, PROPOSED; the published npm name is chosen
  under E7-D1 and set in MP-E7-C1-T03). It holds only pure, I/O-free code:
  1. mode literals, default and decoder (today in
     `packages/contracts/src/delivery/listening-mode.ts:6,16,197-199` and
     `packages/contracts/src/m1/listening-mode.ts:8,18-22`);
  2. support statuses `MODE_SUPPORT_STATUSES` (`delivery/listening-mode.ts:7-9`);
  3. a pure delivery decision `decideDelivery(input) → { deliverModes, steerOnly, markIdleOnly }`
     extracted from `packages/agent/src/harness/deliver-core.ts:104-108`
     (async never; steer-only at tool boundary) and `:218-240`
     (prompt-boundary busy rule, `stop_hook_active` → idle only);
  4. the Claude/Codex hook codec (`packages/agent/src/harness/codecs/claude-style.ts:1-31`)
     and frame limits `MAX_FRAME_BYTES = 64 KiB`, 50 messages, UTF-8-safe
     truncation (`deliver-core.ts:18,57-80`), with the frame *copy* left as a
     parameter (contract §8: frame copy is per product).
- **Non-goals:** no behaviour change in Khala; no JSON artifacts (C1-T02); no
  publishing (C1-T03); no aiur change; Khala's channel inbox, cursor, wake
  ladder and Matrix code stay in `@khala/agent`.

## Dependencies and blockers

- **DESIGN-E7** (feature gate) and **E7-D1** (owner accepts "one package = spec +
  TS reference + goldens, homed and published from Khala"). Khala's owner must
  agree to publish a package it keeps private today
  (`packages/contracts/package.json:2-4`, `"private": true`).
- No aiur predecessor. Successors: MP-E7-C1-T02 → C1-T05 → C1-T03 → C1-T04.
- **May run concurrently with** MP-E7-C2-T01/T02 and MP-E7-C3-T01..T04 (aiur
  side does not import the package until C1-T04).

## Verified starting point (Khala `origin/main` 99e72a43)

- Contracts package is private, version `0.0.0`, exports raw TypeScript
  (`packages/contracts/package.json:1-12`).
- `m1/listening-mode.ts:1-22`: imports `LISTENING_MODES`/`decodeListeningMode`
  from `../delivery/listening-mode`; default `sync`; command type
  `com.khala.listening_mode.v1`; unknown member value decodes to `sync`.
- `delivery/listening-mode.ts`: modes (:6), statuses (:7-9), binding-scoped
  command/result/grant types (:20-145, Khala-specific, stay in Khala),
  `decodeListeningMode` (:197-199).
- `packages/agent/src/harness/deliver-core.ts` (268 lines) mixes the decision
  with Khala file state (`state`, `inbox`, `activity`, `wake/*` imports :1-16).
- `packages/agent/src/harness/codecs/claude-style.ts:6-31`: shared parse/render
  for Claude and Codex.
- Characterization goldens: 81 files (54 for Claude and Codex)
  `packages/agent/src/harness/__golden__/deliver-{claude,codex,cursor}-*-{steer,sync,async}-{0,1,51}.json`
  driven end to end through `runDeliver` by
  `packages/agent/src/harness/characterization.test.ts:24-80`
  ("U2 baselines must remain unchanged … Review any golden update as a
  behavior change", :24-25).
- ~20 import sites of `@khala/contracts/m1/listening-mode` across `apps/web`
  and `packages/agent` (`git grep -n "m1/listening-mode" origin/main`).
- Workspace: `pnpm-workspace.yaml` includes `packages/*`; root lint runs
  `scripts/check-boundaries.mjs` over `apps/` and `packages/` (root
  `package.json` `lint` script).

## Chosen design

- **Direction of dependency:** `@khala/listener` is the source;
  `@khala/contracts/delivery/listening-mode.ts` re-exports `LISTENING_MODES`,
  `MODE_SUPPORT_STATUSES`, `decodeListeningMode` from it, so the ~20 importers
  do not change. `deliver-core.ts` calls `decideDelivery` and the codec from
  the package and keeps all state I/O.
- **The existing 81 goldens stay where they are** and must pass byte-for-byte.
  They exercise Khala's file state and cannot move into an I/O-free package
  (this changes the chunk text "existing goldens move with it"). Package-level,
  language-neutral goldens are added in C1-T02.
- **Interface (TypeScript, PROPOSED):**

```ts
export type HookEvent = 'start' | 'prompt' | 'tool' | 'stop';
export type DecisionInput = Readonly<{ harness: string; event: HookEvent;
  continuation: boolean; busy: boolean; busyAgeMs: number | null;
  interruptedSinceBusy: boolean }>;
export type Decision = Readonly<{ deliverModes: readonly ListeningMode[];
  markIdleOnly: boolean }>;
export function decideDelivery(input: DecisionInput): Decision;
```

  `decideDelivery` reproduces `deliver-core.ts:218-249`: `tool` → `['steer']`;
  `prompt` → `['steer']` when `harness==='claude' && busy && busyAgeMs < 120000 && !interruptedSinceBusy`,
  else `['steer','sync']`; `stop` with `continuation` → `markIdleOnly`;
  `stop` → `['steer','sync']`; `start` → `[]`. `async` is never in the list.
- **Node floor (RQ-E7-5, resolved):** the package uses no `node:*` module;
  byte counting uses `TextEncoder` (available since Node 11) instead of
  `Buffer.byteLength`, so it can declare `engines.node: ">=18"` and be
  imported by `aiur-cli` (`packaging/npm/aiur-cli/package.json` `engines.node: ">=18"`
  at aiur `45a290e3`). Since MP-E7-C6 renders aiur's hook envelopes in Elixir
  and ships no Node hook, aiur does not import the package at all; the floor
  matters only for third-party consumers. Khala's own floor (`^22.18.0 || >=24.11.0`,
  `packages/agent/package.json:6-8`) is unaffected.

## Implementation steps

1. Add `packages/listener/{package.json,tsconfig.json,src/index.ts,src/modes.ts,src/decision.ts,src/codecs/claude-style.ts,src/frame.ts}` (PROPOSED). `package.json`: `"name": "@khala/listener"`, `"private": true` for now (C1-T03 flips it), `"type": "module"`, `engines.node ">=18"`, no runtime dependencies.
2. Move literals/statuses/decoder into `src/modes.ts`; make `packages/contracts/src/delivery/listening-mode.ts` re-export them. Keep `decode.ts` strictness unchanged.
3. Move `claudeStyleCodec` into the package; leave a re-export at `packages/agent/src/harness/codecs/claude-style.ts` so `adapter.ts` imports keep working.
4. Extract `decideDelivery` and the frame-limit helpers; refactor `deliver-core.ts` to call them. Frame copy (`INTRO`, `deliver-core.ts:20`) stays in `@khala/agent` and is passed in.
5. Add `@khala/listener: workspace:*` to `packages/contracts` and `packages/agent` dependencies; update `scripts/check-boundaries.mjs` only if it rejects the new edge (the script derives packages from `package.json` names, `check-boundaries.mjs:30-40`).

## Non-happy paths

- A refactor that changes decision order (for example evaluating `continuation`
  after the mode filter) changes hook output; the 81 goldens catch it.
- Truncation must stay code-point safe; a `TextEncoder` swap must give the same
  byte counts as `Buffer.byteLength` for every golden body (they include
  `café 👋`).
- Packaging: `khala-cli` is bundled by `packages/agent/scripts/build-package.mjs`,
  which externalizes only the `npm/package.json` dependencies (:27, :41) and
  bundles workspace packages, so `@khala/listener` is inlined; do **not** add it
  to `packages/agent/npm/package.json` dependencies (the pin check at :20-24
  would then require a published version).

## Compatibility and rollout

- No wire, file or CLI change. Rollback is a revert of one PR.
- Khala release `khala-cli` is unaffected until its next tag.

## Verification

Commands (Khala repo root, Node 22.23.2 per `.node-version`):

```sh
pnpm install --frozen-lockfile
pnpm --filter @khala/listener test
pnpm --filter @khala/contracts test
pnpm --filter @khala/agent test      # includes characterization.test.ts goldens
pnpm lint                            # eslint + check:boundaries + terminology
pnpm typecheck
pnpm --filter @khala/agent build && node packages/agent/dist/khala.mjs --help
```

New tests in `packages/listener/src/decision.test.ts`:

- `decideDelivery: tool boundary delivers steer only` → `['steer']`.
- `decideDelivery: busy claude prompt under 120 s is steer-only` → `['steer']`; at 120 000 ms → `['steer','sync']`.
- `decideDelivery: codex prompt while busy delivers steer and sync` → `['steer','sync']`.
- `decideDelivery: stop with stop_hook_active marks idle only` → `markIdleOnly: true`, `deliverModes: []`.
- `decideDelivery: async is never delivered` (property over all inputs).
- `frame: byte counting equals Buffer.byteLength on golden bodies`.

Mutation checks: making `tool` return `['steer','sync']` must fail the first
test **and** `deliver-claude-PostToolUse-sync-1.json`; removing the
`continuation` branch must fail the stop test and the `Stop` goldens.
The 81 existing goldens are guards (already pass on main) and are not counted
as new coverage.

## Completion and handoff

- [ ] `packages/listener` exists, I/O-free, `engines.node >=18`.
- [ ] All 81 `deliver-*` goldens unchanged and passing.
- [ ] `@khala/contracts` re-exports; no importer changed.
- [ ] Khala docs: `packages/agent/docs/` unchanged (no user-facing change).
- Dependents: MP-E7-C1-T02, MP-E7-C1-T05, MP-E7-C1-T03; indirectly MP-E7-C6-T04 (aiur's Elixir hook renderer is tested against the vendored goldens).
- aiur docs: none (no aiur change).
