# MP-E6 contract requests (for the coordinator)

Raised during Phase C on 2026-10-06. MP-E6 owns `contracts/voice-session.md` and applied
draft-2 there itself.

| ID | To | Request | Why | Fallback if declined |
| --- | --- | --- | --- | --- |
| R-1 | MP-E7 (listener-mode §7 send API) | `send(conversation_ref, text, client_request_id, opts)` with `opts[:origin]` (`:operator` default, `:voice_assistant`) stored on the queue item and on the resulting conversation entry | DESIGN-E6 §2 requires a consult and a voice-originated instruction to look distinct in the agent's transcript; MP-E6-C5-T03/T04 send them | delivery still works; the entry is unlabelled, and DESIGN-E6 must accept that |
| R-2 | MP-E4 (conversations contract, entry rendering) | render entries with `origin: voice_assistant` with the DESIGN-E6-approved label | same | plain operator message rendering |
| R-3 | MP-E2 (command contract, actor) | optional `via: :voice_assistant` on the operator actor of an answer | audit trail of how a Command answer was produced (MP-E6-C5-T05) | omit `via` |
| R-4 | MP-R1 (capability matrix) | `voice.conversation` row: computed from `voice.stt` (dependency), `voice.conversation.agent_id`, last privacy preflight; `degraded` when `voice.tts` is unavailable | voice-session §7 defines it; MP-E6-C3-T03 implements it | none; documentation alignment only |
| R-5 | MP-R5 (plan §8 C2) | the voice package's child spec also starts `Aiur.VoiceConversation.SessionSupervisor`, `ProviderCleanup` and the preflight cache owner when the conversation component is present | MP-E6-C4-T01/C2-T04 need supervised children inside the optional package | start them from the application child list next to `Aiur.ElevenLabs.Quota` (`aiur.ex:355`) |
