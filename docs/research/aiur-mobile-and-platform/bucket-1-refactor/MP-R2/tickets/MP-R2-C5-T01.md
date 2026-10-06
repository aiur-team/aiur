---
ticket_id: MP-R2-C5-T01
feature_id: MP-R2
chunk_id: MP-R2-C5
bucket: 1 (Bucket-2-enabling, RC-09)
title: Aiur.Events.Catalog — code-level topic registry (class, export flag, allowlists, payload_version, owner) for every topic published today
status: blocked
blocked_by: [DESIGN-R2 §2 (KQ-R2-3 identifiers-only external feed), MP-R2-C2-T08, MP-R2-C1-T05]
prior_units: [U7, U8]
prior_boundaries: [BUS #10, signal port #11]
prior_features: [MP-R1 (component map), MP-E2, MP-E1]
prior_findings: [MP-R2 C1-T05 finding: seven alert topics outside the grammar]
size_owner: n/a (new files; each ≤ 200 lines preferred, ≤ 500 hard)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C5-T01 — `Aiur.Events.Catalog`

## Identity and outcome

- **Bucket 1 (Bucket-2-enabling, RC-09), MP-R2, chunk C5.** Inert: nothing
  reads the catalog at runtime until C6 (exporter) and C7 (catalog route).
  Scheduled just before MP-N4/MP-N5 (RC-09), not in the refactor wave.
- **User value (later):** a phone, watch or push producer can learn what
  the daemon may send it and in what shape, from one registry, instead of
  guessing from topic strings (contract §9).
- **Deliverable:** `Aiur.Events.Catalog` — a pure module holding one entry
  per topic pattern: `class`, `export?`, `refs` allowlist, `attrs`
  allowlist, `payload_version`, `owner` (feature/component). Entries for
  **every topic published at `45a290e3`** (inventory §2) plus the seven
  alert topics outside the grammar. A test fails if a published topic has
  no entry or an exported entry has no allowlist.
- **Non-goals:** no export, no envelope (C5-T02), no reserved future
  namespaces (C5-T03), no topic rename (contract §9: grammar frozen;
  DESIGN-R2 §1 second box), no change to any producer.

## Dependencies and blockers

- **DESIGN-R2 §2, KQ-R2-3** — whether the external feed is identifiers-only.
  The allowlists in this ticket are written for the plan's recommendation
  (identifiers and enums only, contract §4.2). If Kevin allows free text,
  the `attrs` lists change; the module shape does not. Status stays
  `blocked` until KQ-R2-3 is answered.
- **C2-T08** (`Aiur.Events.matches?/2` facade), **C1-T05** (placement-rule
  test; its `@known_violations` list is the source of the seven
  out-of-grammar alert topics this catalog must classify).
- Concurrent with C5-T02 (envelope consumes the entry struct; agree the
  struct in this PR first), C5-T03, C6-T01.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Topic matcher with `*`/`#` and a specificity score | `src/lib/aiur/events/topic.ex:31-32,83-84` (`Alerts` already sorts by `-specificity_score`, `src/lib/aiur/alerts.ex:100`) |
| Every alert name is published as an Exchange topic, payload keys `message, source, reason, severity, needs_attention, source_ticket_id, topic, :source` | `alerts.ex:144-152,293-313` |
| Seven alert names outside `ticket.|system.|executor.` | `decision_store.ex:684,706,742`; `executor_events.ex:435`; `github/dispatch_authorization.ex:740,755`; `orchestrator/retry_engine.ex:1115` (MP-R2-C1-T05) |
| `system.*` producers all via `Alerts.emit_system` (ledgered) | `orchestrator/issue_sync.ex:580,600,1787,2052,2285,2294`; `orchestrator/dispatcher.ex:671,698,764,789,2010-2016`; `workflow_store.ex:37,512`; `subscription_store.ex:508` |
| `ticket.*` producers and classes | inventory §2.1 (`github_firehose.ex:358`, `github_webhook.ex:244`, `github_comments_poller.ex:798`, `ls_remote_ticker.ex:183-205`, `ci_lifecycle.ex:338,361`, `command_scan.ex:316`, `ready_for_review_transitions.ex:185`, `allowed_contributors/wake.ex:22,26`, `progress_checkin/worker.ex:90,102`, `tool_executor.ex:94,123,441`, `decision_store.ex:2555-2558,4604-4608`) |
| `executor.*` producers (journaled) | `executor_events.ex:59-75`; `agent_control_cli.ex:388` |
| Identifier-only precedent with typed extractors | `src/lib/aiur/executor_wake_projection.ex:4-40` (`@actions`, `@ci_conclusions`, `@sha`, `positive_integer/1`, `valid_sha/1`, `enum/2`) |
| Executor binding defaults (topic list cross-check) | `src/lib/aiur/executor_bindings.ex:7-36` |

PROPOSED: `src/lib/aiur/events/catalog.ex`,
`src/lib/aiur/events/catalog/entries.ex` (data only),
`src/test/aiur/events/catalog_test.exs`.

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
- **Initial `export?: true` set** (identifiers-only, pending KQ-R2-3):
  `ticket.*.agent.decision.#` (refs `ticket, decision_id, decision_version`;
  attrs `slug` enum), `ticket.*.pr.opened|ready_for_review|merged`
  (refs `ticket, pr_number, head_sha`), `ticket.*.ci.passed|failed`
  (refs `ticket, pr_number, head_sha`; attrs `ci_conclusion` enum from
  `executor_wake_projection.ex:5`), `ticket.*.issue.commented` and
  `ticket.*.pr.review_comment` (refs `ticket, pr_number`; attrs
  `author_trusted?` boolean; **no** body, author login or comment id text),
  `ticket.*.agent.progress` / `.progress.checkin` (attrs `percent` integer),
  `ticket.*.agent.attention.#` and `system.#` alert topics (refs `ticket`;
  attrs `severity` enum `info|warning|error`, `needs_attention` boolean;
  **no** `message`/`reason`). Everything else `export?: false`.
  `executor.#` is **not exported** (contract §2: the Executor stream is
  private to the Executor principal). `ticket.*.agent.custom.#` is not
  exported (plan §C5 open question; resolved: free-form, agent-authored).
- **Out-of-grammar alert topics:** seven explicit entries with
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
   seven out-of-grammar topics; each entry cites its producer file in a
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
   `ci_lifecycle.ex:338`).
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
6. `"out-of-grammar alert topics are ledgered and not exported"` — the seven
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

- [ ] KQ-R2-3 answered; allowlists match the answer.
- [ ] Every published topic at the implementation head has an entry.
- [ ] Tests 1–6 added and mutation-checked.
- [ ] Docs: none yet (inert). C5-T03 adds the reserved namespaces to
      `website/docs-app/concepts/message-bus.md`; C7-T01 publishes the
      catalog route and its docs.
- Dependents: C5-T02, C5-T03, C6-T02, C7-T01; MP-E2/E1/E7 add entries for
  their topics in their own PRs (C5-T03 reserves them).
