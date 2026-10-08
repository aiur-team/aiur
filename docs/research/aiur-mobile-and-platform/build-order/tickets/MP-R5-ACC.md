# MP-R5-ACC — MP-R5 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R5-C3-T01, MP-R5-C4-T01, MP-R5-C4-T02

## Outcome

The Executor proves MP-R5 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R5/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (9)

- MP-R5-C1-T01 — Aiur.Voice port — provider, transcriber and synthesizer behaviours; ElevenLabs emits neutral message tags
- MP-R5-C1-T02 — Dashboard voice channel on Aiur.Voice; retire the voice_stt_start_fun / voice_tts_start_fun seams
- MP-R5-C1-T03 — Stream Deck voice and voice projection on Aiur.Voice; retire streamdeck_voice_session / streamdeck_voice_available_fun
- MP-R5-C1-T04 — The "voice not installed" state — approved copy on the dashboard and the deck, plus the absent-provider acceptance test
- MP-R5-C2-T01 — Voice owns its quota meter and supervision — Aiur.Voice.quota_snapshot/0 and Aiur.Voice.child_specs/0
- MP-R5-C2-T02 — Voice owns its elevenlabs config section in the manifest and contributes its aiur init step through a registry
- MP-R5-C3-T01 — Move the ElevenLabs provider into an optional package, and run CI on core without it
- MP-R5-C4-T01 — Docs — voice responsibilities (capture, transport, transcription, delivery) and the cloud-processing statement
- MP-R5-C4-T02 — Delete the unwired Stream Deck sidecar ElevenLabs TTS (key-holding code that contradicts the daemon-only-credential rule)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
