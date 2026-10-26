---
ticket_id: MP-R2-C5-T01
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Aiur.Events.Catalog — code-level topic registry (class, export flag, allowlists, payload_version, owner) for every topic published today
status: ready
blocked_by: []
prior_units: [U7, U8]
prior_boundaries: [BUS #10, signal port #11]
prior_features: [MP-R1 (component map), MP-E2, MP-E1]
prior_findings: [MP-R2 C1-T05 finding: eight alert topics outside the grammar]
size_owner: n/a (new files; each ≤ 200 lines preferred, ≤ 500 hard); re-checked against U8 assignments.csv at 761756f39 (no existing oversized edit)
base_sha: 761756f394e6783794c777668fc1a26a540e4059
researched: 2026-10-06
---

# MP-R2-C5-T01 — `Aiur.Events.Catalog`

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C5.** Inert: nothing
  reads the catalog at runtime until C6 (exporter) and C7 (catalog route).
  Scheduled at the start of wave 4 (RC-31, amending RC-09), because
  MP-E6-C4-T05 and MP-E7-C2-T05 consume it there; C6/C7 stay in wave 5.
- **User value (later):** a phone, watch or push producer can learn what
  the daemon may send it and in what shape, from one registry, instead of
  guessing from topic strings (contract §9).
- **Deliverable:** `Aiur.Events.Catalog` — a pure module holding one entry
  per topic pattern: `class`, `export?`, `refs` allowlist, `attrs`
  allowlist, `payload_version`, `owner` (feature/component). Entries for
  **every topic published at the implementation head** (repeat inventory §2 census), including the eight
  alert topics outside the grammar. A test fails if a published topic has
  no entry or an exported entry has no allowlist.
- **Non-goals:** no export, no envelope (C5-T02), no reserved future
  namespaces (C5-T03), no topic rename (contract §9: grammar frozen;
  DESIGN-R2 §1 second box), no change to any producer.

## Dependencies and blockers

- **DESIGN-R2 §2, KQ-R2-3 — satisfied.** The identifiers-only external
  feed is approved in `EXECUTOR-APPROVALS.md` at `9ce9fdc6`; the allowlists
  below use identifiers and enums only (contract §4.2).
- **C2-T08 and C1-T05 — satisfied:** closed as #3359/#3349 and merged
  with C1–C4. The `Aiur.Events.matches?/2` facade and placement-rule test
  are present at the refreshed head; `@known_violations` supplies the eight
  out-of-grammar alert topics this catalog must classify.
- Concurrent with C5-T02 (envelope consumes the entry struct; agree the
  struct in this PR first), C5-T03, C6-T01.

## Verified starting point (761756f394e6783794c777668fc1a26a540e4059)

Refreshed 2026-10-25 from 45a290e3. Original `researched` date retained.
DESIGN-R2 approval is recorded in EXECUTOR-APPROVALS.md at 9ce9fdc6.
Size owners were checked against the U8 ledger; see [refresh audit](../../refresh/MP-R2-C4-T04.md).

| Fact | Evidence at the refreshed head |
| --- | --- |
| Public publish/subscribe boundary | `src/lib/aiur/events.ex:11-29`; matcher `src/lib/aiur/events/topic.ex` |
| Alert publication and specificity ordering | `src/lib/aiur/alerts.ex:38-50,250-278` |
| Legacy topics outside the grammar | Eight frozen exceptions in `src/test/aiur/events/placement_rule_test.exs`; includes `decision_store.append_ambiguous` (the original seven-topic census is historical) |
| Durable Executor publication | `src/lib/aiur/executor_events.ex:61-75`; `src/lib/aiur/events/journaled_publish.ex:24-35` |
| Producer census must be repeated at implementation | `git grep -n -E 'Events.publish|emit_system' <base_sha> -- src/lib`; do not treat the 2026-10-06 inventory as exhaustive |
| Identifier-only extraction and binding defaults | `src/lib/aiur/executor_wake_projection.ex`; `src/lib/aiur/executor_bindings.ex` |

PROPOSED: `src/lib/aiur/events/catalog.ex`, `catalog/entries.ex` and catalog tests. Nothing reads this catalog yet.

## Chosen design

```elixir
defmodule Aiur.Events.Catalog.Entry do
  @enforce_keys [:pattern, :class, :owner]
  defstruct pattern: nil,            # Topic pattern, e.g. "ticket.*.pr.merged"
            class: :live,            # :ephemeral | :live | :ledgered | :logged | :journaled (contract §6)
            export?: false,
            refs: [],                # allowed ref keys (atoms), contract §4.2
            attrs: [],               # {key, type} where type ∈ {:enum, values} | :integer | :boolean | :id | :sha
            payload_version: 1,
            owner: nil               # "MP-E2", "github-listeners", "commands", ...
end

defmodule Aiur.Events.Catalog do
  @spec entries() :: [Entry.t()]
  @spec lookup(String.t()) :: Entry.t()          # most specific matching entry; unknown → default
  @spec exported() :: [Entry.t()]
  @spec default() :: Entry.t()                    # %Entry{pattern: "#", class: :live, export?: false, owner: "unknown"}
end
```

- **Lookup rule:** among entries whose pattern `Aiur.Events.matches?/2` the
  topic, pick the highest `Topic.specificity_score/1`; ties are a test
  failure (catalog must be unambiguous). Unknown topics resolve to
  `default/0` — `live`, not exported (contract §9 "Unknown topics are
  `live`, not exported").
- **Initial `export?: true` set** (identifiers-only, approved KQ-R2-3):
  `ticket.*.agent.decision.#` (refs `ticket, decision_id, decision_version`;
  attrs `slug` enum), `ticket.*.pr.opened|ready_for_review|merged`
  (refs `ticket, pr_number, head_sha`), `ticket.*.ci.passed|failed`
  (refs `ticket, pr_number, head_sha`; attrs `ci_conclusion` enum from
  `executor_wake_projection.ex`), `ticket.*.issue.commented` and
  `ticket.*.pr.review_comment` (refs `ticket, pr_number`; attrs
  `author_trusted?` boolean; **no** body, author login or comment id text),
  `ticket.*.agent.progress` / `.progress.checkin` (attrs `percent` integer),
  `ticket.*.agent.attention.#` and `system.#` alert topics (refs `ticket`;
  attrs `severity` enum `info|warning|error`, `needs_attention` boolean;
  **no** `message`/`reason`). Everything else `export?: false`.
  `executor.#` is **not exported** (contract §2: the Executor stream is
  private to the Executor principal). `ticket.*.agent.custom.#` is not
  exported (plan §C5 open question; resolved: free-form, agent-authored).
- **Out-of-grammar alert topics:** eight explicit entries with
  `class: :ledgered, export?: false, owner: <emitting component>`
  (`decision_store.*` → commands, `executor_events.corrupted` →
  executor-attention, `github.dispatch_authorization.*` → github,
  `orchestrator.claim_released` → orchestration). They are classified, not
  rejected; renaming them is a separately approved change (contract §9).
  The C1-T05 ratchet still tracks them.
- **Invariant:** the catalog never changes routing or delivery; it is data.

## Implementation steps

1. Add `Entry` and `Catalog` (lookup, exported, default).
2. Add `entries.ex` with one entry per row of inventory §2.1–§2.3 and the
   eight out-of-grammar topics; each entry cites its producer file in a
   comment.
3. Add the census fixture: `test/aiur/events/catalog_test.exs` reads the
   producer topic literals with the same docs/comment-stripping scan helper
   as C1-T05 (string literals beginning `ticket.`, `system.`, `executor.`,
   or listed in C1-T05's `@known_violations`, with `#{…}` interpolation
   replaced by `*`).
4. Add `catalog.ex`/`entries.ex` to the C1-T06 member list.

## Non-happy paths

- **Unknown topic at runtime** (new producer without an entry): resolves to
  `default/0` → not exported; the census test catches it in CI first.
- **Ambiguous patterns:** test failure, never a runtime choice.
- **Privacy:** an exported entry without allowlists is a test failure
  (contract §9 "A test fails if an exported topic lacks an allowlist").
  An `attrs` type of free `:string` does not exist in the type set, so a
  free-text attr cannot be declared.

## Compatibility and rollout

No config, no runtime reader. Disabled by construction until C6. Rollback:
delete the module. Versioning: `payload_version` per entry starts at 1
(contract §9).

## Verification

`catalog_test.exs`:

1. `"every topic literal published in src/lib has a catalog entry other than the default"` —
   census over `src/lib` (step 3). **Fails** if any entry in `entries.ex`
   is removed (mutation: delete the `ticket.*.ci.passed` entry → fails naming
   `ci_lifecycle.ex`).
2. `"exported entries declare refs or attrs and only typed attrs"` — for
   each `exported/0`, `refs ++ attrs != []` and every attr type is in the
   allowed type set. **Fails** if an entry is changed to `export?: true`
   with empty lists.
3. `"lookup picks the most specific entry"` — `lookup("ticket.42.agent.decision.answered")`
   returns the decision entry, not `ticket.*.agent.#`; `lookup("foo.bar")`
   returns `default/0` (class `:live`, not exported).
4. `"no two entries tie on specificity for a topic"` — for every census
   topic, at most one top-scoring entry.
5. `"executor and custom agent topics are never exported"` —
   `lookup("executor.decision.requested").export? == false`,
   `lookup("ticket.1.agent.custom.x").export? == false`. Guards the privacy
   decision; fails if either is flipped.
6. `"out-of-grammar alert topics are ledgered and not exported"` — the eight
   names resolve to their explicit entries.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/catalog_test.exs test/aiur/events/placement_rule_test.exs \
  test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check (clean worktree, `git status --porcelain` shows only the
reverted hunk): remove one entry → test 1 fails; set
`executor.#` `export?: true` → test 5 fails; restore → all pass.

## Completion and handoff

- [x] KQ-R2-3 answered: identifiers-only (`EXECUTOR-APPROVALS.md`, `9ce9fdc6`).
- [ ] Allowlists match the approved answer.
- [ ] Every published topic at the implementation head has an entry.
- [ ] Tests 1–6 added and mutation-checked.
- [ ] Docs: none yet (inert). C5-T03 adds the reserved namespaces to
      `website/docs-app/concepts/message-bus.md`; C7-T01 publishes the
      catalog route and its docs.
- Dependents: C5-T02, C5-T03, C6-T02, C7-T01; MP-E2/E1/E7 add entries for
  their topics in their own PRs (C5-T03 reserves them).
