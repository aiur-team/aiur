# Voice package promotion record

MP-R5-C3-T01 (#3456), checked 2026-11-27 at
`2923466a76af031c18ad15279435617c2f47d892`.

**NO-GO for physical extraction.** MP-R5 remains complete at C1 + C2 + C4,
as the ticket's stop rule specifies. This record does not implement the
optional provider package or prove a core-only build.

## Prerequisites and decision

[MP-R1's promotion test](../MP-R1/migration-plan.md#5-promotion-test-when-a-logical-component-becomes-a-physical-package)
requires all five criteria before a logical component becomes a package.
The chosen form is an in-repo Mix path dependency under
`packages/elixir/<app>/`, included in the default release; `src/` stays a
single project. DESIGN-R5 approves default npm inclusion and unchanged UX,
but does not waive the promotion test.

The required first promotion did not happen: #3478 was re-scoped to in-tree
harness repairs. Its [scorecard](../MP-R7/plan.md#c4-t03-in-tree-recheck-2026-11-21)
still says no-go. #3480 records the separate-package release check as
[deferred](../MP-R7/chunks.md), because there is no `aiur_harness` application.
Its supplied commit `fe3fc522a63d7ff1fa8ac1dc05dd508d8794b02a` is an ancestor
of this checkout, so missing integration is not the cause.

| Promotion criterion | Current evidence | Result |
| --- | --- | --- |
| Zero allowlisted violations in/out for two consecutive releases | `scripts/components/allowlist/voice-stt.tsv` has six outgoing exemptions: two R-declared and four R-down. This is a file census, not a live violation count or a release census. | Not established; zero-debt evidence is missing |
| Component-declared children | `Aiur.ElevenLabs.child_specs/0` returns quota children through `Aiur.Voice.child_specs/0`; application assembly uses that facade. | Declaration present |
| Own state and tests independent of the host | Provider tests remain under `src/test/aiur/eleven_labs/`; quota and config still use Aiur. No independent provider no-start run was performed for this record. | Not established |
| Manifest config ownership | `components/voice-stt.json` owns `elevenlabs` and `ELEVENLABS_API_KEY`. The schema embed stays in core. | Present |
| Second consumer or stated independent-release need | The Scribe protocol has a pinnable package, but this is not evidence that another host consumes the entire Aiur provider, quota and init integration. | Not established for the proposed package |

## Existing extraction and overlap

PR #7523 extracted `VoiceTranscribe.Scribe` and its three transport modules
into `packages/elixir/voice_transcribe/`. Its standalone CI proves that
package's isolation. `Aiur.ElevenLabs.Realtime` now supplies Aiur credential
and language readers and delegates to it. Do not recreate the moved transports
when resuming this ticket.

The provider, quota, TTS, capability provider and init contribution remain
in core. `src/mix.exs` still includes `voice_transcribe` unconditionally;
standalone package CI does not prove core compiles or tests without voice.
The `Aiur.Voice` nil-provider seam is also not that proof.

The overlap suggestion naming #4084 is a title/path match, not equivalent
scope: #4084 is a paid conversational-provider spike with no production
extraction deliverable. Keep its spend and conversation work separate.

## Recheck and implementation handoff

Recheck when MP-R1 records a successful first promotion and release proof,
or explicitly revises that prerequisite. Score all five voice criteria with
release references, a boundary census in both directions, and independent
test evidence. Repairing today's exemptions alone does not establish two
consecutive releases. Do not mark physical extraction complete on the basis
of this record or the harness deferral.

Once promotion is permitted, move the remaining provider modules and tests,
including the newer capability provider. Remove core references to the
provider and relocate init contribution bodies behind the provider port.
Preserve the existing Scribe package and keep `Config.Schema.ElevenLabs` in
core. Add a clean core-only compile/test job with the dependency actually
excluded, exercise absent-provider rendering and leftover config parsing,
and verify the default release still includes voice. Update
`website/docs-app/apis/elevenlabs.md` with the installed/absent distinction
in the same implementation PR.
