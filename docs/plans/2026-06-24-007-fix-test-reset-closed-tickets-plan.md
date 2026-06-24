---
title: "fix: Keep test reset labels off closed sandbox tickets"
type: fix
date: 2026-06-24
---

# fix: Keep test reset labels off closed sandbox tickets

## Summary

Prevent `mix aiur.test.reset` and `scripts/aiurdev --test` from preparing closed sandbox tickets for dispatch. Closed pinned tickets should have stale automation labels removed and should cause the reset to fail with an operator-facing setup instruction.

---

## Problem Frame

The reset currently strips and re-adds `agent:todo` without first confirming the pinned sandbox issue is open. When a pinned issue is closed, the reset leaves misleading automation labels behind and the launcher output implies the issue is dispatch-ready.

---

## Requirements

- R1. Reset must not leave `agent:*` or `model:*` labels on closed pinned sandbox issues.
- R2. Reset must not label a closed ticket as `agent:todo`.
- R3. Reset output must clearly distinguish labels prepared on an open ticket from a closed ticket that was skipped and needs operator setup.
- R4. A closed pinned ticket must prevent a real smoke run from launching unless a future change intentionally reopens tickets.
- R5. Regression coverage must lock the closed-ticket path so stale automation labels cannot be reintroduced.

---

## Key Technical Decisions

- **Fail closed before destructive reset work:** Query ticket state before per-ticket cleanup. If any pinned ticket is closed or cannot be verified open, skip normal reset work and return an error so `scripts/aiurdev` refuses to launch.
- **Clean closed-ticket automation labels from observed labels:** Use the issue's current label list to remove any `agent:*` or `model:*` labels. This avoids maintaining a second hardcoded model-label list.
- **Keep open-ticket behavior compatible:** Open tickets continue through the existing two-call remove-then-add label reset and retry path, with clearer success wording.

---

## Implementation Units

### U1. Add ticket-state preflight

- **Goal:** Verify pinned issues are open before normal reset work proceeds.
- **Requirements:** R2, R3, R4.
- **Files:** `src/lib/aiur/test_reset.ex`, `src/test/aiur/test_reset_test.exs`.
- **Approach:** Add injectable helpers around `gh issue view --json state,labels`. Closed or unverifiable tickets return reset errors before workspace, branch, PR, or baseline actions run.
- **Test scenarios:** A closed metadata response returns a closed-ticket error; an open metadata response allows reset preparation to continue.
- **Verification:** Targeted `test_reset_test.exs` coverage exercises the preflight without real GitHub calls.

### U2. Strip automation labels from closed tickets

- **Goal:** Remove stale `agent:*` and `model:*` labels from closed pinned issues while avoiding normal dispatch labeling.
- **Requirements:** R1, R2, R3.
- **Files:** `src/lib/aiur/test_reset.ex`, `src/test/aiur/test_reset_test.exs`.
- **Approach:** Derive the closed-ticket removal set from fetched label names, call `gh issue edit --remove-label <csv>` only when there is something to remove, and log a closed-ticket skip message.
- **Test scenarios:** Closed issue metadata containing `agent:todo`, `model:codex`, and unrelated labels removes only the automation labels and never emits an add-label command.
- **Verification:** Tests assert command arguments and return values.

### U3. Preserve existing open-ticket label reset contract

- **Goal:** Keep the two-call open-ticket label reset and retry behavior intact.
- **Requirements:** R2, R3, R5.
- **Files:** `src/lib/aiur/test_reset.ex`, `src/test/aiur/test_reset_test.exs`.
- **Approach:** Leave `reset_labels_command_args/1` and `apply_label_reset/5` as the open-ticket path, changing only the success message to say labels were prepared on an open ticket.
- **Test scenarios:** Existing reset label command tests still pass; a new open-ticket test confirms the open path uses remove then add.
- **Verification:** Targeted reset tests plus compile/spec checks.

---

## Scope Boundaries

- Do not reopen closed sandbox issues in this change.
- Do not broaden the sandbox smoke flow from issue #527.
- Do not change orchestrator issue polling or dispatch labels outside the test-reset task.
