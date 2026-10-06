---
ticket_id: MP-E7-C6-T04
feature_id: MP-E7
chunk_id: MP-E7-C6
bucket: 2-platform
title: "Elixir hook envelope renderer, conformance-tested against the shared hook goldens"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C1-T02, MP-E7-C1-T04]
repo: aiur-team/aiur
wave: 4
prior_units: [U3]
prior_boundaries: [MSG (16)]
prior_features: []
prior_findings: [MP-E7 plan E7-F3, E7-F4]
size_owner: n/a (new module under Aiur.Listener)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C6-T04 — Hook envelope renderer and golden conformance

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C6.
- **User value:** Executor messages arrive in the exact envelope Claude Code
  and Codex accept, the same shape Khala proves, with aiur's own wording.
- **Deliverable:** `Aiur.Listener.HookEnvelope.render(harness, event,
  entries, opts) :: {:ok, binary, consumed_count} | :none` (PROPOSED) and an
  ExUnit conformance suite that runs every vendored hook golden.
- **Non-goals:** frame copy (DESIGN-E7), transport (C6-T01/T02).

## Dependencies and blockers

- **DESIGN-E7** (aiur frame intro text; contract §8 "frame copy is per
  product": aiur operator messages *are* instructions).
- **MP-E7-C1-T02** (goldens published with the spec) and **MP-E7-C1-T04**
  (vendored to `src/priv/listener_spec/v1/` with a sha256 manifest).
- **Contract request to C1:** goldens must let a product substitute its frame
  copy — either the goldens carry `{intro}` placeholders or the envelope
  (`hookSpecificOutput.additionalContext` / `{"decision":"block","reason"}`)
  is asserted separately from the frame text. Khala's current goldens embed
  Khala's `INTRO` (`packages/agent/src/harness/deliver-core.ts:20` at
  `99e72a43`).
- **May run concurrently with** C6-T02, C6-T03.

## Verified starting point

- Khala `origin/main` `99e72a43`: `deliver-core.ts` limits
  `MAX_FRAME_BYTES = 64 * 1024` (`:18`), at most 50 entries per frame
  (`:57`), line rendering with control-character scrubbing and tag escaping
  (`:31-39`), frame wrapper (`:44-49`), UTF-8-safe truncation marker
  `' …[truncated]'` (`:21`). Goldens:
  `packages/agent/src/harness/__golden__/deliver-{claude,codex}-{PostToolUse,Stop,UserPromptSubmit}-{steer,sync,async}-{0,1,51}.json`
  (MP-E7 plan E7-F3). Envelopes per contract §8: `PostToolUse` /
  `UserPromptSubmit` → `hookSpecificOutput.additionalContext`; `Stop` →
  `{"decision":"block","reason": <frame>}`.
- aiur has no renderer today; `src/priv/listener_spec/` does not exist at
  `45a290e3` (created by C1-T04).

## Chosen design

- Pure module; input entries `[%{ts, sender_label, sender_kind, body}]`.
- Port the rendering rules exactly (scrub `\p{Cc}\p{Zl}\p{Zp}` in labels,
  indent continuation lines, escape the frame tag, 50-entry and 64 KiB caps,
  byte-safe truncation of a single oversized entry).
- aiur wrapper tag `<aiur-operator-messages count="N">` and intro text from
  DESIGN-E7 (placeholder `{intro}` until then; the ticket cannot merge
  without the approved text).
- `consumed_count` tells C6-T01 how many claimed items fit; the rest stay
  pending.

## Implementation steps

1. `src/lib/aiur/listener/hook_envelope.ex`.
2. `src/test/aiur/listener/hook_envelope_conformance_test.exs`: load every
   `priv/listener_spec/v1/goldens/deliver-*.json`, render with the golden's input,
   compare envelope structure and limits (and full text where the golden is
   copy-neutral).
3. Unit tests for truncation and escaping.

## Non-happy paths

- **Zero entries:** `:none` (endpoint returns `204`).
- **Async rows in goldens:** expect `:none` for every async golden (hooks
  never deliver async).
- **Spec version bump:** the manifest check (C1-T04) fails first; this suite
  pins `v1`.

## Compatibility and rollout

Pure code; used only by C6-T01.

## Verification

- Conformance test: every vendored golden passes. **Mutation:** change the
  entry cap from 50 to 51 → the `-51` goldens fail.
- `"a 70 KiB message is truncated on a UTF-8 boundary with the marker"`;
  `"frame tag in a body is escaped"`; `"Stop envelope is decision block"`.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur/listener/hook_envelope_conformance_test.exs`.

## Completion and handoff

- [ ] All goldens green; approved intro text cited.
- [ ] aiur frames end each message with `[aiur:delivery <delivery_id>]`
      (listener-mode §8 "aiur specifics", Phase D CR-E4-2); a golden covers it.
      This is aiur-only frame copy, not part of the shared Khala envelope.
- Dependents: C6-T01.
