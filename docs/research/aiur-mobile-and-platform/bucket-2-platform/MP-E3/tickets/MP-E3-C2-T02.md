---
ticket_id: MP-E3-C2-T02
feature_id: MP-E3
chunk_id: MP-E3-C2
bucket: 2-platform
title: "Claude transcript format guard: tested-version pin, unknown-record counting, one drift alert"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C2-T01]
prior_units: [U4]
prior_boundaries: [EXE, CLD]
prior_features: []
prior_findings: [MP-E3 plan §6 "Transcript format drift"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C2-T02 — Claude transcript drift guard

## Identity and outcome

- Bucket 2 · MP-E3 · C2 · T02.
- **User value:** when a Claude Code update changes its undocumented transcript
  format, the operator is told once, plainly, instead of silently seeing a
  thinner conversation.
- **Deliverable:** per-binding counters of records by `type` (mapped, ignored-
  known, unknown) and of records whose `version` is outside the tested range;
  one `system.executor.transcript.drift` alert per binding generation when the
  unknown rate crosses a threshold or the version is untested; counters exposed
  in `executor-session --json` (C1-T03) and the Executor status (C4-T05).
- **Non-goals:** auto-adapting to new formats.

## Dependencies and blockers

- DESIGN-E3 (alert copy). MP-E3-C2-T01.

## Verified starting point

- The Claude transcript format is undocumented (plan §2.3 "History read API:
  none documented"). `extract_disk_record/2` ignores non-conversational types
  (`src/lib/aiur/claude/transcript.ex:54-75`).
- Census (2026-10-06, 30 local transcripts, types only): known non-conversational
  types seen — `queue-operation`, `system`, `pr-link`, `mode`, `permission-mode`,
  `atis-latch`, `ai-title`, `last-prompt`, `agent-name`, `bridge-session`,
  `file-history-delta`, `file-history-snapshot`; attachment subtypes include
  `total_tokens_reminder`, `queued_command`, `hook_non_blocking_error`,
  `edited_text_file`, `task_reminder`, `deferred_tools_record`, `environment`,
  `skill_listing`. Record `version` values 2.1.287–2.1.290; local CLI 2.1.291.
- `LiveConversation` already counts dropped shapes (`diagnostic_counts`, plan §6).
- System alerts: `Aiur.Alerts.emit_system/2` (`alerts.ex:103-106`).

## Chosen design

- `Aiur.Executor.TranscriptFormat` (PROPOSED, pure): `classify(record) ::
  :mapped | :ignored_known | :unknown` using an allowlist module attribute of the
  census types above; `version_status(record) :: :tested | :untested | :absent`
  against `@tested_versions` (`~r/^2\.1\.(28[7-9]|29\d)$/` at implementation
  time, updated with each fixture refresh).
- `TranscriptIngest` (C2-T01) feeds every raw record through `classify/1` before
  extraction and keeps counters in its state; `Session` stores a snapshot every
  60 s for CLI/status.
- **Alert rule:** after ≥ 200 records in a generation, if unknown > 2 % or any
  `:untested` version → emit once per generation
  `system.executor.transcript.drift` (`needs_attention: true`) with the counts
  and the version, never record content.
- **Fixtures:** `src/test/fixtures/claude_transcripts/2.1.29x/*.jsonl`
  (synthetic records with the real shapes; no real content).

## Implementation steps

1. `TranscriptFormat` + table tests.
2. Counters in `TranscriptIngest`; snapshot into the binding.
3. Alert emission with per-generation latch.

## Non-happy paths

- `version` absent on a record → counted `:absent`, not an alert by itself.
- A new type that carries conversation (Claude adds one) → shows up as
  unknown; alert tells the operator; the entries are still missing until a code
  update (honest gap, not a guess).

## Compatibility and rollout

- Observability only. Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/executor/transcript_format_test.exs test/aiur/executor/transcript_ingest_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "census types classify as ignored_known" | all `:ignored_known` | allowlist |
| "unknown type above 2 % after 200 records alerts once" | one alert per generation | latch (mutation: remove latch → many alerts) |
| "untested version alerts" | alert with version | version rule |
| "alert payload has counts, no content" | no `body`/`text` keys | payload builder |

## Completion and handoff

- [ ] Fixtures checked in; tested-version range documented in the moduledoc.
- Dependents: MP-E3-C4-T05 (status shows counters), MP-E3-C7-T01 (`--check`).
