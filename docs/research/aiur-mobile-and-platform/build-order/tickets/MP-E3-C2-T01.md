---
ticket_id: MP-E3-C2-T01
feature_id: MP-E3
chunk_id: MP-E3-C2
bucket: 2-platform
title: "Claude Executor transcript ingest: tail the attached session's JSONL into the Executor conversation"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T02, MP-E4-C1-T02]
prior_units: [U4]
prior_boundaries: [EXE, CLD, PRJ]
prior_features: [MP-R7 (transcript_source for attached sessions), MP-E4 (journal)]
prior_findings: [security M6 and m10 (path gate), MP-E3 plan §4.1 option A; contract conversations-transcripts-anchors §4-§5, §11]
size_owner: "n/a (new module; small option added to claude/transcript_tailer.ex, 260 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C2-T01 — Claude Executor transcript ingest

## Identity and outcome

- Bucket 2 · MP-E3 · C2 · T01.
- **User value:** the dashboard has the Executor's whole conversation, from the
  session's first record, kept after the session ends and across daemon
  restarts (plan acceptance 1, 3, 9).
- **Deliverable:** `Aiur.Executor.TranscriptIngest` — one supervised tailer per
  attached Claude binding that follows `transcript_path` from the stored byte
  offset (or from the start on first attach), maps records with
  `Aiur.Claude.Transcript.extract_disk_record/2`, and appends them to
  `Conversation.Ref.executor()` through `Aiur.Conversation.Ingest`; plus an
  `{:offset, n}` start option and an offset callback on
  `Aiur.Claude.TranscriptTailer`.
- **Non-goals:** Codex (C3); drift alerting (C2-T02); subagent transcripts
  (C4-T02, RQ-E3-4).

## Dependencies and blockers

- DESIGN-E3 (OQ-E3-4 content shown does not change capture; the gate applies).
- MP-E3-C1-T02 (`{:executor_hook, event}` broadcasts carrying `transcript_path`),
  MP-E4-C1-T02 (`Ingest`).
- Concurrent with: MP-E3-C3, MP-E3-C4-T01.

## Verified starting point

- `Aiur.Claude.TranscriptTailer` (`src/lib/aiur/claude/transcript_tailer.ex`):
  options `:path`, `:on_message`, `:on_backfill_message`, `:from` (`:start |
  :end` only, `:43`), `:interval_ms` (400 ms default, `:27`); reads whole lines
  past a byte offset with `:file.pread` (`:135-160`); resets to 0 when the file
  shrinks (`:112-120`); partial trailing lines wait (`:163-175`). No API
  exposes or accepts an integer offset.
- `Aiur.Claude.Transcript.extract_disk_record/2` maps `assistant`, `user`,
  `attachment`/`queued_command` and ignores other types
  (`claude/transcript.ex:54-140`); `msg_id` is the record `uuid`
  (`:178`), tool ids via `tool_event_id/1` (`:189`).
- `DisplayTailer` is the read-only, hook-retargeted precedent for workers
  (`claude/display_tailer.ex:1-60`).
- Census of 30 recent local Claude transcripts (2026-10-06, types only):
  `assistant` 10,489, `attachment` 6,531, `user` 6,405, `queue-operation` 2,479,
  `system` 1,612, plus `pr-link`, `mode`, `permission-mode`, `ai-title`,
  `last-prompt`, `agent-name`, `bridge-session`, `file-history-*`; record
  `version` 2.1.287–2.1.290. Attachments: `queued_command` 288 of 6,531.

## Chosen design

PROPOSED `src/lib/aiur/executor/transcript_ingest.ex` (GenServer under a
`DynamicSupervisor`, one child per binding generation) and an edit to
`TranscriptTailer`:

- `TranscriptTailer` gains `from: {:offset, non_neg_integer()}` and
  `on_offset: (non_neg_integer() -> any())`, called after each consumed chunk.
  Existing `:start`/`:end` callers are unchanged.
- **Start:** on `{:executor_hook, %{harness: "claude", transcript_path: p}}` for
  the attached binding, if no tailer runs (or the path changed), start one with
  `from: {:offset, binding.transcript_offset}` when the binding's
  `locator_hash == sha256(p)`, else `from: :start`.
- **Per record:** `extract_disk_record/2` → events → `Ingest.append(Ref.executor(),
  source, events)` with `source = %{harness: "claude", role: :executor,
  provider_session_id: binding.provider_session_id, aiur_attempt_id: nil,
  transcript_source: %{kind: :provider_file, locator_hash: h},
  start_reason: binding_start_reason}`. `:user` records and `queued_command`
  attachments become `operator_message` with role `executor_operator`; a
  `queued_command` keeps `meta.origin: "remote_control"` (plan C2 design). This
  mapping is accepted **only** because the Executor conversation is the operator's own
  session **and** the tailed path passed `Aiur.Executor.TranscriptPath.validate/3`
  (MP-E3-C1-T02, security M6/m10). Worker conversations never map a provider `user`
  record to an operator role (MP-E4-C1-T01).
- **Path gate:** the tailer starts only for a `transcript_path` that C1-T02 kept
  (non-`nil`). At boot (step 3) the stored path is re-validated with the same function
  before tailing; a path that now fails is treated as unreadable (`gap`), not tailed.
- **Offset persistence:** `on_offset` → `Session.record_offset/2`, at most every
  2 s (and on terminate). The journal's `dedup_key` (record `uuid`) makes the
  overlap between the last persisted offset and the crash point harmless.
- **Session boundaries:** `SessionStart` `source` `clear | compact | resume |
  fork` arrives via T01's rebind; Claude writes a new JSONL for a new session
  id, so the hook's new `transcript_path` retargets the tailer `from: :start`
  and the journal opens a session with that `start_reason`. A file that shrinks
  under the same path (`TranscriptTailer` reset) → `Ingest.end_session(…,
  "superseded")` then a session `start_reason: "fork"` (contract §11).
- **Detach / end:** stop the tailer, `Ingest.end_session(ref, sid, reason)`.

## Implementation steps

1. `TranscriptTailer` options + tests (keep existing tests green).
2. `TranscriptIngest` + supervisor child; subscribe to `"executor_hook"`.
3. Daemon boot: if `Session.current/0` is `attached` with a `transcript_path`,
   start the tailer from the stored offset (restart resume, plan acceptance 9).

## Non-happy paths

- **Unreadable / moved file** → `Ingest.gap(ref, :source_unreadable, from, to)`
  when it becomes readable again or on the next hook with a new path; status
  keeps hook-derived state (plan §6).
- **Lazy flush** (Claude flushes lazily, `hook_events.ex:7`): live lag is the
  flush lag; RQ-E3-3 measures it (manual check below).
- **Daemon down while the Executor ran:** restart resumes from the stored
  offset; nothing is lost because the provider file is durable (contract §11).
- **Foreign session in the same repo** (not attached): its hooks are refused
  in T01/T02, so no tailer starts for it.
- **Stored path replaced by a symlink between runs:** boot re-validation fails, no
  tailer starts, `gap :source_unreadable` is recorded, and `aiur executor-session`
  shows the rejection reason.
- **Huge backfill on first attach:** the journal writer batches (MP-E4-C1-T02);
  the tailer is unchanged at 400 ms polls.
- **Privacy:** only the attached session's file is read; no scanning of
  `~/.claude/projects` (plan §6 "no scanning without opt-in").

## Compatibility and rollout

- Active only for an attached Claude binding. Rollback: revert; the journal keeps
  what was written.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/claude/transcript_tailer_test.exs test/aiur/executor/transcript_ingest_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "tailer from {:offset, n} skips earlier lines" | only later records | new option |
| "on_offset reports consumed bytes" | callback values monotonic | callback |
| "first attach backfills from start" (fixture JSONL: assistant text/thinking/tool_use, user string, tool_result list, queued_command) | entries in order, kinds mapped, RC message `meta.origin` | ingest mapping |
| "restart mid-file resumes without duplicates" | entry count equals record count | offset resume + dedup |
| "SessionStart clear with new path opens a new journal session" | session `start_reason: clear` | retarget |
| "file truncated under same path → superseded + fork" | two session lines | shrink handling |
| "partial trailing line not emitted" (existing behaviour) | not emitted until newline | — regression guard |
| "no tailer for a non-attached session" | none started | binding check |
| "boot does not tail a stored transcript_path that now fails validation" (m10) | fixture: stored path replaced by a symlink; no tailer, one `gap :source_unreadable` | boot re-validation (remove it and the tailer starts on the symlink) |
| "hook event with transcript_path nil starts no tailer" | none started | path gate |

Manual (RQ-E3-3, record in PR): attach a real Claude Code 2.1.x session, send a
prompt, and measure seconds from the `Stop` hook to the assistant entry appearing
in `History.list_entries(Ref.executor(), tail: true, principal: :internal)`; report p50/max over 10
turns with the CLI version.

## Completion and handoff

- [ ] Plan acceptance 1, 3, 9 covered by tests; RQ-E3-3 numbers recorded in
      `MP-E3/plan.md` §10.
- Dependents: MP-E3-C2-T02, MP-E3-C6-T01.
- Docs: MP-E3-C7-T02.
