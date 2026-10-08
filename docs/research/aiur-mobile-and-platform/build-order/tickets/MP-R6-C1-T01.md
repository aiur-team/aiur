---
ticket_id: MP-R6-C1-T01
feature_id: MP-R6
chunk_id: MP-R6-C1
bucket: 1-refactor
title: Extract the device-neutral event-to-transcript anchor rule into Aiur.Conversation.Anchors (behaviour-preserving)
status: blocked
blocked_by: [DESIGN-R6]
prior_units: [U7, U8]
prior_boundaries: ["SD #35", "PRJ #28", "WEB #34"]
prior_features: [ui-15, ui-16]
prior_findings: []
size_owner: "DECK_WEB (streamdeck_logs.ex 637 lines): this ticket shrinks it"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R6-C1-T01 — Extract the neutral anchor rule

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R6 / C1.
- **User value:** none visible. The deck's logs keys, paging and transcript
  groups are identical. The one reusable event→transcript rule in the codebase
  stops living in a Stream Deck module, so MP-E4 (dashboard conversations) and
  MP-N6 (open-in-context) extend it instead of copying it.
- **RC-06 (binding):** this ticket **extracts** the rule without changing
  behaviour. MP-E4-C3 **extends** the extracted module with exact anchors,
  stable entry IDs and durable journal positions (RC-07: the E4 journal
  position is the address). MP-E4-C7 then switches the deck onto the E4
  journal.
- **Deliverable:**
  1. A PROPOSED module `Aiur.Conversation.Anchors` (`src/lib/aiur/conversation/anchors.ex`)
     with three parts, all moved verbatim from
     `AiurWeb.StreamdeckLogs`:
     - the event identity;
     - the origin synthesis;
     - the "last event at or before" attach rule, with timestamp parsing.
  2. `Aiur.AgentEventFeed.directions/0`, the badge vocabulary, defined where the
     badges are produced.
  3. `StreamdeckLogs` delegates to both. It keeps paging, LIVE, the readout
     window, `line/1` and `wire/1`, and stops reading the visual contract.
  4. Direct unit tests for the rule.
- **Non-goals:**
  - stable anchor positions. RQ1 (answered below) shows that entries have no
    stable ID; E4 adds them.
  - Changing the `start` row index the deck uses.
  - `load/1` data sources and limits. E4-C7 owns the data-source swap.
  - Executor conversations.

## Dependencies and blockers

- **Blocked by:** DESIGN-R6. The plan's "E4 contract must accept § 5" blocker
  is **resolved by RC-06/RC-07**: the contract (`contracts/conversations-transcripts-anchors.md`
  §10) names this rule as the `observed` precision level, and the module name
  follows the E4 plan (`Conversation.Anchors`, plan § 3). CR-R6-1 asks the
  coordinator to retire E4-C3-T01, which duplicated this extraction.
- **MP-R1 placement:** not a blocker. The module lands in core now. MP-R1-C8-T03
  (the conversations component) moves it later. That is a path change only.
- **May run concurrently with:** MP-R6-C2-T01, which touches
  `streamdeck_key_face_contract.ex` and also the `@expected_badges` line. Merge
  this ticket first, or rebase C2 on it. Also MP-R5-C1-T03 (different files).

## Verified starting point (base `45a290e3`)

`src/lib/aiur_web/streamdeck_logs.ex` (637 lines):

- `project/1` (`:71-113`): `oldest_first` → `entry/1` → `bus_event/1` →
  `with_origin/2` → `assign_entries/2` → index → `flatten/1` → keys.
- **Identity:** `bus_event/1` (`:267-281`):
  `id: {:bus, value(row, :kind, "emit"), value(row, :id)}`. The comment at
  `:269-274` explains the emit/consumed twins.
- **Origin:** `with_origin/2` (`:287-297`) adds `%{id: :origin, badge: "INFO",
  label: "Ticket opened", body: "Ticket opened", timestamp: earliest(...)}`.
  `earliest/2` (`:299-304`) is the minimum of the stringified non-nil
  timestamps of both feeds.
- **Attach rule:** `assign_entries/2` (`:309-317`) walks the events
  newest-first with `Enum.split_with(remaining, &at_or_after?(&1, event.timestamp))`.
  - The leftover entries go to the origin (`attach_leftover/2`, `:319-320`).
  - `at_or_after?/2` (`:327-338`):
    - a nil boundary claims nothing;
    - a nil entry timestamp is not matched;
    - otherwise it compares parsed `DateTime`s with `!= :lt`, falling back to a
      lexical comparison.
  - `instant/1` (`:343-351`) parses ISO 8601.
- **Badge vocabulary:**
  - `@directions Map.keys(AiurWeb.StreamdeckKeyFaceContract.direction_badges())`
    (`:64`) is used only by `direction/1` (`:534-535`). This is the module's
    only dependency on the visual contract.
  - The badges are produced by `Aiur.AgentEventFeed.badge/1` (`agent_event_feed.ex:142-156`)
    and `badge_for_kind/1` (`:278-281`). The literal set
    `~w(EMIT CONSUME AGENT SYSTEM INFO)` is also hard-coded in
    `streamdeck_key_face_contract.ex:14` (`@expected_badges`).
- **Callers:**
  - `StreamdeckLive` (`live/streamdeck_live.ex:112,181,312,500,1415-1427`);
  - `StreamdeckChannel` (`streamdeck_channel.ex:497`, `load |> wire`);
  - `StreamdeckStrip` (`:100-108`, for `row_kind`, `glyph`, `tool_display`,
    which stay).
- **Oracle:** `src/test/aiur_web/streamdeck_logs_test.exs`. It uses
  `StreamdeckKeyFaceContract.direction_badge!/1` only for colour lookup
  (`:125`).
- **Plan RQ1 answered: there is no stable per-entry ID.**
  - `AgentEventFeed.list/2` entries carry the provider `msg_id`/`turn_id`,
    which may be nil (`agent_event_feed.ex:196-197,218-219`).
  - The daemon sequence is a per-BEAM `:erlang.unique_integer`
    (`agent_events.ex:129`).
  - `agent.ndjson` records have no ID (contract §1).
  - So R6 keeps row-index `start`, and stable positions are E4's journal `pos`
    (RC-07).

## Chosen design

Note the namespace: `Aiur.Conversations` (plural) already exists. It is the
tmux conversation-pane facade (`src/lib/aiur/conversations.ex:1-19`).
`Aiur.Conversation.Anchors` (singular) is the E4 plan's namespace for the
journal family (`Conversation.Journal`, `History`, `Anchors`). CR-R6-2 asks E4
to confirm the name; if E4 renames it, this ticket uses E4's name.

```elixir
defmodule Aiur.Conversation.Anchors do
  @moduledoc "Event→transcript anchoring, `observed` precision (contracts/conversations-transcripts-anchors.md §10)."
  @origin_id :origin

  @spec event_identity(String.t() | nil, term()) :: {:bus, String.t(), term()}
  def event_identity(kind, id), do: {:bus, kind || "emit", id}

  @spec origin_id() :: :origin
  def origin_id, do: @origin_id

  # Returns [origin | events]; origin is %{id: :origin, timestamp: earliest}. Presentation adds its own fields.
  @spec with_origin([%{timestamp: term()}], [%{timestamp: term()}]) :: [map()]
  def with_origin(events, entries)

  # events oldest-first, origin first. Each event gets :entries: every entry at or after its
  # timestamp and before the next event's. A nil event timestamp claims nothing. Unclaimed
  # entries are prepended to the origin's.
  @spec at_or_before([map()], [map()]) :: [map()]
  def at_or_before(events, entries)
end
```

- The function bodies are the existing private functions **verbatim**:
  - `earliest/2` → inside `with_origin/2`;
  - `assign_entries/2` → `at_or_before/2`;
  - `attach_leftover/2`, `at_or_after?/2` and `instant/1` become private
    helpers.
- `at_or_before/2` is E4-C3-T01's function name (E4 chunks), so E4 extends this
  module and does not add a parallel one.
- `StreamdeckLogs.with_origin/2` becomes:

  ```elixir
  Anchors.with_origin(events, entries) |> merge the deck fields into the origin
  ```

  The deck fields are `badge: "INFO", label: "Ticket opened",
  body: "Ticket opened"`.
- `bus_event/1` uses `Anchors.event_identity(value(row, :kind), value(row, :id))`.
  The old code defaults the kind to `"emit"` with `value(row, :kind, "emit")`;
  `event_identity/2` keeps that default, so a nil kind still becomes `"emit"`.
- **Badge vocabulary:** add `@spec directions() :: [String.t()]` to
  `Aiur.AgentEventFeed`, returning `~w(EMIT CONSUME AGENT SYSTEM INFO)`. Then:
  - `StreamdeckLogs` uses `@directions Aiur.AgentEventFeed.directions()`;
  - `StreamdeckKeyFaceContract` sets
    `@expected_badges Aiur.AgentEventFeed.directions()`. Its compile-time
    exhaustiveness check (`:16-25`) then asserts that the visual contract
    agrees with the producer.
  - After this ticket, `git grep -n StreamdeckKeyFaceContract -- src/lib/aiur_web/streamdeck_logs.ex`
    is empty.

## Implementation steps

1. Add `src/lib/aiur/conversation/anchors.ex` with the moved bodies, and
   `AgentEventFeed.directions/0`.
2. Edit `streamdeck_logs.ex`: delete the moved private functions, delegate,
   and swap `@directions`. Expect about −60 lines.
3. Edit `streamdeck_key_face_contract.ex:14`.
4. Add the PROPOSED `src/test/aiur/conversation/anchors_test.exs` and a test in
   the existing `src/test/aiur/agent_event_feed_test.exs`.
5. Run the oracle **unmodified**.

## Non-happy paths (all must be unchanged)

| Case | Behaviour |
| --- | --- |
| No bus events | Only the origin, holding every entry. |
| An event with a nil timestamp | Claims nothing (the `:322-326` comment). |
| An entry with a nil timestamp | Falls to the origin. |
| Mixed precision (`10:00:00Z` versus `10:00:00.5Z`) | Compared as parsed instants, not as strings. |
| Unparseable timestamps | Lexical fallback. |
| Emit and consumed twins with the same ID | Distinct identities. |
| Unreadable transcript | `load/1` falls back to `[]` (`:631-633`, untouched). |

## Compatibility and rollout

- Wire DTOs, deck events and LiveView output are unchanged.
- No config. Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/anchors_test.exs test/aiur/agent_event_feed_test.exs test/aiur_web/streamdeck_logs_test.exs \
  test/aiur_web/streamdeck_key_face_contract_test.exs test/aiur_web/live/streamdeck_live_test.exs \
  test/aiur_web/streamdeck_channel_test.exs test/aiur_web/streamdeck_strip_test.exs
env -C <worktree>/src mise exec -- mix compile --warnings-as-errors
```

- **Oracle:** `streamdeck_logs_test.exs` passes with **zero edits**. Check
  with `git diff --quiet -- src/test/aiur_web/streamdeck_logs_test.exs`.
- **New tests** in `anchors_test.exs`:

  | Test | Expected |
  | --- | --- |
  | "an entry exactly at an event's timestamp belongs to that event" | Entry with T, events [origin, e1@T]: e1 has it. |
  | "an event without a timestamp claims nothing" | [origin@T0, e1@nil, e2@T2] with an entry at T3: e2 has it; e1 is empty. |
  | "an entry without a timestamp falls to the origin" | The origin's entries include it. |
  | "emit and consumed twins have distinct identities" | `event_identity("emit", 7) != event_identity("consumed", 7)` |
  | "instants are compared parsed, not lexically" | Event at `"2026-01-01T10:00:00Z"`, entry at `"2026-01-01T10:00:00.5Z"`: the event claims the entry. |
  | "with no events, the origin holds every entry" | Single group. |
  | "badge vocabulary covers every produced badge" (`agent_event_feed_test.exs`) | `badge/1` over all roles and `badge_for_kind/1` over `~w(emit consumed emit_alert self other)` are each in `directions()`. |

- **Mutation checks** (plan § 7.2). The new tests are the guard. The extraction
  itself is proven by the unchanged oracle.
  - **A:** in `Anchors`, change `DateTime.compare(at, edge) != :lt` to
    `== :gt`. The "exactly at" test fails.
  - **B:** change `event_identity/2` to `{:bus, id}`. The twin test fails.
  - **C:** change `at_or_after?(_entry, nil)` to `true`. The "claims nothing"
    test fails.
  - **D:** drop `"SYSTEM"` from `directions/0`. The vocabulary test fails, and
    `StreamdeckKeyFaceContract` raises at compile time.
- **Manual:** open the `/streamdeck` emulator in the dashboard on a running
  instance, switch to Logs on an agent with events, and confirm that keys and
  readout match the pre-change capture. That is the DESIGN-R6 "no change in
  the emulator" item; record which agent was checked.

## Completion and handoff

- [ ] The oracle test is unmodified and green; mutations A–D go red.
- [ ] `streamdeck_logs.ex` no longer references `StreamdeckKeyFaceContract`,
  and it is shorter than 637 lines.
- [ ] Docs: none (internal). C3-T01 documents the classification.
- **Dependents:**
  - MP-E4-C3, which extends `Aiur.Conversation.Anchors` with `exact`/`causal`
    and journal `pos`;
  - MP-E4-C7, which moves the deck onto E4 `History`;
  - MP-R6-C2-T01, which relies on `directions/0` living outside the visual
    contract;
  - MP-R1-C8-T03, which moves the module into the conversations component.
