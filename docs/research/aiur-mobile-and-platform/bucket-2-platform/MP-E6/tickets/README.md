# MP-E6 tickets — conversational voice assistant

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md). Chunks:
[../chunks.md](../chunks.md). Provider research: [../provider-research.md](../provider-research.md).
Contract: [voice-session](../../../contracts/voice-session.md) (draft-2, owned by MP-E6).
Design gate: [DESIGN-E6](../../../owner-design-tasks/DESIGN-E6.md).

**Status rule.** `blocked` = an owner decision, a non-waived design gate, an RQ or the paid
spike is open for that ticket. `ready` = fully specified; only predecessor implementation
tickets remain. DESIGN-E6 waives the backend chunks C2–C4 and C6.

**The paid spike (C1-T01) needs Kevin's explicit E6-OQ9 authorization** with the budget in
the ticket (≤ 60 agent-minutes, ≤ USD 15, hard stop at USD 12 / 50 min).

## Ticket table

| ID | Title | Status | Blocked by (owner / research / spike in bold) | Wave |
| --- | --- | --- | --- | --- |
| [MP-E6-C1-T01](MP-E6-C1-T01.md) | PAID provider validation spike | blocked | **E6-OQ9, DESIGN-E6** | 4 (first, owner-run) |
| [MP-E6-C2-T01](MP-E6-C2-T01.md) | Provider behaviour, events, fake | ready | C11-T01 (was MP-R5-C1-T01) | 4a |
| [MP-E6-C2-T02](MP-E6-C2-T02.md) | ElevenLabs Agents connection layer | ready | C2-T01, C11-T01 | 4b |
| [MP-E6-C2-T03](MP-E6-C2-T03.md) | Event mapping + tool round trip | blocked | **C1-T01 (spike)**, C2-T02 | 4c |
| [MP-E6-C2-T04](MP-E6-C2-T04.md) | Provider conversation deletion queue | ready | C2-T02, C6-T01 | 4b |
| [MP-E6-C3-T01](MP-E6-C3-T01.md) | `voice.conversation.*` config | blocked | **E6-OQ6, E6-OQ7**, MP-R5-C2-T01 | 4b |
| [MP-E6-C3-T02](MP-E6-C3-T02.md) | `aiur voice setup [--repair]` | blocked | **DESIGN-E6, E6-OQ7, C1-T01 (spike)**, C3-T01, C2-T02 | 4c |
| [MP-E6-C3-T03](MP-E6-C3-T03.md) | Privacy preflight + capability | blocked | **C1-T01 (spike, RQ-E6-3)**, C3-T01, C2-T02, MP-E5-C2-T03 | 4c |
| [MP-E6-C4-T01](MP-E6-C4-T01.md) | Session process and lifecycle | ready | C2-T01, C6-T01, C2-T04, C3-T01, C3-T03 | 4d |
| [MP-E6-C4-T02](MP-E6-C4-T02.md) | aiur BriefingSource/CommandSource (worker) | ready | C4-T01, C11-T01, MP-E4-C2 (optional) | 4d |
| [MP-E6-C4-T03](MP-E6-C4-T03.md) | ContextBuilder | ready | C4-T02, C6-T01 | 4d |
| [MP-E6-C4-T04](MP-E6-C4-T04.md) | Role registry | blocked | **DESIGN-E6, E6-OQ3**, C3-T01 | 4d |
| [MP-E6-C4-T05](MP-E6-C4-T05.md) | Live context updates from the bus | ready | C4-T01, C4-T03, MP-R2-C5 | 4e |
| [MP-E6-C4-T06](MP-E6-C4-T06.md) | Executor target | ready | C4-T02, C4-T03, MP-E3-C2, MP-E3-C4, MP-E5-C5-T02 | 4e |
| [MP-E6-C5-T01](MP-E6-C5-T01.md) | Read tools | ready | C4-T02, C2-T03 | 4e |
| [MP-E6-C5-T02](MP-E6-C5-T02.md) | Draft store, `propose_instruction` | ready | C5-T01, C6-T01 | 4e |
| [MP-E6-C5-T03](MP-E6-C5-T03.md) | Confirm/discard + delivery via E7 | blocked | **DESIGN-E6, E6-OQ1**, C5-T02, MP-E7-C3, E7 `origin` request | 4f |
| [MP-E6-C5-T04](MP-E6-C5-T04.md) | `consult_agent` | blocked | **DESIGN-E6, E6-OQ2, C1-T01 (spike)**, C5-T02/T03 | 4f |
| [MP-E6-C5-T05](MP-E6-C5-T05.md) | Command-answer drafts | ready | C5-T02, C4-T05, MP-E2 | 4f |
| [MP-E6-C6-T01](MP-E6-C6-T01.md) | Transcript writer | ready | C11-T01 | 4a |
| [MP-E6-C6-T02](MP-E6-C6-T02.md) | Index + read API | ready | C6-T01 | 4b |
| [MP-E6-C6-T03](MP-E6-C6-T03.md) | `aiur voice transcripts` | ready | C6-T02 | 4c |
| [MP-E6-C6-T04](MP-E6-C6-T04.md) | Transcript deletion | blocked | **DESIGN-E6, E6-OQ5**, C6-T02/T03 | 4f |
| [MP-E6-C7-T01](MP-E6-C7-T01.md) | `voice:converse` channel | blocked | **DESIGN-E6**, C4-T01, C2-T03, MP-E5-C2-T01 | 4f |
| [MP-E6-C7-T02](MP-E6-C7-T02.md) | Converse panel and states | blocked | **DESIGN-E6, E6-OQ4, E6-OQ8**, C7-T01, MP-E5-C1-T02, MP-E5-C3-T02 | 4g |
| [MP-E6-C7-T03](MP-E6-C7-T03.md) | Draft cards | blocked | **DESIGN-E6, E6-OQ1**, C7-T02, C5-T03, C5-T06, C5-T05 | 4g |
| [MP-E6-C7-T04](MP-E6-C7-T04.md) | Playback and barge-in | blocked | **DESIGN-E6, C1-T01 (spike, RQ-E6-5)**, C7-T02 | 4g |
| [MP-E6-C8-T01](MP-E6-C8-T01.md) | History views | blocked | **DESIGN-E6**, C6-T02, C7-T02 | 4h |
| [MP-E6-C8-T02](MP-E6-C8-T02.md) | Continue with carried drafts | blocked | **DESIGN-E6**, C8-T01, C4-T03, C5-T02 | 4h |
| [MP-E6-C8-T03](MP-E6-C8-T03.md) | Link delivered drafts to E4 anchors | blocked | **DESIGN-E6, DESIGN-E4**, C8-T01, MP-E4-C3, MP-E7-C3 | 4h |
| [MP-E6-C9-T01](MP-E6-C9-T01.md) | Docs + end-to-end verification | blocked | **DESIGN-E6, E6-OQ7**, user-visible E6 tickets | 4i |
| [MP-E6-C10-T01](MP-E6-C10-T01.md) | Agent status note | ready | MP-R2-C5-T01 | 4a |
| [MP-E6-C10-T02](MP-E6-C10-T02.md) | Status card + deltas | ready | C10-T01, C4-T03, C4-T05 | 4e |
| [MP-E6-C10-T03](MP-E6-C10-T03.md) | Side-query spike (fork) | ready | — | 4a |
| [MP-E6-C10-T04](MP-E6-C10-T04.md) | Briefing on demand (refresh / pause) | blocked | **DESIGN-E6, E6-OQ12**, C10-T01, C10-T02, C5-T03 | 4f |
| [MP-E6-C10-T05](MP-E6-C10-T05.md) | Side-query path for `ask_agent` | blocked | **C10-T03 (spike), E6-OQ15**, C5-T04, C11-T05 | 4g |
| [MP-E6-C11-T01](MP-E6-C11-T01.md) | `voice_converse` package skeleton, Config, ports, standalone CI | ready | — | 4a (first) |
| [MP-E6-C11-T02](MP-E6-C11-T02.md) | Session API, `Wire` codec, WebSock transport | ready | C11-T01, C4-T01 | 4e |
| [MP-E6-C11-T03](MP-E6-C11-T03.md) | Standalone example host (no aiur) | ready | C11-T02, C5-T03, C10-T02, C2-T03; E6-OQ17 (assumes yes) | 4g |
| [MP-E6-C11-T04](MP-E6-C11-T04.md) | aiur host adapter layer + manifest entries | ready | C11-T01, C3-T01, MP-R5-C1-T01, MP-R1-C1-T01 | 4c |
| [MP-E6-C11-T05](MP-E6-C11-T05.md) | Harness `fork_session` (native / history copy / replay) | blocked | **C10-T03 (spike), E6-OQ21**, MP-R7-C2-T02, MP-R7 request R-6 | 4f |
| [MP-E6-C11-T06](MP-E6-C11-T06.md) | ~~Second provider adapter~~ superseded by C14-T02/T03 (2026-10-10) | superseded | **C1-T01 (spike), E6-OQ20**, C2-T03 | 4h |
| [MP-E6-C11-T07](MP-E6-C11-T07.md) | Package docs + MP-R1 birth check | ready | C11-T03, C11-T04, C3-T03; E6-OQ16/OQ18 for publish only | 4i |
| [MP-E6-C12-T01](MP-E6-C12-T01.md) | Executor session registration + `aiur executor-session` | ready | — | 4a |
| [MP-E6-C12-T02](MP-E6-C12-T02.md) | Read-only native fork of the Executor session | blocked | **C10-T03 (spike)**, C12-T01, C11-T05 | 4g |
| [MP-E6-C12-T03](MP-E6-C12-T03.md) | Executor `AgentChannel` + voice wake records + reply verb | blocked | C12-T02, C4-T06, C5-T03, C5-T04, C10-T05 | 4h |
| [MP-E6-C12-T04](MP-E6-C12-T04.md) | Executor skill + docs for voice proposals | blocked | C12-T03, C7-T02 | 4i |

| [MP-E6-C13-T01](MP-E6-C13-T01.md) | talk host CLI (serve, status, stop) with a loopback-only, token-guarded local launch | blocked (predecessors only) | C11-T02, C11-T03 | 4 (/talk) |
| [MP-E6-C13-T02](MP-E6-C13-T02.md) | talk doctor - detect every conversation option, .env loading, saved preference | blocked (predecessors only) | C14-T01, C13-T01 | 4 (/talk) |
| [MP-E6-C13-T03](MP-E6-C13-T03.md) | Self-contained talk binaries (mix release with bundled runtime) shipped through npm per-platform packages | blocked (predecessors only) | C13-T01 | 4 (/talk) |
| [MP-E6-C13-T04](MP-E6-C13-T04.md) | Conversation page v1 (ChatGPT-voice-style) - live dictation, letter-by-letter assistant text, barge-in, text-only mode, draft cards | blocked (predecessors only) | C11-T02, C13-T05 | 4 (/talk) |
| [MP-E6-C13-T05](MP-E6-C13-T05.md) | Assistant text timing - one normalized event and wire frame for letter-by-letter reveal across providers | blocked (predecessors only) | C2-T01, C11-T02 | 4 (/talk) |
| [MP-E6-C13-T06](MP-E6-C13-T06.md) | Standalone agent bridge - briefing file, inbox and reply verbs for a live coding agent (talk brief, talk inbox wait/reply) | blocked (predecessors only) | C11-T03, C13-T01 | 4 (/talk) |
| [MP-E6-C13-T07](MP-E6-C13-T07.md) | Read-only native fork from a session handle (Claude Code, Codex) with replay fallback, in the voice_converse core | blocked (predecessors only) | C11-T01, C10-T03 | 4 (/talk) |
| [MP-E6-C13-T08](MP-E6-C13-T08.md) | The /talk skill (Agent Skills format) and talk install-skill for Claude Code, Codex, Gemini CLI and others | blocked (predecessors only) | C13-T01, C13-T02, C13-T03, C13-T06, C13-T07 | 4 (/talk) |
| [MP-E6-C13-T09](MP-E6-C13-T09.md) | /talk docs, quick start and end-to-end verification on Claude Code and Codex | blocked (predecessors only) | C13-T04, C13-T08, C14-T04, C14-T02 | 4 (/talk) |
| [MP-E6-C14-T01](MP-E6-C14-T01.md) | Provider registry, option descriptors and preference resolution in the voice_converse core | blocked (predecessors only) | C2-T01 | 4 (/talk) |
| [MP-E6-C14-T02](MP-E6-C14-T02.md) | OpenAI native voice adapter (GPT-Live 1, with the gpt-realtime path as fallback) | blocked (predecessors only) | C2-T01, C14-T01, C13-T05 | 4 (/talk) |
| [MP-E6-C14-T03](MP-E6-C14-T03.md) | Gemini Live native voice adapter | blocked (predecessors only) | C2-T01, C14-T01, C13-T05 | 4 (/talk) |
| [MP-E6-C14-T04](MP-E6-C14-T04.md) | Cascade adapter (speech-to-text + model + text-to-speech) with model backends and client-side speech and text modes | blocked (predecessors only) | C2-T01, C14-T01, C13-T05 | 4 (/talk) |
| [MP-E6-C14-T05](MP-E6-C14-T05.md) | Server speech parts for the cascade - ElevenLabs streaming TTS with alignment, ElevenLabs realtime STT, OpenAI TTS and transcription | blocked (predecessors only) | C14-T04 | 4 (/talk) |
| [MP-E6-C14-T06](MP-E6-C14-T06.md) | aiur .aiur/config voice provider preferences, mapping into the core Config, capability reasons and docs | blocked (predecessors only) | C3-T01, C14-T01, C11-T04 | 4 (/talk) |
| [MP-E6-C14-T07](MP-E6-C14-T07.md) | Experimental agent-native option - Codex thread realtime voice on a read-only fork (codex_realtime) | blocked (predecessors only) | C14-T01, C13-T07, C11-T02, C13-T05, C13-T02 | 4 (/talk) |
| [MP-E6-C11-T08](MP-E6-C11-T08.md) | Core Briefing render, diff and staleness (moved out of C10-T02 so the standalone path does not wait for aiur) | blocked (predecessors only) | C11-T01 | 4 (/talk) |
| [MP-E6-C5-T06](MP-E6-C5-T06.md) | aiur delivery of confirmed drafts and consults through MP-E7 listener mode (split from C5-T03) | blocked (predecessors only) | C5-T03, C11-T04, MP-E7-C3-T03, MP-E7-C3-T04, DESIGN-E6 | 4 (/talk) |

Totals (2026-10-10): 65 ticket files — 18 new (C13 ×9, C14 ×7, C11-T08, C5-T06), 1 superseded (C11-T06), 64 published to GitHub. Plan §19–§20; the dependency re-cut of §19.10 is applied in each ticket's frontmatter. Earlier totals: 43 tickets — 22 ready, 21 blocked (C11 added 2026-10-09, plan §17: independent package and read-only fork per harness). Before that: 36 tickets — 17 ready, 19 blocked (C10 added 2026-10-08 from
[../realtime-convo-research.md](../realtime-convo-research.md); several older tickets carry a
2026-10-08 amendment section).

## Dependency order

2026-10-10: see plan §19.10 for the /talk critical path and the re-cut core dependencies; chunks.md has the C13/C14 graphs.


```text
C6-T01 ─► C6-T02 ─► C6-T03 ; C6-T04 (E6-OQ5)
C11-T01 ─► C2-T01 ─► C2-T02 ─┬─► C2-T04 (+C6-T01)
                               └─► C2-T03 ◄── C1-T01 (PAID spike, E6-OQ9)
MP-R5-C2 ─► C3-T01 (E6-OQ6/7) ─► C3-T02 (spike) ; C3-T03 (spike)
C2-T01 + C6-T01 + C2-T04 + C3-T01 + C3-T03 ─► C4-T01 ─► C4-T02 ─► C4-T03 ─► C4-T05 ; C4-T06
                                                       C4-T04 (E6-OQ3)
C4-T02 + C2-T03 ─► C5-T01 ─► C5-T02 ─┬─► C5-T03 (E6-OQ1, MP-E7-C3) ─► C5-T04 (E6-OQ2)
                                      └─► C5-T05 (MP-E2)
C4-T01 + MP-E5-C2-T01 ─► C7-T01 ─► C7-T02 ─► C7-T03 ; C7-T04
C7-T02 + C6-T02 ─► C8-T01 ─► C8-T02 ; C8-T03
everything user-visible ─► C9-T01
```

## Concurrency

- **2026-10-09:** C11-T01 lands first. C2-T01 and C6-T01 now depend on it, not on MP-R5-C1. Core tickets write into `packages/elixir/voice_converse/`; plan §17.9 maps the modules.

- Can start first (after C11-T01): C6-T01, C2-T01; then C2-T02, C6-T02, C2-T04 in parallel.
- The spike (C1-T01) runs in parallel with all backend work; it only gates C2-T03, C3-T02,
  C3-T03, C5-T04 and C7-T04.
- C4-T05, C4-T06, C5-T01 can run in parallel after C4-T03.
- UI tickets (C7, C8) wait for DESIGN-E6 and run in the listed order.

## New research questions

None open beyond RQ-E6-1..6 (assigned to the spike). RQ-E6-7 (frame budget) is resolved in
voice-session §3.6; RQ-E6-8 (E4 tail/since read) is resolved by the conversations contract
§7 (`list_entries` with `tail` / `after` and the required `principal:` option; voice
context reads use `:internal`, device-rendered text uses `{:device, device_id}`).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).

## GitHub (published 2026-10-10)

Epic #4083 (container, label `feature:mp-e6`). 64 sub-issues with labels `feature:mp-e6`, `build-lane:voice`, `phase:5`, `priority:2`, `complexity:N`; `agent:todo` on C10-T03, C11-T01, C12-T01; `agent:parked` on the rest (reason in each body). 140 native `blocked_by` links (MP-E6 graph plus #3450, #3454, #3468). C11-T06 is superseded and not published.

| Ticket | Issue | Ticket | Issue | Ticket | Issue | Ticket | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1-T01 | #4084 | C2-T01 | #4117 | C2-T02 | #4118 | C2-T03 | #4119 |
| C2-T04 | #4120 | C3-T01 | #4121 | C3-T02 | #4122 | C3-T03 | #4123 |
| C4-T01 | #4124 | C4-T02 | #4125 | C4-T03 | #4126 | C4-T04 | #4128 |
| C4-T05 | #4130 | C4-T06 | #4131 | C5-T01 | #4132 | C5-T02 | #4133 |
| C5-T03 | #4134 | C5-T04 | #4135 | C5-T05 | #4136 | C5-T06 | #4137 |
| C6-T01 | #4138 | C6-T02 | #4139 | C6-T03 | #4140 | C6-T04 | #4141 |
| C7-T01 | #4142 | C7-T02 | #4143 | C7-T03 | #4144 | C7-T04 | #4145 |
| C8-T01 | #4146 | C8-T02 | #4147 | C8-T03 | #4148 | C9-T01 | #4149 |
| C10-T01 | #4085 | C10-T02 | #4086 | C10-T03 | #4087 | C10-T04 | #4088 |
| C10-T05 | #4089 | C11-T01 | #4090 | C11-T02 | #4091 | C11-T03 | #4092 |
| C11-T04 | #4093 | C11-T05 | #4094 | C11-T07 | #4095 | C11-T08 | #4096 |
| C12-T01 | #4097 | C12-T02 | #4098 | C12-T03 | #4099 | C12-T04 | #4100 |
| C13-T01 | #4101 | C13-T02 | #4102 | C13-T03 | #4103 | C13-T04 | #4104 |
| C13-T05 | #4105 | C13-T06 | #4106 | C13-T07 | #4107 | C13-T08 | #4108 |
| C13-T09 | #4109 | C14-T01 | #4110 | C14-T02 | #4111 | C14-T03 | #4112 |
| C14-T04 | #4113 | C14-T05 | #4114 | C14-T06 | #4115 | C14-T07 | #4116 |
