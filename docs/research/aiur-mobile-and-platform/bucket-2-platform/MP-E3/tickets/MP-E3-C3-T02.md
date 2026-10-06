---
ticket_id: MP-E3-C3-T02
feature_id: MP-E3
chunk_id: MP-E3-C3
bucket: 2-platform
title: "Codex Executor transcript reader: tail the rollout JSONL with a version-pinned extractor"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C3-T01, MP-E3-C2-T01]
prior_units: [U4]
prior_boundaries: [EXE, CDX, PRJ]
prior_features: [MP-R7 (attached transcript_source)]
prior_findings: [RQ-E3-1 (census in MP-E3-C3-T01); OQ-E3-1 (harness order)]
size_owner: n/a (new extractor module)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C3-T02 — Codex rollout reader

## Identity and outcome

- Bucket 2 · MP-E3 · C3 · T02.
- **User value:** a Codex TUI Executor's conversation appears in the dashboard
  the same way a Claude one does (plan acceptance 2).
- **Deliverable:** `Aiur.Codex.RolloutTranscript.extract/2` (rollout record →
  transcript events) and the Codex branch of `Aiur.Executor.TranscriptIngest`
  (C2-T01) that tails the rollout file named by the hook's `transcript_path`
  (or located per C3-T01's rule) into `Conversation.Ref.executor()`.
- **Non-goals:** the app-server history reader (RQ-E3-2) — the ticket must not
  ship both readers (MP-E3 chunks).

## Dependencies and blockers

- DESIGN-E3 and **OQ-E3-1** (if Kevin chooses "Claude first", this ships after
  the Claude path is approved in use).
- MP-E3-C3-T01 (fixtures and confirmation of the TUI shape at 0.160.x).
- MP-E3-C2-T01 (ingest process; reuses its tailer with a different extractor).

## Verified starting point

- Rollout shape at 0.157–0.160.1 (census in MP-E3-C3-T01): `event_msg` records
  with `payload.type == "item_completed"` carry a typed `item`:
  `AgentMessage{content}`, `Reasoning{summary_text, raw_content}`,
  `CommandExecution{command, aggregated_output, exit_code, cwd}`,
  `FileChange{changes}`, `UserMessage{content}`, `DynamicToolCall`,
  `McpToolCall`, `SubAgentActivity`, `ContextCompaction`; `session_meta`
  carries `cli_version` and `originator`.
- `TranscriptTailer` reads whole lines past an offset and maps them through
  `Aiur.Claude.Transcript.extract_disk_record/2` (`claude/transcript_tailer.ex:1-20`);
  C2-T01 adds `{:offset, n}` and `on_offset`. The extractor is hard-wired; this
  ticket adds an `:extractor` option (default the Claude function).
- App-server-side extractor for comparison: `Aiur.Codex.Transcript`
  (`codex/transcript.ex:24-145`) — different casing, not reusable directly.

## Chosen design

| Rollout item type | Transcript event | Notes |
| --- | --- | --- |
| `AgentMessage` | `:assistant`, body = joined text `content` | `msg_id` = item `id` |
| `Reasoning` | `:reasoning`, body = `summary_text` joined, else `raw_content` | |
| `CommandExecution` | `:command`, body = `command`; payload `%{command, output: aggregated_output, exit_code, workdir: cwd}` | same payload keys as `Codex.Transcript` so the journal mapping (MP-E4-C1-T01) is shared |
| `FileChange` | `:tool`, payload `%{tool: "edit", output: diffs joined}` | |
| `UserMessage` | `:user` → `operator_message` role `executor_operator` | |
| `DynamicToolCall`, `McpToolCall` | `:tool`, `msg_id` = item `id` | |
| `ContextCompaction` | `:system` "Context compacted" + session boundary hint | journal opens a new session `start_reason: compact` |
| `SubAgentActivity` | none (C4-T02 consumes it for the background-agent roster) | |
| anything else / `response_item` / `token_count` | skipped, counted by C2-T02's guard (Codex allowlist) | |

- **Version pin:** `session_meta.cli_version` read once per file; tested range
  `0.157.0–0.160.x`; outside → C2-T02-style drift alert and the capability
  record (C3-T03) shows `untested`. A rollout whose first record is not
  `session_meta` with a known major layout → reader refuses with `unsupported`
  and writes nothing (never partial garbage; chunk test).
- **Start/offset/dedup:** as C2-T01; `dedup_key` from item `id`.

## Implementation steps

1. `RolloutTranscript` + fixture tests (C3-T01 fixtures).
2. `TranscriptTailer` `:extractor` option (default unchanged).
3. Codex branch in `TranscriptIngest` keyed on `binding.harness == "codex"`.

## Non-happy paths

- `transcript_path` null → locate by `session_id` per C3-T01's rule; not found
  → gap `source_unreadable` and capability `unsupported` with reason.
- Codex hooks not yet trusted → no hook, no path; status `unknown`; `--check`
  (C7-T01) says "hooks need review in Codex".
- Rollout rewritten by a future migration (`codex migrate-rollouts`, plan RQ-E3-1)
  → file shrink → new session `fork`, guard alerts on layout.

## Compatibility and rollout

- Only for `--harness codex` bindings. Rollback: revert; Codex reported
  `unsupported` again.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/codex/rollout_transcript_test.exs test/aiur/executor/transcript_ingest_codex_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "each fixture item type maps per the table" | events | clauses |
| "unknown layout refuses with unsupported, writes nothing" | zero entries, capability reason | layout check (mutation: best-effort parse fails) |
| "compaction opens a new session" | `start_reason: compact` | boundary hint |
| "restart resumes from offset without duplicates" | count equal | offset + dedup |
| "claude extractor default unchanged" (existing tailer tests) | green | — regression guard |

Manual: attach a real Codex 0.160.x TUI Executor (`aiur executor-attach --harness
codex`, trust hooks), run two prompts, open the Executor view (after C6) or
`aiur executor-session --json`, confirm entries.

## Completion and handoff

- [ ] Fixtures from C3-T01 in `src/test/fixtures/codex_rollouts/0.160/`.
- Dependents: MP-E3-C3-T03.
