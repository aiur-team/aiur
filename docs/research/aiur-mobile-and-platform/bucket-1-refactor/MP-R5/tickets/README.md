# MP-R5 tickets

- **U0 gate (X-58, RC-19).** Every MP-R5 ticket waits for U0 review of the prior plan
  (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps
  that gate for refactor work. U0 has no ticket ID, so the gate is stated here and not in
  `blocked_by`; the MP-R1-C11-T02 recheck does not replace it.

Base `45a290e3`, researched 2026-10-06. RC-13 and RC-14 are applied:

- speech-to-text keeps the `elevenlabs.*` keys;
- owner messages are `{:voice_transcript, kind, text}`, `{:voice_error, %{code, message}}`
  and `{:voice_closed}` (X-49);
- availability reasons are `:unconfigured` and `:not_installed`.

The plan's "voice-session contract must accept § 5 before C1" blocker is
therefore **resolved**. CR-R5-1 asks the coordinator to update the contract text.

| ID | Title | Status | Blocked by | Wave |
| --- | --- | --- | --- | --- |
| [MP-R5-C1-T01](MP-R5-C1-T01.md) | `Aiur.Voice` port: provider, transcriber and synthesizer behaviours; neutral message tags | blocked | DESIGN-R5 | 1 |
| [MP-R5-C1-T02](MP-R5-C1-T02.md) | Dashboard voice channel on `Aiur.Voice`; retire its two seams | blocked | DESIGN-R5, C1-T01 | 1 |
| [MP-R5-C1-T03](MP-R5-C1-T03.md) | Stream Deck voice and projection on `Aiur.Voice`; retire its two seams | blocked | DESIGN-R5, DESIGN-R6, C1-T01 | 1 |
| [MP-R5-C1-T04](MP-R5-C1-T04.md) | The "voice not installed" state: approved copy and absent-provider test | blocked | DESIGN-R5 (copy; "hidden" also needs MP-E5-C2), C1-T02, C1-T03 | 1 |
| [MP-R5-C2-T01](MP-R5-C2-T01.md) | Voice owns its quota meter and supervision | blocked | DESIGN-R5, C1-T01 | 1 |
| [MP-R5-C2-T02](MP-R5-C2-T02.md) | Voice owns its config section and contributes its `init` step | blocked | DESIGN-R5, C1-T01, MP-R1-C4-T01, MP-R1-C4-T05 | 1 (after R1-C4) |
| [MP-R5-C3-T01](MP-R5-C3-T01.md) | Optional physical package, and CI on core without it | blocked | DESIGN-R5, C1-T04, C2-T01, C2-T02, RQ-R5-PKG | deferred |
| [MP-R5-C4-T01](MP-R5-C4-T01.md) | Docs: voice responsibilities and cloud processing | blocked | DESIGN-R5 | 1 |
| [MP-R5-C4-T02](MP-R5-C4-T02.md) | Delete the unwired sidecar ElevenLabs TTS | blocked | DESIGN-R5 (§3.2) | 1 |

Every ticket is blocked on the DESIGN-R5 gate (MP-REQ2). Apart from that gate,
the following are ready once their predecessors merge:

- C1-T01 to T04;
- C2-T01;
- C4-T01 and C4-T02.

C2-T02 also waits on MP-R1-C4-T01 (registry pattern) and MP-R1-C4-T05 (manifest ownership; RQ4 keeps sections literal). C3-T01 waits on RQ-R5-PKG.

## Order

```
C1-T01 ─┬─► C1-T02 ─┐
        ├─► C1-T03 ─┴─► C1-T04 ─┐
        ├─► C2-T01 ─────────────┼─► C3-T01 (RQ-R5-PKG)
        └─► C2-T02 (R1-C4-T01/T05) ┘
C4-T01, C4-T02: independent
```

## Concurrency

- C1-T02 and C1-T03 run in parallel. Both edit
  `test/browser/fixture_server.exs` (T02 only), so a rebase is trivial.
- C2-T01 runs in parallel with T02 and T03.
- C4-T01 and C4-T02 can run at any time.

## Phase C changes to the plan

- **TTS behaviour name:** the plan's `Aiur.Voice.Speaker` became
  `Aiur.Voice.Synthesizer`, the contract §4 name.
- **TTS message tag:** `{:voice_audio, …}`, following the RC-14 pattern
  (CR-R5-1).
- **Ticket merges:** C1-T03 and C1-T04 (deck channel and projection) merged
  into C1-T03. C1-T05 (TTS) was folded into C1-T01 and C1-T02. The absent-state
  copy and test became C1-T04.
- **C2 is now two tickets:** C2-T01 (quota and supervision) needs no MP-R1
  mechanism. Config ownership and the `init` registry became C2-T02, blocked on R1-C4-T01/T05.
- **C3 is one ticket,** blocked on RQ-R5-PKG. MP-R1's promotion test
  (migration-plan § 5) does not pass for voice yet. MP-R5 is complete without
  C3; the in-process seam makes absence testable.

## Plan research answered

- **RQ1:** the adapter emits neutral tags directly. There is no extra hop, so
  latency is unchanged by construction.
- **RQ2:** `VoiceSessionLimiter` is supervised by
  `AiurWeb.FinancialData.Supervisor` (`financial_data/supervisor.ex:18`). It
  stays in `aiur_web`.
- **RQ3:** `elevenlabs-tts.ts` and `node-fetch.ts` import only each other and
  are unreachable from `main.ts`.
- **RQ4:** open as RQ-R5-PKG. MP-R1 chose a promotion test, not a mechanism.
