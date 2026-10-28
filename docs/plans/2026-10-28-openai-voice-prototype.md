---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---
# OpenAI voice prototype

## Goal Capsule
Implement #6905 on the existing provider port. Keep the browser mic, read-only
tools, transcript storage and Executor summary handoff shared. Spend nothing in tests.

## Product Contract
R1: select OpenAI Realtime through config; retain the ElevenLabs default.
R2: normalize user/assistant transcripts, audio, interruption, tool calls and errors.
R3: document pricing/setup/limits and leave subjective/live measurements for PC.
Non-goals: Stream Deck, provider choice, ongoing live calls or subscriptions.

## Planning Contract
Use the existing Mint websocket transport with a configurable message tag. Keep
credentials behind the credentials port and out of adapter state. Use the GA
session.update protocol; require an explicit model, configure server VAD and input
transcription, register the same session tool schemas. Convert streaming PCM16
16 kHz input to 24 kHz; emit tagged 24 kHz output the existing browser understands.
The current browser has no playback-offset feedback: conservatively truncate the
interrupted item at zero rather than retain unheard assistant context.

## Implementation Units
### U1. Provider
Add process, frame decoder and PCM conversion modules, registry facade, bounded
startup queue and timeout, owner/socket cleanup and safe errors. Verify wire
frames and normalized events using injected transport/credentials doubles.
### U2. Host selection
Add provider setting (default ElevenLabs) and optional voice id, OpenAI credential
lookup and wrapper using the same read-only prompt. Verify config validation,
selection, credential presence and unchanged tool allowlist.
### U3. Documentation
Update config reference/template, package README and comparison table. Include
PC configuration and exact post-deploy checks; no fabricated measurements.

## Risks and review
Protocol drift: link official GA docs and test actual wire shapes. Sample-rate
mismatch: deterministic conversion tests across chunk boundaries. Tool replay:
track pending call ids and return results once; never execute from argument deltas.
Credentials/errors: fixed public messages and no raw upstream payload forwarding.
Budget: retain existing time limits; minute caps are not dollar caps.
Plan review: checked feasibility, coherence and security sequentially; playback
feedback limitation explicitly bounded above. No unresolved operator decision.

## Verification Contract
Compile/format and standalone tests; affected host tests and required lint/guards;
new-test mutation check in an isolated worktree; pre-pr and fresh PR body guards.
CI owns coverage/dialyzer/full required jobs. PC owns live mic/interruption/summary
comparison under the combined USD 25 budget, recorded as post-deploy checks.

## Definition of Done
Real provider and config wiring, passing scoped gates, documented facts, ready PR
with current-head validation evidence and explicit unrun live checks.
