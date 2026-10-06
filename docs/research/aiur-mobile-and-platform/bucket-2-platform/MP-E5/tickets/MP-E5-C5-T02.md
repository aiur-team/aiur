---
ticket_id: MP-E5-C5-T02
feature_id: MP-E5
chunk_id: MP-E5-C5
bucket: 2-platform
title: Voice input on the Executor composer, with Executor target validation
status: blocked
blocked_by: [DESIGN-E5, DESIGN-E3, MP-E3-C5-T01, MP-E3-C6-T01, MP-E5-C1-T03, MP-E5-C3-T01, MP-E5-C2-T01]
prior_units: []
prior_boundaries: [VOX, WEB, EXE]
prior_features: [ui-07]
prior_findings: []
size_owner: n/a (the Executor LiveView is new, MP-E3-C6)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C5-T02 — Executor composer voice

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C5.
- **User value:** the operator can speak to the Executor about the whole project the same way
  as to a worker — the key "talk to the Executor without Remote Control" outcome, by voice.
- **Deliverable:**
  1. `<.voice_input surface="executor_composer" target={%{kind: "executor", instance_id}}>`
     on the MP-E3-C6 Executor composer, inside a `phx-hook="VoiceInput"` form.
  2. `AiurWeb.VoiceTargets` gains the `executor` rule, replacing the `unsupported_target`
     refusal of MP-E5-C2-T01.
- **Non-goals:** the Executor composer itself and its send path (MP-E3-C5/C6); listener
  mode (MP-E7).

## Dependencies and blockers

- **Owner:** DESIGN-E5 and DESIGN-E3 (composer layout).
- **Predecessors:** MP-E3-C5-T01 (Executor send adapter over E7, "composer disabled with
  reason when `effective: null`"); MP-E3-C6-T01 (route/LiveView, proposed `/executor`);
  MP-E5-C1-T03, C2-T01, C3-T01.
- **Paths are PROPOSED** until MP-E3-C6 lands; plan refresh (`../plan.md` §10) rewrites them.

## Verified starting point (base `45a290e3`)

- No Executor composer exists at the base (baseline E3; `MP-E3/chunks.md` C5–C6).
- The Executor's existence today is surfaced by MP-E3's projection; the capability report
  carries `executor.conversation` with reasons `executor_absent` / `executor_not_managed`
  (`contracts/identity-and-capabilities.md` §2.2).

## Chosen design

- **Target rule:** `executor` is valid on surface `executor_composer` when the MP-R1 report
  has `executor.conversation` `available` (or `degraded`). Otherwise:
  - `executor_absent` → `target_not_found`;
  - `executor_not_managed` or the E3 composer's `effective: null` → `target_not_writable`;
  - any other / unknown → `unknown`.
- **Instance check:** `instance_id` must equal this instance's id (MP-R1-C2); mismatch →
  `target_not_found`.
- The component is rendered only where the composer itself is enabled; when E3 disables the
  composer with a reason, voice is not shown (one disabled control, not two).
- The hook, choice and dictation flow are exactly C3-T01's.

## Implementation steps

1. `VoiceTargets`: executor clause reading the capability registry (MP-R1-C2) through an
   injectable function for tests.
2. Executor LiveView/composer: add the component and hook attributes.
3. Docs: the MP-E3 Executor guide section gains one line: the composer supports Dictate and
   Converse like worker composers.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| No live Executor | composer disabled by E3; no voice controls |
| Executor goes away while dictating | Send fails with the E3/E7 receipt (`failed`), text kept (C6-T03) |
| Capability registry unavailable | `unknown` refusal; never `target_not_found` |

## Compatibility and rollout

Additive. Rollback: revert; the `executor` target falls back to `unsupported_target`.

## Verification

| Test | Expected |
| --- | --- |
| `voice_targets_test.exs` "executor target is valid when executor.conversation is available" | `:ok` |
| "executor_absent maps to target_not_found" | refusal code |
| "executor_not_managed maps to target_not_writable" | refusal code |
| "an unknown capability state is unknown, not a specific cause" | `unknown` |
| Executor LiveView test "composer renders the voice choice only when the composer is enabled" | present / absent |

```bash
env -C src mise exec -- mix test test/aiur_web/voice_targets_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Replace the fallback clause with `target_not_found`: the "unknown"
test fails (collapsed-cause rule).

## Completion and handoff

- [ ] Executor composer voice; `executor` targets validated; docs in PR.
- **Dependents:** MP-E6-C4-T06 (Executor converse target), MP-N6 Executor chat button voice.
