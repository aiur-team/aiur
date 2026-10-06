# MP-E5 contract requests (for the coordinator)

Raised during Phase C ticket research on 2026-10-06. MP-E5/E6 own
`contracts/voice-session.md` and applied their own changes there (draft-2). The items below
touch contracts or plans owned by other features.

| ID | To | Request | Why | Fallback if declined |
| --- | --- | --- | --- | --- |
| R-1 | MP-R5 (plan §2, `Aiur.Voice` owner messages) | `{:voice_error, reason}` carries `%{code: atom, message: binary}`, where `code` ∈ voice-session §8 provider codes | MP-E5-C2-T01 otherwise maps codes from the provider's human text (`realtime.ex:402-409`), which is brittle | text mapping table in `VoiceChannel.reason_code/1` with an unknown → `provider_error` default (already specified) |
| R-2 | MP-N2 (pairing contract §4.4; MP-N2-C6-T01) | `AiurWeb.DeviceAuth` sets `conn.assigns.aiur_device_id` on success | MP-E5-C8-T01 mints a voice ticket for the authenticated device | the controller re-verifies the bearer through `Machine.Store.verify_token/1` |
| R-3 | MP-N2 (store library, MP-N2-C1) | expose `Machine.Store.device_active?(device_id) :: boolean` with the same mtime cache as `verify_token/1`; fail closed on read errors | MP-E5-C8-T01/T02 check an open voice session's device every 15 s | `Enum.any?(Machine.Store.devices(), &(&1.device_id == id))` |
| R-4 | MP-N6 / MP-N7 plans | use the capability IDs `voice.stt` and `voice.conversation` (already in MP-N6 §5.3 and the client-capability model) and the device path in voice-session §3.5 (`POST /api/v1/device/voice-ticket`, socket `/voice/device`) | earlier voice-session drafts used `voice.dictate`/`voice.converse`; those IDs are retired | none needed; naming only |
| R-5 | DESIGN-E5 | add copy items: "field did not open" (C4-T01), "this device was unpaired" (C8-T02, native clients), "dictation is not active" (C2-T02 defensive path), "a dashboard script did not load" (C1-T02, optional) | new strings found during ticket research must be approved, not improvised | tickets reuse existing strings until approved (each ticket says which) |
| R-6 | voice-session §3.2 (own contract, recorded here for traceability) | add surface `command_revision` | revisions target answered Commands (`decision_revision_action.ex:43`) | — (applied by MP-E5-C4-T02) |
