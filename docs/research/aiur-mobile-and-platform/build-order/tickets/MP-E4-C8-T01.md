---
ticket_id: MP-E4-C8-T01
feature_id: MP-E4
chunk_id: MP-E4-C8
bucket: 2-platform
title: "Import pre-journal history from workspace and IssueLog files as a marked import session"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T03]
prior_units: [U4, U6]
prior_boundaries: [PRJ, RUN, CDX]
prior_features: []
prior_findings: [RQ-E4-4 (answered below for Codex; others by fixture tests)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C8-T01 — Pre-journal importer

## Identity and outcome

- Bucket 2 · MP-E4 · C8 · T01.
- **User value:** tickets that were already running when the journal shipped, or
  that resume after it, show their earlier conversation as far as the old files
  allow, clearly marked as imported and possibly incomplete.
- **Deliverable:** `Aiur.Conversation.Importer`, run once by the journal writer
  when a worker conversation is created, that writes a `pre_journal` gap and an
  `import` session from the workspace `logs/agent.ndjson` (full bodies) or,
  failing that, the current launch's IssueLog transcript (truncated bodies).
- **Non-goals:** importing other launches' IssueLog files (per-launch roots are
  not indexed by ticket across launches); any rewrite of the source files.

## Dependencies and blockers

- DESIGN-E4 (partial-history copy). MP-E4-C1-T03 (the tee passes the hint).
- Concurrent with: C2, C3.

## Verified starting point

- Workspace log: `AgentEventLog.write/3` appends the backend message map as-is to
  `<workspace>/logs/agent.ndjson` and writes nothing for remote hosts
  (`src/lib/aiur/agent_event_log.ex:23-48`, `:24`).
- Offline extraction: `CodingAgent.transcript_module(backend).extract/2` is a pure
  function of the message (`agent_runner/message_handler.ex:293-298`);
  `Aiur.Codex.Transcript.extract/2` reads only the message map
  (`codex/transcript.ex:24-37`). **RQ-E4-4 for Codex: replayable offline.** A
  census of 378 workspace logs found Codex `item/completed` records in them
  (see MP-E4-C1-T00), so Codex history imports with full bodies.
- IssueLog transcript `<logs-root>/<launch>/log/<repo>.<id>.agent_events.jsonl`
  holds `role, body, timestamp, msg_id, sequence, turn_id, payload` with bodies
  cut to 1,000 chars (`issue_log.ex:37,46-47`); `IssueLog.read_tail/2` pages it
  (`issue_log.ex:111-141`).

## Chosen design

- **Trigger:** T03's first `Ingest.append/3` for a worker carries
  `import_hint: %{workspace: path | nil, backend: label, identifier: id}`. The
  writer runs the importer only when the conversation directory was created by
  this call (no `head.json`, no segments).
- **Order:** (1) one `gap` entry `pre_journal` with `from: nil`, `to:` the first
  live record's time; (2) a session `start_reason: "import"`, `harness: backend`,
  `transcript_source.kind: "provider_file"`; (3) imported entries; (4) the
  session ends `end_reason: "superseded"`; (5) the live batch opens its own session.
- **Source choice:** workspace `agent.ndjson` when present and the backend's
  extractor yields ≥ 1 event from it; else the current launch's IssueLog JSONL
  (entries flagged `body_truncated: true` when the body is exactly at the 1,000
  char cut, `meta.import_source: "issue_log"`); else nothing beyond the gap.
- **Streaming:** read in chunks of 500 lines via `handle_continue/2` steps so the
  writer keeps receiving casts; live inputs that arrive during import are
  buffered and appended after it (they are newer).
- **Dedup:** imported entries go through the same `dedup_key` rule, so importing
  twice (writer restarted mid-import) adds nothing.
- `complete_from_start` stays `false` for this conversation (C2-T01 rule).

## Implementation steps

1. `Importer.plan(hint) :: {:workspace, path} | {:issue_log, path} | :none`.
2. `Importer.stream(plan, backend) :: Enumerable.t(transcript_event)`.
3. Writer: import state machine in `handle_continue`.
4. Fixtures: one Codex `agent.ndjson`, one IssueLog JSONL, one malformed file.

## Non-happy paths

- Malformed lines skipped and counted; the count goes into the import session's
  record (`meta.skipped_lines`).
- Workspace removed between hint and import → IssueLog fallback.
- Very large workspace logs (47 MB max in the T00 census): streaming bounds
  memory; time is bounded by the 500-line steps.
- Remote worker: no workspace log on this host → IssueLog fallback.
- Symlinked `logs/agent.ndjson` inside an agent-writable workspace: refused
  (`File.lstat/1` type check) — an agent must not redirect the daemon to read an
  arbitrary file into the journal.

## Compatibility and rollout

- Runs only for conversations created after this ships. Rollback: revert; already
  imported sessions stay, marked `import`.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/importer_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "codex workspace log imports full bodies after a pre_journal gap" | gap, import session, entries, then live session | importer + ordering |
| "import twice adds nothing" (kill writer mid-import, restart) | same entry count | dedup on import |
| "no workspace → IssueLog fallback with truncation flag" | entries with `meta.import_source` | fallback |
| "malformed lines skipped and counted" | `skipped_lines: 2` | counter |
| "symlinked agent.ndjson refused" | no import, gap only | lstat check |
| "live inputs during import land after it" | pos order: imported < live | buffering |
| "existing conversation never re-imports" | no new import session | creation check |

## Completion and handoff

- [ ] RQ-E4-4 result for non-Codex backends recorded in `MP-E4/plan.md` §10
      (which backends import from the workspace log, which fall back).
- Dependents: none.
- Docs: C8-T02 explains "imported history".
