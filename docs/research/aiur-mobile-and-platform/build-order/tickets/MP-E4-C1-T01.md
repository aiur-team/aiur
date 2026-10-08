---
ticket_id: MP-E4-C1-T01
feature_id: MP-E4
chunk_id: MP-E4-C1
bucket: 2-platform
title: "Conversation identity, entry and session records, and the append-only on-disk store"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T00]
prior_units: [U6]
prior_boundaries: [PRJ]
prior_features: [MP-R1 (identity contract, instance_id)]
prior_findings: [security M6 (operator provenance), contract conversations-transcripts-anchors §3-§6, §8]
size_owner: n/a (new modules; no file over 500 lines touched)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C1-T01 — Conversation identity, records and store

## Identity and outcome

- Bucket 2 · MP-E4 · C1 · T01.
- **User value:** the foundation of "full transcripts, kept locally, never
  rewritten" (brief §3, D15). Nothing user-visible yet.
- **Deliverable:** pure modules for conversation identity and record shapes,
  and a file store that appends batches durably, rolls segments, and rebuilds
  its head index. No process, no ingest (T02, T03).
- **Non-goals:** the writer process, PubSub, reading pages (C2), anchors (C3).

## Dependencies and blockers

- **DESIGN-E4** (decisions 3 and 5: reasoning stored or not; retention) — the
  record kinds and "no pruning" are fixed by it.
- **MP-E4-C1-T00** sets `@max_body_bytes` and `@segment_bytes`.
- Contract: `contracts/conversations-transcripts-anchors.md` §3–§6, §8.
- Concurrent with: MP-E4-C8-T02 docs drafting; MP-R6-C1.

## Verified starting point

- No `Aiur.Conversation*` module exists at `45a290e3`
  (`git grep -n "Aiur.Conversation" 45a290e3 -- src/lib` is empty).
- Durable state root: `Aiur.Config.Paths.decision_state_dir/0`
  (`src/lib/aiur/config/paths.ex:61-66`), instance- and project-scoped
  (`paths.ex:322-357`). Sibling leaf pattern with an `Application` override:
  `progress_retention_state_dir/0` (`paths.ex:99-109`).
- Test isolation: `src/test/support/test_boot_guard.exs:37-44` lists every
  `*_state_dir` override that tests must point at temp dirs.
- Append primitive to mirror: `Aiur.DecisionLog.prepare/3` (0700 dir, 0600 file,
  symlink rejection; `decision_log.ex:46-110`) and `append/2` (raw fd, write,
  `:file.sync`, `decision_log.ex:122-150`); `replay/3` truncates only an
  unacknowledged torn tail (`decision_log.ex:152-190`).
- Segment bound precedent: `AlertLedger @max_bytes 8 * 1_024 * 1_024`
  (`alert_ledger.ex:29`).
- Identity: `Aiur.TrackerIdentity.github_key/1` returns
  `{:github, owner_lc, repo_lc, provider_id}` for joinable identities
  (`tracker_identity.ex:141-146`).
- Transcript event shape: `Aiur.AgentEvents.transcript_event/3`
  (`agent_events.ex:121-133`): `role` in `:user | :assistant | :system |
  :command | :alert | :reasoning | :tool`, `body`, `timestamp`, `msg_id`,
  `sequence`, `turn_id`, `payload`. Codex command payload
  `%{command, output, title, workdir, exit_code}` (`codex/transcript.ex:122-145`);
  tool payload `%{tool, input, output, title, body, success}`; edits use
  `tool: "edit"` with the diff in `output` (`codex/transcript.ex:187-232`).
- Fallback identity to match: `LiveConversation.Normalizer.stable_id/3`
  (`live_conversation/normalizer.ex:196-199`), hashing via
  `LiveConversation.Source.opaque_id/2` (`live_conversation/source.ex:90-96`).

## Chosen design

PROPOSED files (all new):

| File | Responsibility |
| --- | --- |
| `src/lib/aiur/conversation/ref.ex` | `%Ref{v: 1, subject: {:worker, TrackerIdentity.t()} \| :executor}`; `worker/1 :: {:ok, t} \| {:error, :unjoinable}`, `executor/0`, `conversation_id/1`, `canonical/1`. |
| `src/lib/aiur/conversation/entry.ex` | Entry struct, `from_transcript_event/2 :: {:ok, entry_input} \| :skip`, `bound/2`, `dedup_key/1`, `to_json/1`, `from_json/1`. |
| `src/lib/aiur/conversation/session.ex` | Session struct, `start_line/1`, `end_line/2`, JSON codec. |
| `src/lib/aiur/conversation/store.ex` | Directory layout, `prepare/1`, `append_entries/3`, `append_session_line/2`, `append_anchor_line/2`, `read_head/1`, `rebuild_head/1`, `stream_entries/3`. |
| `src/lib/aiur/config/paths.ex` (edit) | `conversation_state_dir/0` = `<decision_state_dir>/conversations`, override `:conversation_state_dir`. |
| `src/test/support/test_boot_guard.exs` (edit) | add `:conversation_state_dir` to the override list. |

**conversation_id.** `"conv_" <> String.slice(Base.encode32(:crypto.hash(:sha256,
canonical), case: :lower, padding: false), 0, 26)`; `canonical` is
`"worker:github:<owner>/<repo>:<provider_id>"` or `"executor"` (contract §3).

**Entry mapping** (`from_transcript_event(event, opts)`, `opts[:subject_kind]`):

| `event.role` | `kind` | entry `role` | `body` / `output` |
| --- | --- | --- | --- |
| `:assistant` with `kind: :assistant_delta` | — | — | `:skip` |
| `:assistant` | `message` | `agent` | body |
| `:reasoning` | `reasoning` | `agent` | body (stored; display per DESIGN-E4 decision 3) |
| `:command` | `command` | `agent` | body = command; `output` = `payload.output`; `meta` = `%{exit_code, cwd}` |
| `:tool`, `payload.tool == "edit"` | `diff` | `tool` | body = title; `output` = diff text |
| `:tool` (other) | `tool_result` | `tool` | body = display body; `output` = `payload.output`; `meta` = `%{tool, success}` |
| `:user`, worker, `payload.delivery_id` set (daemon delivery evidence from `observe_operator_delivery/4`) | `operator_message` | `operator` | body |
| `:user`, worker, **no** `delivery_id` (a provider record: tool result, aiur prompt, or anything an agent wrote into its own JSONL) | `system` | `provider_input` | body; `meta.provider_role = "user"` |
| `:user`, executor (path validated by MP-E3-C1-T02) | `operator_message` | `executor_operator` | body |
| `:system`, `:alert` | `system` | `system` | body; `meta.alert = true` for `:alert` |

This adds two optional fields to contract §5 (`output`, `meta`); the contract
is amended in the same PR (owner MP-E4).

**Operator provenance (Phase D, security M6).** Provider JSONL files are
agent-writable, and Claude `user` records also carry tool results and the aiur prompt.
So a worker entry gets role `operator` **only** from daemon delivery evidence
(`refs.delivery_id` set by the `observe_operator_delivery/4` tee, T03). The Remote-Control
display path (`SessionLifecycle.display_tailer_handler/3`) reads the provider file, so
its `:user` records always map to `provider_input`; the delivery tee writes the operator
line for the same input, and the dedup key keeps them separate (different role). Views
label `provider_input` "provider input", never as the operator (contract §5).

**refs:** `provider_msg_id = msg_id`; `turn_id`; for `command`, `tool_result` and `diff`
also `tool_call_id = payload.tool_call_id || msg_id`. The Codex tool item id
is the provider call id that `ToolExecutor` records as the invocation id
(census in contract §15: 1,851 of 2,164 publications matched a tool entry's
`msg_id`), which is what MP-E4-C3-T02's `exact` anchoring joins on.
`delivery_id` comes from `payload.delivery_id` (operator deliveries, T03).

**Bounds** (`bound/2`): `body` and `output` each ≤ `@max_body_bytes`
(default 65,536 unless T00 says otherwise). Over the bound: keep the first and
last 16,384 bytes at UTF-8 boundaries, join with `"\n…[N bytes omitted]…\n"`,
set `body_truncated` / `output_truncated: true`.

**dedup_key** (contract §5): first present of
`{:msg, role, provider_msg_id}` → `{:item, role, provider_item_id}` (passed by
the tee from the raw Codex item, T03) → `{:call, role, tool_call_id}` →
`{:fallback, role, turn_id, occurred_at, body}`; then
`"ent_" <> opaque digest`. `occurred_at` is in the fallback (unlike
`stable_id/3`) so two identical commands in one turn are not merged.

**Store layout** under `<conversation_state_dir>/<conversation_id>/`:
`entries.000001.jsonl`, … (append only), `sessions.jsonl`, `anchors.jsonl`,
`head.json` (`{v, last_pos, last_session_seq, segments: [{n, first_pos,
last_pos, bytes}]}`, written by temp file + rename; a cache, rebuildable), and
`subject.json` (`{v, conversation_id, kind, owner, repository, identifier,
provider_id}` or `{v, conversation_id, kind: "executor"}`), written once at
creation and never changed. It lets C2-T02 resolve a finished ticket's
display identifier to its conversation after the ticket left the run (the
drawer can only resolve rows of the current units snapshot,
`aiur_web/live/dashboard_live.ex:209-234`). The display `identifier` there is
informational; identity stays `provider_id`.

- `append_entries(dir, segment_state, [entry_json])`: one `:file.write` of the
  joined lines and one `:file.sync` per batch (DecisionLog's raw-fd pattern,
  but one sync per batch). Rolls to the next segment before a write that would
  exceed `@segment_bytes` (8 MiB default). Returns `{:ok, segment_state}`.
- `rebuild_head(dir)`: replays segments in order through `DecisionLog.replay/3`
  with a validator that requires `v`, integer `pos`, strictly increasing; a torn
  tail is truncated (never acknowledged, so this is not a rewrite); interior
  corruption returns `{:error, {:corrupt, segment, line}}`.
- No function deletes, truncates (except the torn tail via `DecisionLog`), or
  overwrites a segment, `sessions.jsonl` or `anchors.jsonl`. Static test
  enforces it.

## Implementation steps

1. Add `Paths.conversation_state_dir/0` + spec + moduledoc line; add the key to
   `test_boot_guard.exs`.
2. `Ref`, `Session`, `Entry` with `@spec` on every public function
   (`mix lint` runs `specs.check`).
3. `Store`: `prepare/1` (via `DecisionLog.prepare/3` for the dir and
   `sessions.jsonl`), segment naming, batch append, roll, head write/rebuild,
   `stream_entries(dir, from_pos, to_pos)` reading only the segments whose
   `[first_pos, last_pos]` overlaps.
4. Amend contract §5 with `output`, `output_truncated`, `meta`.

## Non-happy paths

- Unjoinable identity → `Ref.worker/1` returns `{:error, :unjoinable}`; callers skip.
- Symlinked conversation dir or file → refused (`DecisionLog` rule).
- `head.json` missing, unparsable or behind the last segment → rebuilt.
- Interior corruption in a segment → store returns `{:error, {:corrupt, …}}`;
  T02 opens the conversation read-only and raises one alert; it never
  "repairs" by rewriting.
- Non-UTF-8 bytes in a body → replaced with U+FFFD before encoding (the
  `AgentEventFeed.scrub/1` precedent) so one bad byte cannot make a line
  undecodable.
- Disk full mid-batch → `{:error, :enospc}` with nothing acknowledged; the
  partial line is a torn tail the next `rebuild_head/1` truncates.

## Compatibility and rollout

- New files only; no existing behaviour changes. No config key (a key for the
  location would need `reference/configuration.md`; DESIGN-E4 did not ask).
- Rollback: revert; the directory is unused until T02.

## Verification

Commands (do not run plain `mix test`; it overwrites the real agent token):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/ref_test.exs test/aiur/conversation/entry_test.exs \
  test/aiur/conversation/store_test.exs test/aiur/config/paths_conversation_test.exs
env -C src mise exec -- make ci
```

| Test (PROPOSED file) | Expected | Fails without |
| --- | --- | --- |
| `ref_test` "same identity → same id; owner case ignored" | equal ids for `Owner/Repo` and `owner/repo` | the `github_key/1` call (using `identity.identifier` instead) |
| `ref_test` "unjoinable identity has no conversation" | `{:error, :unjoinable}` | the `joinable?/1` guard |
| `entry_test` "assistant_delta skipped" | `:skip` | the delta clause |
| `entry_test` "a provider user record with no matching delivery is not an operator_message" (M6) | worker `:user` event without `payload.delivery_id` → `kind: "system"`, `role: "provider_input"` | the `delivery_id` condition (map every `:user` to `operator` and it fails) |
| `entry_test` "a daemon delivery is an operator_message" | worker `:user` with `payload.delivery_id: "d1"` → `kind: "operator_message"`, `role: "operator"`, `refs.delivery_id == "d1"` | — (condition must not over-match) |
| `entry_test` "two identical commands at different times are two keys" | distinct `dedup_key` | `occurred_at` in the fallback tuple |
| `entry_test` "200 KiB body keeps head and tail" | 16 KiB + marker + 16 KiB, `body_truncated: true`, valid UTF-8 | `bound/2` |
| `entry_test` "4-byte emoji on the cut stays whole" | `String.valid?/1` true | the UTF-8 boundary walk |
| `store_test` "batch of 50 is one fsync" | sync spy called once | per-entry sync |
| `store_test` "roll at segment bound" (bound 1 KiB in test) | second segment created, head lists both | roll check |
| `store_test` "head.json deleted → rebuilt equal" | identical map | `rebuild_head/1` |
| `store_test` "torn tail truncated, interior corruption refused" | tail dropped; corrupt middle → `{:error, {:corrupt, _, _}}` | validator / `DecisionLog.replay` options |
| `store_test` "modes 0700/0600" | `File.stat` modes | `DecisionLog.prepare/3` use |
| `store_test` "no rewrite API" (static) | module exports contain no `delete`, `truncate`, `rewrite`, `put_entry` | — (guard against future regression; not counted as coverage) |
| `paths_conversation_test` "override wins; default under decision dir" | both paths | the new function |

All tests use `System.tmp_dir!/0`-based dirs (AGENTS.md "Reading real state").

## Completion and handoff

- [ ] Modules + tests merged; `make ci` green on the head SHA.
- [ ] Contract §5 amended (`output`, `meta`).
- [ ] PR body lists each test with "fails with hunk X reverted" per AGENTS.md.
- Dependents: MP-E4-C1-T02, MP-E4-C2-T01, MP-E4-C8-T01, MP-E3-C2-T01.
- Docs: none user-facing yet (location documented in MP-E4-C8-T02).
