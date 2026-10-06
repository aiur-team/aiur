---
ticket_id: MP-N1-C3-T01
feature_id: MP-N1
chunk_id: MP-N1-C3
bucket: 3-mobile-watch
title: TypeScript affordance resolver — precedence table, version handling and the shared fixture table of the client capability model
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T01, MP-R1-C3-T6]
prior_units: []
prior_boundaries: []
prior_features: [MP-R1]
prior_findings: [baseline R1 (clients infer availability from missing fields)]
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C3-T01 — Affordance resolver (TS)

Candidate tickets merged: N1-C3-T2 (precedence) and N1-C3-T3 (version handling); version
handling is step 4 of the same precedence function.

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C3 (client capability model).
- **User value:** every phone screen shows "unavailable", "stale", "unreachable", "needs
  update" and "needs permission" truthfully and identically; nothing renders a missing
  capability as `0` or as a working button (brief §6 N3; AC4, AC5).
- **Deliverable:** `packages/aiur-mobile/src/capability/resolve.ts` (PROPOSED), a pure
  function, plus the **shared fixture table** `fixtures/capability/cases.json` that the Swift
  and Kotlin ports (MP-N1-C3-T03) also run.

```ts
type AffordanceId = "instance_row" | "commands_count" | "build_progress" | "open_dashboard"
  | "executor_chat" | "answer_command" | "send_message" | "mic_dictate_server"
  | "mic_dictate_system" | "mic_converse" | "push_receive" | "pref_build_progress" | "pref_pr_merge";
type AffordanceState = { state: "ready"|"degraded"|"stale"|"unreachable"|"unavailable"
  |"needs_permission"|"needs_update"|"revoked"|"unknown"|"hidden"; reason?: string;
  reasons?: string[]; ageMs?: number };
function resolve(id: AffordanceId, inputs: ResolverInputs, now: number): AffordanceState;
```

  `ResolverInputs` = I1 report (or `null` + fetch outcome), I2 reachability and transport
  mode, I3 authorization, I4 local permissions, I5 client support, exactly as
  `contracts/client-capability-model.md` §2.
- **Non-goals:** caching and refresh (MP-N1-C3-T02), native ports (MP-N1-C3-T03), any
  rendering (screens own presentation; DESIGN-N1 surface 5 owns the shared pattern).

## Dependencies and blockers

- DESIGN-N1 (surface 5 wording does not change the function, but the gate applies).
- MP-R1-C3-T6 (capability report TS types). Capability IDs are those of
  `bucket-1-refactor/MP-R1/capability-matrix.md` §2 (e.g. `instance.status`, `commands.read`,
  `commands.answer`, `agents.message`, `build_orders.progress`, `executor.conversation`,
  `voice.stt`, `voice.tts`, `voice.conversation`, `push`, `listener_modes`).
- RC-04: `boot_id`, `min_client_version` and the typed `capability_unavailable` error are in the
  MP-R1 report; this ticket consumes `min_client_version` (step 4).
- Concurrent with MP-N1-C2-*.

## Verified starting point (base 45a290e3)

- No capability endpoint exists; clients infer (baseline R1). The single explicit projection
  today is `AiurWeb.StreamdeckProjection.voice/0` returning `%{available, reason}`
  (`src/lib/aiur_web/streamdeck_projection.ex:33-40`), which the contract generalises.
- Dashboard precedents for distinct states: "Command counts unavailable." and "Partial Command
  counts" (`src/lib/aiur_web/components/operator_control_center/overview.ex:79-89`).
- Contract text this ticket implements: `client-capability-model.md` §3 (states), §4
  (precedence 1–11), §5 (requirements table), §8 (404 → `needs_update`; ID missing on a
  new-enough server → `unavailable/unknown`). Reconciled 2026-10-06 (RC-04, RC-15 transport kinds).

## Chosen design

- A data table `REQUIREMENTS: Record<AffordanceId, {required: CapId[]; optional: CapId[];
  local: LocalReq[]; introducedIn: Record<CapId, number>}>` transcribed from contract §5;
  the function walks contract §4 in order. No per-affordance special code except:
  - `mic` button aggregate (`micButton(inputs)`): `ready` if Dictate (server or system) or
    Converse is `ready|degraded`; the sheet shows each option's own state (D16).
  - `open_dashboard` under transport mode `http_degraded` → `degraded` (reason
    `http_degraded`), `mic_dictate_server` on WebView surfaces → `unavailable`
    (reason `insecure_context`) — RQ-TRANSPORT, contract §5 as reconciled.
- Multiple unavailable causes: `reasons` lists all, `reason` = first in requirement order
  (AGENTS.md "collapsed cause … `reasons` list").
- Unknown server reason string → `unknown` (never mapped to a specific cause).
- `hidden` only for I5 (client does not implement the affordance), never for server absence.

## Implementation steps

1. `src/capability/types.ts`, `requirements.ts` (table), `resolve.ts`.
2. `fixtures/capability/cases.json`: array of `{name, affordance, inputs, now, expect}`;
   at least one case per state per affordance where reachable (~60 cases), including:
   old server (`contract_version` below `introducedIn`) → `needs_update`; report 404 →
   `needs_update`; `min_client_version` above build → `needs_update`; revoked beats
   unreachable; unreachable beats unavailable; unavailable `build_orders.progress` →
   `unavailable` (not `0`); `degraded` voice.tts optional → converse `degraded`;
   permission denied mic → `needs_permission`; stale (age 61 s foreground) → `stale`.
3. `test/capability/resolve.test.ts` iterates the fixture file.

## Non-happy paths

- Every non-happy input **is** the subject of this ticket; the precedence order is the
  conflict rule (e.g. revoked + unreachable → `revoked`).
- Clock: ages use the server `age_ms` plus the client's own fetch age (contract §6); a
  negative computed age (clock moved back) is clamped to the fetch age only.
- Privacy: inputs contain no secrets; the function logs nothing.

## Compatibility and rollout

- Pure code. Contract version handling is the compatibility mechanism (step 4 rules).
- Rollback: n/a.

## Verification

- Command: `npm --prefix packages/aiur-mobile test -- test/capability/resolve.test.ts`.
- `fixture table: <name>` (one generated test per case) — all pass.
- Unknown-path mutations (AGENTS.md last test rule), each must turn at least one case red:
  1. Replace the `unknown` branch with `ready`.
  2. Make `unavailable` return `{state: "ready"}` with value-free reason (the "plausible
     default").
  3. Swap precedence steps 3 and 5 (unreachable vs unavailable).
  4. Map an unknown reason string to `not_configured`.
  5. Return `hidden` for server-unavailable capabilities.
  Record the five mutation runs (command + failing case names) in the PR body.
- `no state renders zero` is not testable here (no rendering); the screen tickets
  (MP-N3-C4, MP-N6) assert it with these fixtures.

## Completion and handoff

- [ ] Fixture table covers every state × affordance cell that the precedence can reach.
- [ ] Five mutations recorded as failing.
- **Docs:** none user-facing. If DESIGN-N1 changes a state name, the contract changes first.
- **Dependents:** MP-N1-C3-T02, MP-N1-C3-T03 (same fixtures), MP-N1-C4-T06 (header pill),
  MP-N3-C4, MP-N5 preference screens, MP-N6.
