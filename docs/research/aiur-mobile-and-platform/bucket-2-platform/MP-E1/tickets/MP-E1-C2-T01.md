---
ticket_id: MP-E1-C2-T01
feature_id: MP-E1
chunk_id: MP-E1-C2
bucket: 2-platform
title: "Queue domain model and versioned JSON codec"
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U2]
prior_boundaries: [BO #30]
prior_features: []
prior_findings: [MP-E1 F9]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C2-T01 — `Aiur.BuildQueue.Model`: structs and JSON codec v1

> **Plan refresh (wave 0).** Pure code under `src/lib/aiur/build_queue/`
> (PROPOSED). It moves unchanged into the `build-queue` package after MP-R1
> (plan §10). It must not reference `Aiur.Orchestrator`, `Aiur.GitHub` or
> `Aiur.BuildOrder` (C1-T07, contract §8): graph helpers are reimplemented
> here, following the cited approaches, not called.

## Identity and outcome

- Bucket 2, MP-E1, C2 (pure domain core), T01.
- **User value:** one stable shape for queue state, so the store (C3-T02), the
  read model (C6-T01) and the planner agree, and a restart reads what was written.
- **Deliverable:** PROPOSED `src/lib/aiur/build_queue/model.ex` with structs
  and `encode/1` / `decode/1` for the store document.
- **Non-goals:** I/O, readiness logic.

## Dependencies and blockers

- DESIGN-E1 (gate; OQ-4 marker name appears only as a config-derived string).
- Concurrent with all of C1. Predecessor of C2-T02..T04, C3-T02, C4-T01.

## Verified starting point (`45a290e3`)

- Store pattern: `orchestrator/global_pause_store.ex:48-60` writes
  `%{"version" => 1, …}` maps via `Aiur.JsonStore`; `normalize/1` rejects
  bad shapes (`:32-36`).
- `Jason` is the JSON library (`alerts.ex:188`).
- Issue ids are GitHub numbers as strings (`github/issues.ex:987`).

## Chosen design

Structs (all fields required unless noted):

| Struct | Fields |
| --- | --- |
| `Queue` | `id` (`"q-" <> 4 hex`), `name`, `kind` (`:list | :build_order`), `root` (int or nil), `held` (bool), `generation` (int), `created_at` |
| `Item` | `issue_id`, `queue_id`, `position` (non-neg int, list kind only), `hold` (`nil | :operator | :external`), `override` (`nil | :manual_promotion`), `promoted_at`, `added_at` |
| `Edge` | `prerequisite`, `dependent`, `source` (`:list | :build_order | :native`) |
| `Observation` | `issue_id`, `open?` (`true | false | :unknown`), `labels`, `state_reason`, `pr` (`nil | :closed_unmerged | :merged | :open`), `observed_at_ms` |
| `Intent` | `id`, `issue_id`, `action` (`:promote | :withdraw | :mark | :unmark`), `target_labels`, `recorded_at_ms`, `outcome` (`nil | :ok | {:error, term}`) |
| `Latch` | `key` (`{cause, subject}`), `opened_at_ms` |

Store document: `%{"version" => 1, "queues" => [...], "items" => [...],
"edges" => [...], "intents" => [...], "latches" => [...]}`. Observations are
**not** persisted (always re-derived, plan §6 Restart). No titles or bodies.
`decode/1` returns `{:error, {:unsupported_version, v}}` for any other
version and `{:error, {:invalid, path}}` for a bad field; never raises.

## Implementation steps

1. `model.ex` with nested modules and `@type t`.
2. `encode/1`, `decode/1`, atom fields via explicit whitelists
   (`String.to_existing_atom` is not used on input).

## Non-happy paths

- Unknown version / corrupt field → error tuple; C3-T02 fails closed on it.
- Unknown extra keys are ignored (forward compatible within v1).

## Compatibility and rollout

New file. Version 1 is the first schema.

## Verification

| Test (`src/test/aiur/build_queue/model_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "round-trips a document" (StreamData generator over items/edges/intents) | `decode(encode(x)) == {:ok, x}` | the codec |
| "rejects version 2" | `{:error, {:unsupported_version, 2}}` | the version check |
| "rejects an unknown action atom" | `{:error, {:invalid, ["intents", 0, "action"]}}` | the whitelist |
| "does not persist observations or titles" | encoded keys exclude them | the field list |

Mutation check: accept any version → test 2 fails; use `String.to_atom` → test 3 fails.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue/
```

## Completion and handoff

- [ ] Structs and codec with tests. Docs: none.
- Dependents: C2-T02..T04, C3-T02, C4-T01.
