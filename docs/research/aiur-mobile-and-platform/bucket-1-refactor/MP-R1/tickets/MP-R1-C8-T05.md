---
ticket_id: MP-R1-C8-T05
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Move the display sanitizer out of build-orders into kernel so conversations stop depending on build-orders
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T01, MP-R1-C1-T03, MP-R1-C1-T05]
prior_units: [U4, U5]
prior_boundaries: [K #1, BO #30, PRJ #28]
prior_features: []
prior_findings: [agent-runtime-02]
size_owner: n/a (ticket_detail_sanitizer.ex is 298 lines; no touched file is in the U8 ledger at 465aca643 — re-check at ticket start per RC-23 / MP-R1-C11-T02)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T05 — Display sanitizer moves to kernel

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (prerequisite of the
  conversations component, C8-T06).
- **User value:** none visible. Live conversation rendering no longer needs the
  optional build-orders component, so a run without build orders keeps sanitized
  chat transcripts (R-optional rule: a required component never depends on an
  optional one).
- **Deliverable:** `Aiur.BuildOrder.TicketDetail.Sanitizer`
  (`src/lib/aiur/build_order/ticket_detail_sanitizer.ex`, 298 lines) is renamed to
  `Aiur.DisplaySanitizer` at PROPOSED `src/lib/aiur/display_sanitizer.ex`, owned by
  `kernel` beside `Aiur.SecretRedactor` (its only dependency). Callers renamed. A
  characterization test is added (none exists today).
- **Non-goals:** no change to any pattern, limit or option; no merge with
  `Aiur.Events.Sanitizer` or `Aiur.DecisionSanitizer` (different trust contracts —
  U5 KTD9 owns `Events.Sanitizer`, RC-21).

## Dependencies and blockers

- DESIGN-R1 §1; MP-R1-C1 manifest/rules/ratchet.
- Coordinates with MP-R1-C5-T02 (kernel primitives move: `Bounded`, `MapAccess`): both
  add files to the `kernel` manifest entry; whichever merges second rebases the
  manifest only. No code overlap.
- May run concurrently with every other C8 ticket; must merge before C8-T06.

## Verified starting point (45a290e3)

- Module: `src/lib/aiur/build_order/ticket_detail_sanitizer.ex:1`
  `defmodule Aiur.BuildOrder.TicketDetail.Sanitizer do` (`@moduledoc false`), only
  outgoing reference `Aiur.SecretRedactor`. Public functions `sanitize/2`
  (`:159-169`) and `sanitize_projection/3` (`:174-200`, options `:input_byte_limit`,
  `:redact_urls`, `:redact_environment`, `:trim`).
- Callers:
  - `src/lib/aiur/live_conversation/normalizer.ex:4,71,119,157` (required path: the
    live conversation projection).
  - `src/lib/aiur/build_order/ticket_detail_normalizer.ex:5,116,129`.
  - `src/lib/aiur_web/build_order/ticket_context_presenter.ex:104,748`.
  - `src/lib/aiur_web/markdown.ex:6` (moduledoc text only).
- No test references the module (`git grep -l 'sanitize_projection\|TicketDetail.Sanitizer' 45a290e3 -- src/test` is empty); it is covered indirectly by
  `src/test/aiur/live_conversation_test.exs` and the build-order ticket-detail tests.

## Chosen design

- Rename + move (no shim). The name `DisplaySanitizer` states the contract: it bounds
  and redacts text for display; it is not a trust decision.
- Manifest: `kernel.paths += src/lib/aiur/display_sanitizer.ex`,
  `kernel.facades += Aiur.DisplaySanitizer`. The `live_conversation → build_order`
  allowlist entry is removed.

## Implementation steps

1. `python3 scripts/rename_preflight.py` for `Aiur.BuildOrder.TicketDetail.Sanitizer`
   and `TicketDetail.Sanitizer` (catches multi-alias forms such as
   `alias Aiur.BuildOrder.TicketDetail.{DestinationNormalizer, Failure, Sanitizer, Snapshot}`
   at `ticket_detail_normalizer.ex:5`).
2. `git mv` to `src/lib/aiur/display_sanitizer.ex`; rename module.
3. Update the three code callers and the `markdown.ex` doc sentence (≈8 lines).
4. Add the characterization test; update the manifest.

## Non-happy paths

- Invalid UTF-8, over-limit input and non-binary input keep returning `:error` exactly
  as today; the new test pins those branches so a later refactor cannot replace them
  with a default (AGENTS.md "unknown or unavailable rendering branch").
- Secrets: unchanged redaction; the test uses a synthetic token string, never a real one.

## Compatibility and rollout

Internal rename; no config or data change. Revert is a plain revert.

## Verification

New `src/test/aiur/display_sanitizer_test.exs` (future-regression guards; they pass on
main against the old name and are **not** counted as covering a behaviour change):

1. `test "sanitize/2 rejects input longer than the byte limit"` →
   `Aiur.DisplaySanitizer.sanitize(String.duplicate("a", 11), 10) == :error`.
2. `test "sanitize/2 rejects invalid UTF-8"` → `sanitize(<<0xFF>>, 10) == :error`.
3. `test "sanitize_projection/3 reports truncation"` →
   `{:ok, "abc", true} = sanitize_projection("abcdef", 3)`.
4. `test "sanitize_projection/3 redacts an environment assignment when asked"` →
   result for `"FOO_TOKEN=abc123"` with `redact_environment: true` does not contain `"abc123"`.
5. `test "sanitize_projection/3 refuses input over :input_byte_limit"` → `:error`.

Mutation check for the boundary itself: the checker fixture (C1-T06) for
"required → optional". With `normalizer.ex` re-pointed at a module under
`build_order/` in a scratch branch, `check-components.py` must fail.

Commands:
`env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/display_sanitizer_test.exs test/aiur/live_conversation_test.exs test/aiur/live_conversation_restart_test.exs test/aiur/build_order test/aiur_web/build_order`;
`make -C src fmt-check lint`; `python3 scripts/check-components.py`.

Manual: foreground `scripts/aiurdev --test`; open a chat pane and the dashboard ticket
context dialog; text renders as before (capture before/after).

## Completion and handoff

- [ ] No reference to `Aiur.BuildOrder.TicketDetail.Sanitizer` remains.
- [ ] Five characterization tests pass.
- [ ] `live_conversation → build_order` allowlist entry removed; count ≤ baseline.
- **Docs:** none.
- **Dependents:** MP-R1-C8-T06 (conversations), MP-R1-C8-T08 (build-orders facade).
