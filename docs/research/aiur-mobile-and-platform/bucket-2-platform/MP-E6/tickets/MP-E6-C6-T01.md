---
ticket_id: MP-E6-C6-T01
feature_id: MP-E6
chunk_id: MP-E6-C6
bucket: 2-platform
title: Transcript store — state directory, append+fsync writer and torn-line recovery
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend, DESIGN-E6 header)", MP-E6-C11-T01]
prior_units: []
prior_boundaries: [VOX, K]
prior_features: []
prior_findings: []
size_owner: n/a (new file; paths.ex gains one function)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C6-T01 — `TranscriptStore` writer

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C6 transcript store, review API, CLI.
- **User value:** every voice conversation is kept in full on the operator's machine and
  survives crashes; nothing is lost because a summary replaced it (D17, brief §3).
- **Deliverable:** `Aiur.Config.Paths.voice_conversation_state_dir/0` (PROPOSED) and
  `Aiur.VoiceConversation.TranscriptStore` with `open(conversation_id, session_started)`,
  `append(conversation_id, record)` (fsync before return), `read(conversation_id)` with
  torn-tail recovery. Record schema = contract §9.
- **Non-goals:** index and listing (C6-T02), CLI (C6-T03), deletion (C6-T04).

## Dependencies and blockers

None in E6 (can start first). Stays independent of the provider.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Root resolution | `Paths.decision_state_dir/0` with app-env override and fail-closed resolution (`paths.ex:39-66`) |
| Derived leaf precedent | `current_run_membership_state_dir/0` (`paths.ex:68-87`) |
| Append+fsync barrier, torn-tail truncate on replay, parent-dir sync on create | `Aiur.DecisionLog` moduledoc (`decision_log.ex:1-20`), `prepare/3` (`:46-47`), `Aiur.Fs.sync_filesystem/0` (`fs.ex:86-87`) |
| Atomic writes | `Aiur.Fs.atomic_write/3` (`fs.ex:18-19`) |

## Chosen design

- Directory: `<decision_state_dir>/voice-conversations/` (mode 0700), file
  `<conversation_id>.ndjson` (0600); `conversation_id` must match `^vc_[A-Za-z0-9_-]{22}$`
  (refuses traversal by construction; the resolved path is also asserted to stay under the
  root, `PathSafety` precedent).
- Each line `{"v":1,"type":…,"at":iso8601,…}`. Append through a raw fd opened per session
  (kept by the writer), `:file.datasync/1` after each write, parent dir synced once at create
  (DecisionLog pattern).
- `read/1`: parse lines; a final line without `\n` or with invalid JSON is **reported**
  (`{:ok, records, %{torn_tail: true}}`) and skipped — not deleted, because transcripts are
  review material (differs from DecisionLog's truncate; justified by D17).
- Never stored: audio, keys, signed URLs (writer rejects records with fields named
  `audio`, `data_b64`, `signed_url`, `api_key` — defensive guard).

## Implementation steps

1. `Paths.voice_conversation_state_dir/0` with app-env override `:voice_conversation_state_dir`.
2. Writer GenServer (one per open conversation, or the session holds the fd) and read.
3. Tests on temp dirs.

## Non-happy paths

- Root unresolvable (`decision_state_dir` error) → session start refused `unknown`; voice
  never writes to a shared or default path.
- Disk full → append error → session ends (C4-T01).

## Compatibility and rollout

New directory under existing daemon-private state. Rollback: revert; files remain readable
text.

## Verification

| Test | Expected |
| --- | --- |
| "append returns only after data is synced" | inject a sync fun spy; called before return |
| "a torn last line is reported and skipped, earlier records intact" | write half a line → `torn_tail: true` |
| "path traversal ids are refused" | `../x` → error |
| "audio-bearing records are refused" | `%{data_b64: …}` → error, nothing written |
| "the directory resolves under decision_state_dir" | app env temp root |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/transcript_store_test.exs
make -C src fmt-check lint
```

Tests use temp dirs only (AGENTS.md "reading real state"). Run in an implementation worktree
with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check `~/.aiur/github-budget/agent-token`
before and after.

**Mutation checks.** Remove the sync call: the first test fails. Drop the id regex: the
traversal test fails.

## Completion and handoff

- [ ] Writer and reader; tests green.
- **Dependents:** C2-T04, C4-T01, C4-T03, C5-T02, C6-T02.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.TranscriptStore`. The root is `Config.transcript_root` (required,
  injected). aiur keeps `Aiur.Config.Paths.voice_conversation_state_dir/0` and passes its
  result. The core does not resolve aiur paths.
- The core carries its own fsync/torn-tail helpers (the `Aiur.DecisionLog` pattern, about 60
  lines) instead of calling `Aiur.Fs`. The traversal and root-containment checks are
  unchanged.
- Added predecessor: MP-E6-C11-T01.
