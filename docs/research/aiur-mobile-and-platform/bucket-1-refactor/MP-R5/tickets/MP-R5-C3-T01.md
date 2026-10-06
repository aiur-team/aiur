---
ticket_id: MP-R5-C3-T01
feature_id: MP-R5
chunk_id: MP-R5-C3
bucket: 1-refactor
title: Move the ElevenLabs provider into an optional package, and run CI on core without it
status: blocked
blocked_by: [DESIGN-R5, MP-R5-C1-T04, MP-R5-C2-T01, MP-R5-C2-T02, RQ-R5-PKG]
prior_units: [U8]
prior_boundaries: ["VOX #36", "CFG #2"]
prior_features: [integrations-51, ui-16]
prior_findings: []
size_owner: n/a (moves files under 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C3-T01 — Move the ElevenLabs provider into an optional package

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C3.
- **User value:** a build without voice is possible and proven, so "voice
  module absent" (brief R5) is real, not simulated.
- **Deliverable:**
  - Move `Aiur.ElevenLabs` (provider), `Realtime` (+ 3 transport modules),
    `TTS`, `Quota`, `Config.Schema.ElevenLabs` and `Init.ElevenLabs` into a
    physical package.
  - Add a CI job that compiles and tests core with the package excluded.
  - Release packaging includes the package by default, unless DESIGN-R5 §3.1
    says otherwise.
- **Non-goals:**
  - a separate repository (prior decision `ui-16`, KTD11);
  - new behaviour. C1-T04 already ships the absent-state copy.

## Dependencies and blockers

- **RQ-R5-PKG (open; it gates this ticket).** MP-R1's
  [promotion test](../../MP-R1/migration-plan.md) (§ 5) allows a component to
  become a physical package only when all five criteria hold:
  - zero allowlisted dependency violations for 2 consecutive releases;
  - component-declared child specs;
  - its own state and tests;
  - a registered config section;
  - a second consumer or a stated independent-release need.

  At base, voice meets none of them. C1 and C2 satisfy criteria 2–4. Criterion
  1 needs the MP-R1-C1 checker plus two releases. Criterion 5 needs an owner
  statement.
- **The package mechanism** (an in-repo path dependency with
  `optional: true`, or an umbrella app) is not chosen by MP-R1 either. R1 plan
  § 3 rejects an umbrella app now, and leaves physical packaging to the
  promotion test. The mechanism is chosen when the first component is
  promoted; that is part of RQ-R5-PKG.
- **Unblock condition:**
  - MP-R1 records the mechanism with its first promotion (candidates listed
    first: `aiur-contracts`, the Stream Deck sidecar);
  - the voice-stt component passes the promotion test;
  - the owner answers DESIGN-R5 §3.1 (default npm `aiur` includes voice:
    recommended yes).

  Until then this ticket stays blocked, and **MP-R5 is complete at C1 + C2 +
  C4**. The in-process seam already makes absence testable.
- **Predecessors:** C1-T04, C2-T01, C2-T02.

## Verified starting point (base `45a290e3`)

The files to move (line counts at base):

| File | Lines |
| --- | --- |
| `src/lib/aiur/eleven_labs/realtime.ex` | 421 |
| `realtime/mint_socket.ex` | 192 |
| `realtime/mint_transport.ex` | 31 |
| `realtime/transport.ex` | 25 |
| `tts.ex` | 135 |
| `quota.ex` | 296 |
| `src/lib/aiur/config/schema/eleven_labs.ex` | 26 |
| `src/lib/aiur/init/eleven_labs.ex` | 73 |

The tests move with them:

| Test file | Lines |
| --- | --- |
| `src/test/aiur/eleven_labs/realtime_test.exs` | 418 |
| `realtime/mint_socket_test.exs` | 215 |
| `tts_test.exs` | 103 |
| `quota_test.exs` | 251 |

There is no physical Elixir package in the repo today. `src/` is one Mix
project.

## Chosen design

Deferred to the RQ-R5-PKG answer. These are fixed regardless of mechanism:

1. **Core never references the package.** An ExUnit source-scan test (added in
   this ticket, `test/aiur/voice_boundary_test.exs`, PROPOSED) reads every
   `src/lib/**/*.ex` outside the package path and fails on `Aiur.ElevenLabs`.
   This is plan acceptance § 7.1, written as a test rather than a lint script,
   in the RC-11 pattern. It is retired when the MP-R1-C1 checker carries the
   rule.
2. **The default provider resolves to `nil`** when `Aiur.ElevenLabs` is not
   loaded. `Aiur.Voice.provider/0` already checks `Code.ensure_loaded?/1`
   (C1-T01).
3. **The CI job** compiles and runs `mix test` for core with the package
   excluded, using the mechanism's exclusion switch. It also runs
   `test/aiur_web/voice_absent_test.exs` in that build, which proves the
   absent path for real.
4. **Packaging:** the npm `aiur` release includes the package when DESIGN-R5
   §3.1 = include. Check with `packaging/scripts/check-platform-drift.mjs`
   and the release build.

## Implementation steps

1. Confirm that RQ-R5-PKG is answered, and record the mechanism and path.
2. Move the files and tests. Update the remaining aliases, which should be none
   outside the package after C1 and C2.
3. Add the boundary test and the CI job.
4. Update the release assembly to include the package.

## Non-happy paths

- **Package excluded but an `elevenlabs:` config section present:** it loads
  (C2-T02 constraint 4).
- **Package excluded:** the dashboard and the deck show the C1-T04 copy, and
  typed chat works.

## Compatibility and rollout

- Default releases include voice, so operators see no change.
- Rollback means reverting the move PR. No state migration is needed; the quota
  has no durable store.

## Verification

- The boundary test is green. Mutation: add `Aiur.ElevenLabs.TTS` to a core
  module. It fails.
- The CI job is green on core without the package.
- In the default release, the dashboard dictation and deck hold-to-dictate
  manual check from C1-T03 still works.
- Commands depend on the mechanism and are written into this ticket when
  RQ-R5-PKG is answered.

## Completion and handoff

- [ ] RQ-R5-PKG is answered and cited.
- [ ] Core compiles and tests without the package in CI.
- [ ] Docs:
  - `website/docs-app/apis/elevenlabs.md` gains one line: "Voice is an
    optional component; a build without it shows 'Voice input isn't
    installed…' and typed messages work".
  - If the install changes (DESIGN-R5 §3.1 = separate install), add an
    install note to the install/quick-start page.
- **Dependents:** the MP-R1 component directory (C10) lists voice-stt as a
  package.
