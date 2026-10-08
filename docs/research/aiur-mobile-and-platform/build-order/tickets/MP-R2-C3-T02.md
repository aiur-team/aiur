---
ticket_id: MP-R2-C3-T02
feature_id: MP-R2
chunk_id: MP-R2-C3
bucket: 1 (refactor)
title: Extract the reserve → append → publish sequence into Aiur.Events.publish_journaled/3; ExecutorEvents calls it
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C3-T01]
prior_units: [U3, U8]
prior_boundaries: [BUS #10, EXE #26]
prior_features: []
prior_findings: []
size_owner: EVENTS (executor_events.ex 525 lines; must shrink); re-check at start per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C3-T02 — `publish_journaled/3`

## Identity and outcome

- **Bucket 1, MP-R2, chunk C3.** No user-visible change.
- **Value.** The "persist first, then publish with the durable id" order
  (contract rule R-3) becomes one bus primitive instead of code private to
  the Executor stream, so later producers (C6 exporter is a consumer, not a
  producer; future journaled producers such as MP-E2 Executor-requester
  events) reuse it instead of re-implementing the order.
- **Deliverable.** `Aiur.Events.JournaledPublish.publish/3` (re-exported as
  `Aiur.Events.publish_journaled/3` by the C2-T08 facade when that lands);
  `ExecutorEvents.publish/3` keeps topic validation and the GitHub-source
  rejections and delegates the rest.
- **Non-goals.** No change to `executor.*` validation
  (`validate_publish_topic/1`), GitHub rejection, the journal path, the
  JSON normalization or the return shape. `ExecutorEvents` stays in the
  executor-attention component (plan §4.1).

## Dependencies and blockers

- DESIGN-R2 §1; **C3-T01** (uses `Aiur.Events.Journal`).
- Soft: C2-T08 (facade). If C2-T08 has merged, add the `publish_journaled/3`
  delegate to `Aiur.Events` in this PR; otherwise C2-T08 adds it.
- Concurrent with C3-T03 and C2-* tickets that do not touch
  `executor_events.ex` (C2-T10 batch C touches it; merge order T02 → C2-T10
  or rebase).

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Sequence: validate topic → reject GitHub source (opt) → reject GitHub payload source → `IdGenerator.reserve_durable_id()` → `JSONSafe.normalize/1` + merge `"id"`, `"topic"`, `"source"` → `append_event/1` → `Publisher.publish_persisted(topic, payload, id, source: source)` | `src/lib/aiur/executor_events.ex:63-75` |
| Note: the journal gets the normalized map; the Exchange gets the **original** payload | `executor_events.ex:71,73` |
| `reserve_durable_id/1` fails closed with `{:error, :not_durable}` | `src/lib/aiur/events/id_generator.ex:97-108,153-175` |
| `publish_persisted/4` skips filters except executor/GitHub check; same fan-out, history marker, trace | `src/lib/aiur/events/publisher.ex:248-271` |
| `source_name/1` atom → string | `executor_events.ex:297-298` |
| Callers of `ExecutorEvents.publish/3` | `agent_control_cli.ex:388` (`aiur executor emit`); internal `publish_requested/1` `:59-61`, `publish_deferred/2` `:38-55` |
| `Aiur.JSONSafe` (kernel utility) | `src/lib/aiur/json_safe.ex:1-15` |
| Tests | `src/test/aiur/executor_events_test.exs:24-33` (publish+replay), `:61` (GitHub rejection), `:157` (renotify fresh id) |

PROPOSED: `src/lib/aiur/events/journaled_publish.ex`,
`src/test/aiur/events/journaled_publish_test.exs`.

## Chosen design

```elixir
defmodule Aiur.Events.JournaledPublish do
  @spec publish(String.t(), map(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | {:error, term()}
  # required opts: :journal (path), :journal_dir; optional :source (atom | string), :publish_opts
  def publish(topic, payload, opts) do
    journal = Keyword.fetch!(opts, :journal)
    dir = Keyword.fetch!(opts, :journal_dir)
    source = Keyword.get(opts, :source)
    with {:ok, id} <- Aiur.Events.IdGenerator.reserve_durable_id(),
         record = payload |> Aiur.JSONSafe.normalize() |> Map.merge(%{"id" => id, "topic" => topic, "source" => source_name(source)}),
         :ok <- Aiur.Events.Journal.prepare(dir, journal),
         :ok <- Aiur.Events.Journal.append(journal, record) do
      Aiur.Events.Publisher.publish_persisted(topic, payload, id, Keyword.get(opts, :publish_opts, source: source))
    end
  end
end
```

- `ExecutorEvents.publish/3` becomes the three validations then
  `JournaledPublish.publish(topic, payload, journal: journal_path(),
  journal_dir: StatePaths.dir(), source: source)`.
- `append_event/1` in ExecutorEvents is deleted (its only caller moves).
- **Invariants:** id reserved before the append; append synced before fan-out;
  a failed append returns its error and publishes nothing; a
  `:not_durable` reservation returns `{:error, :not_durable}` and writes
  nothing; journal line content identical (`"source"` string, normalized payload).

## Implementation steps

1. Add `JournaledPublish` as above (≈35 lines incl. docs).
2. Edit `ExecutorEvents.publish/3` and delete `append_event/1`; keep the
   comment at `executor_events.ex:442-447` (why `StatePaths.ensure/0` is
   not called on the hot path) next to the new call. File shrinks.
3. If C2-T08 merged: `defdelegate publish_journaled(topic, payload, opts), to: Aiur.Events.JournaledPublish, as: :publish`.
4. Add `journaled_publish.ex` to the C1-T06 member list (references only
   members, `Aiur.JSONSafe` — add it to the kernel allow-prefixes — and
   `Aiur.Events.Journal`).

## Non-happy paths

- **Counter not durable:** `{:error, :not_durable}`; no journal line, no
  publish (today identical).
- **Journal prepare/append fails** (disk full, symlink): error returned,
  nothing published; the reserved id is a permanent gap (allowed by the id
  contract, `id_generator.ex:25-33`).
- **Crash between append and publish:** the event is journaled but not
  delivered live; Executor replay from the watermark recovers it
  (`executor_listener.ex:64-69,133-142`). Unchanged.
- **Publish returns GitHub rejection:** cannot happen after
  ExecutorEvents' own rejection; for other callers the journal line exists
  but nothing fans out — documented in the moduledoc as "callers must
  validate before calling".

## Compatibility and rollout

None. Rollback: revert.

## Verification

New tests (`journaled_publish_test.exs`; they use the application's named
`IdGenerator`, because the function calls the singleton, and a temp
`journal`/`journal_dir` from `Aiur.TestSupport.tmp_root!/1`):

1. `"appends the normalized record before fan-out"` — subscribe the test
   process to `executor.test.ordered`; in the subscriber branch read the
   journal file on `{:event, %{id: id}}` and assert it already contains a
   line with `"id": id`. **Fails if the append is moved after
   `publish_persisted`.**
2. `"a failed append publishes nothing"` — `journal_dir` is a regular file
   (prepare fails with `{:not_a_directory, _}`); expect `{:error, _}` and
   `refute_receive {:event, _}`.
3. `"journal line carries the string source and the normalized payload"`
   — payload `%{at: ~U[2026-10-06 12:00:00Z], kind: :x}` with `source:
   :executor_cli` → line has `"at":"2026-10-06T12:00:00Z"`, `"kind":"x"`,
   `"source":"executor_cli"`; the live event keeps the original atom value.
4. Existing `executor_events_test.exs` all green (publish/replay, renotify,
   GitHub rejection), `agent_control_cli_test.exs` executor emit cases,
   `decision_store_test.exs` executor escalation cases.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/journaled_publish_test.exs test/aiur/executor_events_test.exs \
  test/aiur/agent_control_cli_test.exs test/aiur/decision_store_test.exs \
  test/aiur/events/bus_boundary_test.exs
```

Mutation check: swap the append and `publish_persisted` in
`journaled_publish.ex` → test 1 fails; drop the `JSONSafe.normalize/1` →
test 3 fails. Record commands and `git status --porcelain` in the PR body.

## Completion and handoff

- [ ] `executor_events.ex` shorter than before; no `IdGenerator`/`Journal`
      sequencing code left in it.
- [ ] Tests 1–3 added and mutation-checked.
- [ ] Docs: none (internal).
- Dependents: C2-T08 facade delegate; MP-E2 (Executor-requester events, if
  journaled, call this instead of hand-rolling the order); C4-T05 documents
  R-3 in `message-bus.md`.
