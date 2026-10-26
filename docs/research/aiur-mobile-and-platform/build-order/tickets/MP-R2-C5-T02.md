---
ticket_id: MP-R2-C5-T02
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Aiur.Events.Envelope.to_external/2 — pure, allowlist-only serializer to external envelope v1
status: ready
blocked_by: [DESIGN-R2 §2, MP-R2-C5-T01]
prior_units: [U8]
prior_boundaries: [BUS #10]
prior_features: [MP-E4 (anchor, RC-07), MP-R1 (instance_id, RC-02)]
prior_findings: []
size_owner: n/a (new file, ≤ 200 lines); re-checked against U8 assignments.csv at 761756f39 (no existing oversized edit)
base_sha: 761756f394e6783794c777668fc1a26a540e4059
researched: 2026-10-06
---

# MP-R2-C5-T02 — External envelope v1 serializer

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C5.** Inert until the
  exporter (C6-T02) calls it.
- **Deliverable:** `Aiur.Events.Envelope.to_external(event, opts) ::
  {:ok, map()} | :skip` that turns one internal `{:event, map}` payload
  into the contract §4.2 envelope using **only** the catalog entry's
  allowlists. Nothing outside the allowlist can appear in the output.
- **Non-goals:** no `seq` (assigned by the exporter), no I/O, no change to
  the internal envelope (contract §4.1 unchanged).

## Dependencies and blockers

- DESIGN-R2 §2 (feed exists at all); C5-T01 (entry struct and allowlists).
  The allowlist *contents* follow KQ-R2-3 through C5-T01; this ticket's
  code does not depend on the answer, so it is `ready`.
- `instance` comes from opts (C5-T04 supplies the provider); tests pass a
  literal.
- Concurrent with C5-T03, C5-T04, C6-T01.

## Verified starting point (761756f394e6783794c777668fc1a26a540e4059)

Refreshed 2026-10-25 from 45a290e3. Original `researched` date retained.
DESIGN-R2 approval is recorded in EXECUTOR-APPROVALS.md at 9ce9fdc6.
Size owners were checked against the U8 ledger; see [refresh audit](../../refresh/MP-R2-C4-T04.md).

| Fact | Evidence at the refreshed head |
| --- | --- |
| Internal payload plus atom id/topic, optional digest source and observation | `src/lib/aiur/events/publisher.ex:220-245` |
| JSON-normalized durable record | `src/lib/aiur/events/journaled_publish.ex:28-35`; Executor caller `src/lib/aiur/executor_events.ex:61-75` |
| Observation fields and unknown occurred_at | `src/lib/aiur/ticket_observation.ex` |
| Typed extraction precedent | `src/lib/aiur/executor_wake_projection.ex` |
| Proposed external envelope | `contracts/events-and-replay.md` §4.2 |

PROPOSED: `src/lib/aiur/events/envelope.ex` and its tests. Packaging has not added an external envelope.

## Chosen design

Output (string keys, JSON-ready):

```json
{"v":1,"instance":"<instance_id>","id":1791281110183123,"topic":"ticket.142.pr.merged",
 "class":"live","occurred_at":null,"observed_at":"2026-10-06T15:02:13Z",
 "source":"legacy","refs":{"ticket":"142","pr_number":2210,"head_sha":"abc1234"},
 "attrs":{"action":"merged"},"payload_version":1,"anchor":null}
```

- `to_external(event, instance: id, catalog: Catalog)`:
  1. `entry = catalog.lookup(topic)`; `entry.export? == false` → `:skip`.
  2. `id` must be a positive integer, else `:skip` (malformed).
  3. `refs`: for each allowed key, read atom **or** string key (both shapes
     exist, `publisher.ex`; executor JSON at `executor_events.ex`)
     from the payload, the nested `pr`/`pr.head` maps (same paths as
     `executor_wake_projection.ex`), or the topic (ticket segment).
     Coerce with typed extractors: `ticket` = topic ticket segment string;
     `pr_number`, `decision_version` positive integer; `head_sha` matches
     `~r/\A[0-9a-fA-F]{7,64}\z/`; `decision_id` binary ≤ 128 bytes of
     `[A-Za-z0-9_-]`. A value that fails coercion becomes `null`; it is
     never passed through raw.
  4. `attrs`: `{key, {:enum, values}}` keeps the value only if it is in
     `values`; `:integer`, `:boolean`, `:id`, `:sha` likewise; otherwise
     `null`.
  5. `occurred_at`/`observed_at` from `ticket_observation`, ISO8601 or
     `null` — never replaced with "now" (`ticket_observation.ex`).
  6. `source`: `TicketObservation` source kinds are only `:agent_event`,
     `:agent_alert`, `:legacy` (`ticket_observation.ex`), so
     GitHub, CI and orchestrator events arrive as `:legacy`. Mapping:
     `:agent_event` → `"agent"`, `:agent_alert` → `"agent_alert"`; for
     `:legacy`, payload `"source" == "alert"` (set by `alerts.ex`) →
     `"alert"`, topic `executor.` → `"executor"`, otherwise `"legacy"`.
     The envelope never guesses `"github"` from a topic shape.
  7. `anchor` is always `null` in v1 (RC-07: the address is MP-E4's
     journal position; clients resolve it through E4 by `(instance, id)`;
     the bus never computes it).
  8. `class` = `entry.class` as a string; `payload_version` = entry's.
- **Invariant (property):** `Map.keys(result)` is exactly the 12 envelope
  keys of the sample above (`v, instance, id, topic, class, occurred_at,
  observed_at, source, refs, attrs, payload_version, anchor`). `seq` is the
  13th wire key, but the exporter (C6) adds it, so `to_external/2` never
  emits it (T-7); `Map.keys(refs) ⊆ entry.refs`; `Map.keys(attrs) ⊆ attr keys`.

## Implementation steps

1. Add `Envelope` with the steps above and private typed extractors
   (copy the three regex/guards from `executor_wake_projection.ex`
   rather than calling a private function there).
2. Add tests (below), including a StreamData property (`{:stream_data,
   "~> 1.2", only: :test}` is already a dependency, `src/mix.exs`).
3. Add the file to the C1-T06 member list.

## Non-happy paths

- Payload contains a comment body, title, message, failure excerpt or file
  path: dropped, because none of those keys is allowlisted (privacy rule,
  contract §1.3 and §4.2).
- Atom/string key collision (both present, different values): atom key wins
  (internal producers set atoms; JSON replays set strings); documented and
  tested.
- `ticket_observation` missing (should not happen after Publisher): times
  `null`, source `"unknown"`.
- Very large payloads: only allowlisted keys are read; cost is bounded.

## Compatibility and rollout

Pure function, no config. Rollback: delete.

## Verification

`envelope_test.exs`:

1. `"drops every key not in the allowlist"` — payload with `body`, `title`,
   `message`, `reason`, `comment: %{"body" => …}`, `files: [...]` plus
   allowed keys → result `refs`/`attrs` contain only allowed keys; JSON of
   the result does not contain the body text. **Fails** if step 3/4 passes
   unknown keys through (mutation: replace the allowlist filter with
   `Map.take(payload, all_keys)`).
2. `"reads atom and string keys"` — same event with atom keys and with
   string keys (executor replay shape) → identical output.
3. `"occurred_at nil stays null"` — observation with `occurred_at: nil` →
   `"occurred_at" => nil`. **Fails** if replaced with `DateTime.utc_now()`.
4. `"invalid typed values become null"` — `head_sha: "not a sha"`,
   `pr_number: -1`, enum attr outside the set → `nil` each.
5. `"non-exported topics are skipped"` — `executor.decision.requested` →
   `:skip`; `ticket.1.agent.custom.x` → `:skip`.
6. `"anchor is null in v1"` — any exported event → `"anchor" => nil`.
7. Property / table: for 1 000 generated payloads per exported entry, the
   key-set invariant holds: exactly those 12 keys, and no `"seq"` key.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/envelope_test.exs test/aiur/events/catalog_test.exs
```

Mutation check: replace the refs filter with pass-through → tests 1 and 7
fail; make `occurred_at` default to now → test 3 fails; restore → pass.

## Completion and handoff

- [ ] Tests 1–7 added and mutation-checked.
- [ ] Docs: none (inert; C7-T01 documents the wire format).
- Dependents: C6-T02 (calls it per event), C7-T01/T02 (serve its output),
  MP-N4/N5/N6 (consume `refs.decision_id` + `instance`).
