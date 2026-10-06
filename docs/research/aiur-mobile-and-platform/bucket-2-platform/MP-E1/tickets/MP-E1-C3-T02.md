---
ticket_id: MP-E1-C3-T02
feature_id: MP-E1
chunk_id: MP-E1-C3
bucket: 2-platform
title: Durable queue store that fails closed
status: blocked
blocked_by: [DESIGN-E1, MP-E1-C2-T01, MP-E1-C3-T01]
prior_units: [U6]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F9]
size_owner: n/a (new file)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C3-T02 — `Aiur.BuildQueue.Store`

> **Plan refresh (wave 0).** New file under `build_queue/`; moves unchanged
> after MP-R1. The path key comes from C3-T01.

## Identity and outcome

- Bucket 2, MP-E1, C3, T02.
- **User value:** queue order, edges, write intents and alert latches survive
  a restart; a damaged file stops writes instead of guessing.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/store.ex`:
  `load() :: {:ok, doc} | {:error, reason}`, `save(doc) :: :ok | {:error, reason}`,
  using `Model.encode/decode` (C2-T01) and `Aiur.JsonStore`.

## Dependencies and blockers

- DESIGN-E1, C2-T01, C3-T01. Concurrent with C4-T01.

## Verified starting point (`45a290e3`)

- `orchestrator/global_pause_store.ex:17-60`: `JsonStore.read(path, :missing)`,
  normalize, `read_failed` logs and returns `{:error, {:read_failed, _}}`.
- `JsonStore.write!` atomic rename + fsync (`json_store.ex:32-37`; `fs.ex:19-65`, F9).
- `Config.Paths.build_queue_dir/0` (C3-T01).

## Chosen design

- File `<build_queue_dir>/queue.json`. Missing file → `{:ok, empty_doc}`.
- Corrupt JSON, unsupported version or invalid field → `{:error, {:read_failed, reason}}`;
  the server (C3-T03) enters status `store_unavailable`, writes nothing and
  raises `system.queue.attention.store_unavailable` (C5-T02). It never
  overwrites the bad file; the operator runs `aiur queue recover` (C3-T07/C6-T03),
  which moves the bad file to `queue.json.corrupt-<unix>` first.
- `save/1` is called after every state change that must survive (intent
  recorded, outcome recorded, latch change, operator mutation).

## Implementation steps

1. `store.ex` (≈ 60 lines) mirroring `GlobalPauseStore`.

## Non-happy paths

- Path unavailable (`{:error, :missing_instance_key}`) → `store_unavailable`.
- Disk full on save → `{:error, _}`; the server does not perform the write
  whose intent could not be persisted (C3-T04).

## Compatibility and rollout

New file; no migration (version 1).

## Verification

| Test (`src/test/aiur/build_queue/store_test.exs`, PROPOSED; temp dir via `Application.put_env(:aiur, :decision_state_dir, tmp)`) | Expected | Fails without |
| --- | --- | --- |
| "missing file loads empty" | `{:ok, %{queues: []…}}` | the `:missing` default |
| "round-trips a saved document" | equal | save/load |
| "corrupt file loads as read_failed and is not overwritten" | `{:error, {:read_failed, _}}`; file bytes unchanged | fail-closed branch |
| "version 2 file is read_failed" | error | the codec check |

Mutation check: treat corrupt as empty → test 3 fails.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/build_queue/store_test.exs
```

## Completion and handoff

- [ ] Store with fail-closed load. Docs: none.
- Dependents: C3-T03, C3-T07, C5-T01.
