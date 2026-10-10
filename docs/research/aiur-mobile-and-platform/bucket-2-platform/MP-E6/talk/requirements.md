---
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
feature_id: MP-E6
sub_feature: talk
date: 2026-10-10
parent: ../plan.md
---

# /talk — a voice conversation skill for any coding agent (requirements)

## Goal Capsule

- Objective: one skill, `/talk`, that any coding agent (Claude Code, Codex, Gemini CLI and others) can run. It sets up and starts the MP-E6 voice package on the user's machine, gives the user a local link, and lets the user talk with a fast voice assistant about the agent's work while the agent keeps working.
- Product authority: Kevin (operator). Sources: his /talk request and his provider change, both 2026-10-10, quoted below.
- Open blockers: the paid provider spike (E6-OQ9) for live-provider fixtures. Nothing else blocks the requirements.

## Product Contract

### Source statements (verbatim)

Kevin, 2026-10-10:

> earlier i asked about making convo mode usable by executors, i even want to usable by any agent via a skill separate from aiur:
> 1. i invoke /talk, tells agent how to set up and run locally.
> 2. if user needs further setup, like an eleven labs key, agent prompts them to set it in a .env. should also support if the user has api access to the model they're using, so they can just use the native end points and convo functionality of their agent if it exists without setting up new 3rd party deps. agent presents user options regardless
> 3. once chosen, agent runs small UI locally and sends link to user. user clicks and see UI similar to GPT convo mode, with voice to text dictation realtime, or the option of text only if they use their own language preferred vtt model. agent audio is played and shows real time text letter by letter.
> same forking functionality applies to let agent continue working during convo.

Kevin, 2026-10-10 (provider change, relayed by the Executor):

> just to flag, i originally said i only wanted air convo to support eleven, this means full support for native model convo wrappers to use model APIs in aiur too and .config settings to choose preferences

### Problem frame

MP-E6 (plan §1–§18) gives aiur a voice assistant, but only inside aiur and, until today, only with ElevenLabs. A user of a plain coding agent cannot use it. A user who already pays for a model provider that has its own realtime voice API must still buy a second vendor. The heavy coding agent is slow to answer by voice, so the assistant must answer from a briefing and from a read-only fork, and the real agent must not stop.

### Settled decisions carried forward

| ID | Decision | Provenance |
| --- | --- | --- |
| SD1 | MP-E6 is an independent package that works without aiur (plan §17). | (session-settled: user-directed — chosen over an aiur-internal module: Kevin 2026-10-09 "its own independent package") |
| SD2 | The fork wrapper is model-specific: native fork for Claude Code and Codex, others when they have it; a replay fallback otherwise (plan §17.7). | (session-settled: user-directed — chosen over one generic replay: Kevin 2026-10-09) |
| SD3 | The forked conversation is read-only and proposes; only the live agent applies (plan §17.11, §18.4). | (session-settled: user-approved — chosen over letting the voice assistant write: V5 confirm rule) |
| SD4 | Providers: ElevenLabs is the default third-party provider. Native model voice APIs (OpenAI, Gemini, others with a native conversation API) are full peers behind one provider interface, in aiur and in /talk, chosen by preference settings. | (session-settled: user-directed — chosen over ElevenLabs-only: Kevin 2026-10-10 "full support for native model convo wrappers … and .config settings to choose preferences") |
| SD5 | /talk is separate from aiur. It does not need an aiur install, an aiur daemon or GitHub. | (session-settled: user-directed — chosen over an aiur-only Executor feature: Kevin 2026-10-10 "usable by any agent via a skill separate from aiur") |
| SD6 | The agent always presents the options, even when only one works. | (session-settled: user-directed — Kevin 2026-10-10 "agent presents user options regardless") |

### Actors

- A1. User: the person at the keyboard. Talks or types in the browser page.
- A2. Live agent: the coding agent session that ran `/talk`. Keeps working. Applies confirmed drafts.
- A3. Voice assistant: the fast conversational model behind the page (a realtime model, ElevenLabs Agents, or a cascade).
- A4. Fork: a read-only copy of the live agent's session that answers one deep question and is discarded.
- A5. Talk host: the local process from the MP-E6 package that serves the page and holds the keys.

### Requirements

Setup and options

- R1. `/talk` is one skill directory in the open Agent Skills format, so one copy installs into Claude Code, Codex, Gemini CLI and other agents that read that format.
- R2. On first run the agent checks prerequisites and installs or fetches the talk host without the user needing Elixir, Erlang or a build toolchain.
- R3. The agent detects every conversation option the machine can use and shows them all, with a status for each (ready, needs key, unsupported) and one recommendation.
- R4. The options include, when present: the native realtime voice API of the user's own model provider (OpenAI, Gemini, others); ElevenLabs; a cascade that uses the user's own model API for the thinking and separate speech-to-text and text-to-speech; and text-only.
- R5. When an option needs a key, the agent tells the user the exact variable name and asks the user to put it in a `.env` file. The agent never asks the user to paste a key into the chat, and never prints a key.
- R6. Keys are read from the process environment or from `.env` files only (project `.env`, then a user-level file). A missing key turns that option to "needs key", never into a crash.
- R7. The user's choice is remembered as a preference order, and the next `/talk` starts with it without asking again unless it no longer works.

The page

- R8. After the choice, the agent starts the talk host and sends the user one link. The host binds to the loopback interface only, and the link carries a one-time secret.
- R9. The page looks and behaves like ChatGPT voice mode: one large state indicator (listening, thinking, speaking), the conversation as text, a mute and an end button.
- R10. In voice mode the user's speech appears as live text while the user speaks.
- R11. Assistant audio plays as it arrives, and its text appears letter by letter in step with the audio.
- R12. The user can interrupt the assistant by talking; playback stops at once.
- R13. Text-only mode needs no microphone and no speech vendor. It gives a text box that works with any dictation tool the user already has (OS dictation, Superwhisper, Wispr Flow). The assistant's reply streams as text; speech output is optional.
- R14. The page shows drafts (proposed instructions) as cards with Confirm, Edit and Discard.

Working while talking

- R15. The live agent keeps working during the conversation. `/talk` never pauses it.
- R16. The assistant answers from a briefing the live agent writes at start and refreshes at its checkpoints.
- R17. For a question the briefing cannot answer, the assistant asks a read-only native fork of the live agent's session (Claude Code, Codex), or a replay fork when the harness has no native fork, and says when an answer comes from a replay.
- R18. A confirmed draft reaches the live agent as an inbox message. The live agent applies it at its next checkpoint and replies applied or declined. Nothing types into the agent's terminal.
- R19. Unconfirmed text never reaches the live agent (V5).

Providers (aiur and standalone)

- R20. One provider interface in the package serves three families: native speech-to-speech (OpenAI Realtime / GPT-Live, Gemini Live), ElevenLabs Agents, and a cascade (speech-to-text + model + text-to-speech, each part chosen separately).
- R21. Settings choose a provider preference order, per-part choices for the cascade, voice or text mode, and the fallback when a key is missing. aiur exposes them in `.aiur/config`; the standalone host reads the same struct from its own settings file.
- R22. The privacy rules of plan §17.11 apply to every provider: no audio stored by the host, provider-side storage off where the provider allows it, provider conversation deleted where the provider supports deletion, full local text transcripts.

Safety and cost

- R23. The host shows the active provider and a running cost estimate, and enforces the session and daily caps of plan §17.6.
- R24. The fork has no write tools, no network beyond the model, no GitHub token, and does not change the parent session or worktree (plan §17.7 rules).

### Acceptance examples

- AE1. A Claude Code user with only an `ANTHROPIC_API_KEY` runs `/talk`. The agent lists: Cascade (Claude + browser speech) ready; ElevenLabs needs `ELEVENLABS_API_KEY`; OpenAI Live needs `OPENAI_API_KEY`; Gemini Live needs `GEMINI_API_KEY`; Text-only ready. The user picks Cascade and gets a link.
- AE2. A Codex user with `OPENAI_API_KEY` runs `/talk`; OpenAI Live is recommended. While Codex edits files, the user asks "why did you skip the migration?"; the assistant answers from a Codex `thread/fork` and says it asked a copy of the session.
- AE3. The user says "tell it to add a test for the empty case". A draft card appears. Nothing reaches the agent. The user presses Confirm. The agent's inbox gets one message; at its next checkpoint the agent applies it and the page shows "applied".
- AE4. The user picks Text-only and dictates with macOS dictation into the text box. No microphone permission is requested.
- AE5. In aiur, `.aiur/config` lists `[openai_live, elevenlabs_agents, cascade]`; `OPENAI_API_KEY` is missing; Converse starts with ElevenLabs and the panel says why.

### Scope boundaries

- In scope: the skill, the talk host CLI and its distribution, option detection, the page, text timing, standalone agent bridges (briefing file, inbox, native fork for Claude Code and Codex), the provider families above, aiur preference settings.
- Out of scope for v1: a native desktop or mobile app; remote access over the internet (the user may forward the port over SSH at their own choice); speaker identification; storing audio; local speech-to-text models bundled in the host (users who want one use text-only with their own dictation tool); Windows-native binaries if the bundled-runtime builder does not support them (planning decides).

### Key decisions (this brainstorm)

- KD1. The skill is a thin installer and launcher; all behaviour lives in the MP-E6 package and its talk host. A skill update never changes conversation logic.
- KD2. The talk host is the productized standalone host of plan §17.5 (former example host C11-T03), shipped as a self-contained binary.
- KD3. aiur and /talk share the provider interface, the settings struct, the wire protocol and the browser client. aiur adds its own ports and its dashboard panel.
- KD4. "Use the agent's native convo functionality" means, in order: the agent CLI's own realtime voice when it exists and is exposed (today only Codex `thread/realtime/*`, experimental, research §6; option `codex_realtime`); else the user's model provider's native realtime API when a key is present (OpenAI, Gemini); else a cascade that uses that provider's text model (Anthropic has no speech API, research §1.3). Claude Code's `/voice` is dictation only and is not reusable.

### Assumptions (recorded, not asked)

- AS1. Users run a Chromium, Firefox or Safari browser on the same machine as the agent, or forward the port themselves.
- AS2. Users accept a one-time binary download (about tens of MB) for the host.
- AS3. The cascade's default speech-to-text in the browser is the Web Speech API where the browser supports it; where it does not, the page offers text-only or a server speech-to-text vendor.
- AS4. The /talk skill source lives in the package (`packages/elixir/voice_converse/priv/skills/talk/`, so the release binary carries it; changed in the C13-T08 plan pass) and is copied to agent skill directories by an install command; a separate repository can follow later.

### Outstanding questions

- OQ-T1 (resolved in plan §19.6): per-platform `mix release` with ERTS through npm optional dependencies; Burrito is experimental and Bakeware archived (research §5).
- OQ-T2 (resolved in research §3.3): Claude Code delivery uses the documented messaging socket; Codex uses `codex queue --thread $CODEX_THREAD_ID`; others use the file inbox.
- OQ-T3 (Kevin, money): authorize the paid spike with three arms (E6-OQ9 amended). See plan §19.8.
