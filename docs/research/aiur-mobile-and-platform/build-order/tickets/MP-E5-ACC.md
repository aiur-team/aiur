# MP-E5-ACC — MP-E5 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-E5-C3-T02, MP-E5-C3-T03, MP-E5-C7-T01

## Outcome

The Executor proves MP-E5 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-E5/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (19)

- MP-E5-C1-T01 — Extract the drawer's voice markup into a reusable <.voice_input> function component
- MP-E5-C1-T02 — Split conversation-voice-controller.js into capture, transport and controller modules
- MP-E5-C1-T03 — Standalone VoiceInput LiveView hook so voice can live outside the conversation drawer
- MP-E5-C2-T01 — voice:dictate topic with a validated v1 join payload and stable reason_code on every error
- MP-E5-C2-T02 — Channel cancel event that discards the uncommitted utterance
- MP-E5-C2-T03 — Publish voice.stt and voice.tts capabilities and assign them at dashboard render time
- MP-E5-C3-T01 — Explicit Dictate / Converse choice in <.voice_input> (D16)
- MP-E5-C3-T02 — Converse hand-off from the mic choice to the MP-E6 conversation panel
- MP-E5-C3-T03 — Apply the owner's decision on the legacy auto-submit "interactive voice chat" (E5-OQ2)
- MP-E5-C4-T01 — Dictate a Command custom response on the answer form (card and detail)
- MP-E5-C4-T02 — Dictate a revised Command response on the revision form
- MP-E5-C5-T01 — Voice input on the agent log modal composer
- MP-E5-C5-T02 — Voice input on the Executor composer, with Executor target validation
- MP-E5-C6-T01 — Voice input state machine, approved status copy and the unavailable presentation
- MP-E5-C6-T02 — Cancel control and Escape key that restore the field's pre-recording text
- MP-E5-C6-T03 — Show the real delivery state after Send, taken from the send path, not invented by voice
- MP-E5-C7-T01 — Dashboard voice end-to-end verification and docs audit
- MP-E5-C8-T01 — Device voice ticket endpoint and /voice/device socket for paired phones and watches (RC-16)
- MP-E5-C8-T02 — End device voice sessions on revocation or unpair-all within 15 seconds

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
