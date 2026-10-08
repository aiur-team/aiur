---
ticket_id: MP-E6-C4-T03
feature_id: MP-E6
chunk_id: MP-E6-C4
bucket: 2-platform
title: ContextBuilder — redacted, budgeted, time-stamped context blocks recorded in the transcript
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T02, MP-E6-C6-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C4-T03 — `ContextBuilder`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C4.
- **User value:** the assistant starts each conversation already knowing the ticket or
  project state, never sees a secret, and a reviewer can see exactly what it was told.
- **Deliverable:** `Aiur.VoiceConversation.ContextBuilder.build(target, ports, opts) ->
  %{text, blocks: [%{source, ref, observed_at, text}], gaps: [String.t()], tokens}`
  implementing MP-E6 plan §5 blocks; every block passes `Aiur.SecretRedactor.redact/1` and
  `redact_urls/1` before it is returned; the session writes each block as a `context`
  record (contract §9) before sending `text` to the provider.

## Dependencies and blockers

- **Predecessors:** C4-T02 (ports), C6-T01 (writer). Budget default from C3-T01
  (`context_token_budget`, 8,000 until the spike's RQ-E6-4 says otherwise).

## Verified starting point (base `45a290e3`)

- Redaction: `Aiur.SecretRedactor.redact/1` (`secret_redactor.ex:45-54`), `redact_urls/1`
  (`:56-60`).
- Dictation glossary for the assistant: `.claude/skills/aiur-agent/dictated-input.md` (exists
  at base) — included verbatim in the role pre-context by C4-T04, not here.

## Chosen design

| Block (worker target) | Source | Limit |
| --- | --- | --- |
| `identity` | target + status port | 200 tokens |
| `work` | ticket title/phase from status; last 20 messages | 3,500 tokens |
| `commands` | open Commands (question + option labels) | 1,500 tokens |
| `events` | last 10 milestones (C4-T05 buffer) | 800 tokens |
| `prior` | tail of the last voice session with this target + open drafts (C6-T02) | 1,500 tokens |
| `gaps` | one line per unavailable port ("Command data unavailable") | 100 tokens |

- Token estimate: `div(byte_size(text), 4)` (no tokenizer dependency); over budget →
  drop oldest messages first, then oldest events, never the `commands` or `gaps` blocks.
- Executor target blocks (status snapshot, all open Commands count + top 5, fleet events)
  are produced by the same function with C4-T06's port.
- Output order fixed; each block headed `### <name> (observed <iso8601>)`.

## Implementation steps

1. Block builders; 2. budget trimming; 3. redaction; 4. tests.

## Non-happy paths

- All ports unavailable → only identity + gaps; the session still starts (the operator can
  still brain-dump).
- A message containing a token-like string → redacted marker in both provider text and
  stored record (same string).

## Compatibility and rollout

Internal. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "secrets are redacted before the provider and the store" | a message with a GitHub token → FakeProvider `open` context and the transcript `context` record both contain `[REDACTED:` and not the token |
| "budget trimming drops the oldest messages first" | 200 messages, budget 1,000 → newest kept |
| "commands and gaps are never trimmed" | tiny budget → both blocks present |
| "a missing Command port yields a stated gap" | gaps contains "Command data unavailable" |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/context_builder_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Redact only the stored copy: the first test fails on the provider side.
Replace the gap line with an empty list when a port is nil: the gap test fails.

## Completion and handoff

- [ ] Builder with redaction and budget.
- **Dependents:** C4-T01 start sequence, C4-T06, C8-T02.

## Amendment 2026-10-08 — fast voice over a slow agent

Source: [../realtime-convo-research.md](../realtime-convo-research.md) (Kevin's request of
2026-10-08: voice with high-effort agents is "extremely slow and broken up"). Context-handoff
requirement: the voice assistant must be able to answer from a current briefing in about one
second, without stopping or waiting for the coding agent.

- The **status card** (MP-E6-C10-T02) is the first block and the main source of answers.
  The default start budget drops from 8,000 to **4,000 tokens** (card ~1,500 + Commands +
  prior session tail). The raw "last 20 messages" block moves out of start context and is
  served on request by `get_details(section: "conversation")` (MP-E6-C5-T01). Reason:
  start-context size adds directly to time to first audio (research §7 latency table).
- Added predecessor once C10-T02 lands: the builder calls `StatusCard.build/2`; until then
  the old `work` block stays (no ordering change to this ticket's own tests).
