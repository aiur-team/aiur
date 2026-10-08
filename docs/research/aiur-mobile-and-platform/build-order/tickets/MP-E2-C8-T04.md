---
ticket_id: MP-E2-C8-T04
feature_id: MP-E2
chunk_id: MP-E2-C8
bucket: 2-platform
title: Enable native capture by default per harness after owner approval
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T05, MP-E2-C5-T03, MP-E2-C7-T03]
prior_units: [U6, U4]
prior_boundaries: [DEC #27, CDX #21, CLD #22]
prior_features: []
prior_findings: [owner item "enable the Codex default_mode_request_user_input flag in production" (reconciliation owner items; DESIGN-E2)]
size_owner: "DECISIONS (config defaults) + DOCS"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C8-T04 — Enable native capture by default per harness after owner approval

## Identity and outcome

- Bucket 2, MP-E2, chunk C8.
- **User value:** native questions reach you without each operator opting in.
- **Deliverable:** default of `decisions.native_capture.codex` and/or `.claude` set to
  `true` **per harness**, each only with Kevin's explicit approval; the repo's own
  `.aiur/config` (dogfood) enabled first for one week; release note.
- **Non-goals:** any new behaviour.

## Dependencies and blockers

- **Owner decision (DESIGN-E2):** using an `UnderDevelopment` Codex feature in production
  (stage verified with `codex features list`, codex-cli 0.160.0, 2026-10-06). Claude needs
  no upstream flag but needs the `aiur-claude` release from C5-T01.
- C4-T05, C5-T03 merged (all release paths); C7-T03 (the operator can see a held unit).

## Verified starting point

- Keys added by C4-T02 / C5-T02 in `Aiur.Config.Schema.Decisions` (PROPOSED at base).
- Dogfood config `.aiur/config` (AGENTS.md "Layout": operational config, not portable
  defaults).

## Chosen design

1. Dogfood: set both keys `true` in this repo's `.aiur/config` (operator change, not a
   code default) for ≥ 7 days. Census from the event log: number of native Commands
   created, number released (`native_released` facts), number answered in-band — paste
   the counts (AGENTS.md "count the population").
2. Flip code defaults only for harnesses where in-band answers ≥ releases and no stall /
   max-duration incidents with `native_hold` set were seen.

## Implementation steps

1. Census command (read-only on a copy, as in C8-T03) counting `request_attributed` with
   `origin == native_question`, `native_released`, and delivered in-band facts.
2. Default literal change(s) + `configuration.md` defaults + release note.

## Non-happy paths

- Codex removes or renames the feature: C4-T05's startup-failure path; revert the
  default.
- High release rate: keep default off; open a follow-up with the counts.

## Compatibility and rollout

- Operators can still set `false`. Rollback = default revert.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur/config/decisions_native_capture_test.exs
python3 scripts/check-config-docs.py
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "native capture defaults" | values equal the approved defaults | default literals |

Manual: wrapper-tmux `aiurdev --test` with **no** native-capture keys in config; a
Codex worker's native question appears in `/commands`.

## Completion and handoff

- [ ] Owner approval recorded per harness; dogfood census in the PR body.
- Docs: `reference/configuration.md` defaults; `concepts/commands.md` (no longer "opt-in").
