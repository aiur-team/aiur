---
ticket_id: MP-N6-C3-T01
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Phone Command screen — context, 2–3 suggested responses, custom response, Open conversation
status: blocked
blocked_by: [DESIGN-N6 (§3 phone Command screen), DESIGN-E2 (§4.1–4.2, D-4 multi-question), DESIGN-N1, MP-N6-C1-T01, MP-N6-C2-T02, MP-N1-C4-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-E2, MP-N1]
prior_findings: [decision.ex options/recommendation fields, DecisionAnswer @response_max 4_000]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C3-T01 — Phone Command screen

## Identity and outcome

Bucket 3, MP-N6, chunk C3. The native phone screen for one Command: DESIGN-E2 §4.1 anatomy
at phone width, 2–3 options (recommended first and marked), option details disclosure,
custom response field with a live character count against the **4,000**-character limit
(`Aiur.DecisionAnswer` `@response_max`, `decision_answer.ex:15`), sticky answer area, the
Mic button slot (C4-T01) and "Open conversation" (C2-T03). Submission calls C1-T03 with a
fresh `idempotency_key` per user action, stored with the draft.

## Dependencies and blockers

**Blocked** on DESIGN-N6 §3 layout, DESIGN-E2 §4.1–4.2 (normative anatomy and option
rules) and DESIGN-N6 D-4 / DESIGN-E2 §6.5 (multi-question native Commands); DESIGN-N1
(native screen); C1-T01; C2-T02; RQ-TRANSPORT.

## Verified starting point

C1-T01 view model; `Aiur.Decision` option fields (`id, label, description, benefits,
drawbacks, risk`) and `recommendation` (`decision.ex:18-42`).

## Chosen design (fixed parts)

- The idempotency key is generated once per answer attempt and reused for retries
  (AC-N6-5); a changed selection or text generates a new key.
- `expected_version` = the version in the loaded view.
- Wire keys are those of the code and C1-T03 (X-13): `option_id` **or**
  `custom_response`, never both (`{:response, :ambiguous}`), never `custom_text`.
- Options render in server order with the recommended one marked; more than 3 options show
  3 plus "More options" (DESIGN-E2 §4.2 decides the order rule; the marker is fixed).
- `summary.title` / short label is agent-authored: rendered in the "from agent" style
  (plan §5.6, security m3).
- Command text lives in the view model in memory only (plan §5.6, security M5). The draft
  `{option_id?, custom_response?, idempotency_key, expected_version}` is stored with
  `expo-secure-store` under `draft:<instance_id>:<decision_id>` and deleted on success,
  revoke and terminal status.
- Multi-question native Commands follow DESIGN-E2 §6.5 / DESIGN-N6 D-4 (design-pending):
  until approved, a Command with more than one question renders S17-like "Answer on the
  dashboard" with the reason `multi_question`.

## Implementation steps

1. `packages/aiur-mobile/src/commands/commandViewModel.ts`: map the C1-T01 JSON
   (`aiur-contracts` types) to view state; `selectOption`, `setCustom`, `submit`.
2. `packages/aiur-mobile/src/commands/draftStore.ts`: secure-store draft (above).
3. `packages/aiur-mobile/src/commands/api.ts`: `getCommand`, `answer` (C1-T01/T03).
4. `packages/aiur-mobile/src/commands/CommandScreen.tsx`: context, options, custom field
   with live count, sticky answer area, Mic slot (C4-T01), "Open conversation" (C2-T03).
5. Docs (same PR): `website/docs-app/guide/mobile.md` § "Answering a Command".

## Non-happy paths

Submission outcomes: C3-T02. Unreachable/offline: C3-T03. Live changes while open: C6-T01.
Multi-question: rendered as "answer on the dashboard" until D-4 is decided.

## Compatibility and rollout

Copy and layout are DESIGN-N6 §3 / DESIGN-E2 §4.1–4.2 (design-pending). Unknown extra
fields from a newer daemon are ignored.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/commands/commandViewModel.test.ts test/commands/draftStore.test.ts test/commands/CommandScreen.test.tsx
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `S02_recommendedOptionMarked` | recommended option carries the marker, server order kept | the marker |
| `S02_customOver4000DisablesSend` | 4,001 chars → Send disabled, count shown | the 4,000 limit (7,800 → fails) |
| `retryReusesKey` (AC-N6-5) | two submits of the same draft carry one key | key reuse (new key per call → fails) |
| `changedSelectionMintsNewKey` | new selection → new key | the regeneration |
| `bodyUsesOptionIdOrCustomResponse` (X-13) | request body has `option_id` xor `custom_response` | the wire mapping (`custom_text` → fails) |
| `titleRenderedFromAgentStyle` (m3) | title node has the from-agent style token | the style |
| `draftStoreHoldsNoCommandText` (M5) | secure-store writes contain no `question`/`context` text | the in-memory rule |
| `S03_submittingDisablesForm` | form disabled while the request is pending | the submitting state |
| `multiQuestionRoutesToDashboard` | >1 question → "answer on the dashboard" with reason | the guard |

## Completion and handoff

- [ ] DESIGN-E2/N6 approved layout applied; each test fails with its hunk reverted.
- [ ] Docs: `website/docs-app/guide/mobile.md` (same PR).
- Dependents: C3-T02, C3-T03, C4-T01.
