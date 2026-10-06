---
ticket_id: MP-N6-C3-T01
feature_id: MP-N6
chunk_id: MP-N6-C3
bucket: 3-mobile-watch
title: Phone Command screen — context, 2–3 suggested responses, custom response, Open conversation
status: blocked
blocked_by: [DESIGN-N6 (§3 phone Command screen), DESIGN-E2 (§4.1–4.2, D-4 multi-question), DESIGN-N1, MP-N6-C1-T01, MP-N6-C2-T02, N1-C4-T1, RQ-TRANSPORT (RC-15)]
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

## Implementation steps

After approval: screen, view model, API client (`aiur-contracts` types).

## Non-happy paths

States in C3-T02 / C3-T03.

## Compatibility and rollout

n/a.

## Verification

Component tests: recommended option first; 4,001-char custom text disables Send with the
count (must fail if the limit is 7,800); retry reuses key (must fail if a new key is minted).

## Completion and handoff

- [ ] DESIGN-E2/N6 approved layout. Dependents: C3-T02, C3-T03, C4-T01.
