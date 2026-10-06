# MP-R5 requests to the coordinator

## CR-R5-1 — `contracts/voice-session.md` §4: apply RC-14 in the text (owner: MP-E6/E5)

The contract's §4 table still names the transcriber messages
`{:transcript, …}`, `{:transcriber_error, code}` and `{:transcriber_closed}`.
RC-14 adopts R5's names. Please update §4 to the following:

- Streaming STT messages: `{:voice_transcript, :partial | :final, text}`,
  `{:voice_error, %{code, message}}` and `{:voice_closed}` (voice-session contract
  form, X-49): `message` is today's human string and `code` is a voice-session §8 code.
- TTS messages: `{:voice_audio, :chunk, binary}`, `{:voice_audio, :done}` and
  `{:voice_audio, :error, reason}`. These replace `{:audio, …}`, using the same
  `voice_` prefix so that a mailbox shared with other subsystems cannot
  collide on a bare `:audio` tag.
- Behaviour names stay as in the contract: `Aiur.Voice.Transcriber` and
  `Aiur.Voice.Synthesizer`. MP-R5 adopts `Synthesizer`, not the plan's
  `Speaker`.
- A provider-level behaviour, `Aiur.Voice.Provider`, exposes:
  - `transcriber/0`, `synthesizer/0` and `configured?/0` (C1-T01);
  - `child_specs/0` and `quota_snapshot/0` (C2-T01).
- The availability function is `Aiur.Voice.availability/0` →
  `%{available, reason: nil | :unconfigured | :not_installed}`. The `voice.stt`
  capability is derived from it (X-49; `voice.dictate.status` is retired).

## CR-R5-2 — DESIGN-R5 `blocks:` line

The DESIGN-R5 `blocks:` line says "MP-R5-C1..C4". The Phase C IDs are listed in
`tickets/README.md`. Please also add the "hidden versus disabled" consequence:
"hidden" makes MP-R5-C1-T04 wait for MP-E5-C2.

## CR-R5-3 — voice-session contract §4 note on the unwired sidecar TTS

MP-R5-C4-T02 deletes `packages/streamdeck/src/audio/elevenlabs-tts.ts` (if
DESIGN-R5 §3.2 = delete). After that merges, the contract's note can say
"removed".

## CR-R5-4 — MP-R1 input (no contract change)

MP-R1-C3-T02's `voice.stt` capability callback should read
`Aiur.Voice.availability/0`. MP-R1-C8's component child-spec assembly should
absorb `Aiur.Voice.child_specs/0`. RQ-R5-PKG (the physical package mechanism
and the promotion of voice-stt) is an MP-R1 question; MP-R5-C3-T01 waits on it.
