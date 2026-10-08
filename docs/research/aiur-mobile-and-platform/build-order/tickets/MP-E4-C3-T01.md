---
ticket_id: MP-E4-C3-T01
feature_id: MP-E4
chunk_id: MP-E4-C3
bucket: 2-platform
title: "Extend Aiur.Conversation.Anchors with journal positions and the precision ladder (pure)"
status: blocked
blocked_by: [DESIGN-E4, MP-R6-C1-T01, MP-E4-C1-T01]
prior_units: [U6]
prior_boundaries: [PRJ, SD]
prior_features: [MP-R6 (C1 extracts the neutral module, RC-06)]
prior_findings: [RC-06, RC-07; contract conversations-transcripts-anchors §10]
size_owner: n/a (module created by MP-R6-C1; this adds functions)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C3-T01 — Positions and precision ladder in the neutral anchor module

## Identity and outcome

- Bucket 2 · MP-E4 · C3 · T01.
- **User value:** an event (progress, push, PR, merge, Command) points to the
  exact place in a conversation when that can be proven, and says
  "approximately here" when it cannot (plan acceptance 3, 4).
- **Deliverable:** pure functions in `Aiur.Conversation.Anchors` (created
  by MP-R6-C1) that compute an anchor record for one event against journal
  entries: `position/3`, `exact/2`, `decision_source/2`, `strongest/1`,
  `anchor_id/1`. No process, no I/O (C3-T02 runs them).
- **Non-goals:** changing `at_or_before/2` (the deck rule MP-R6-C1 moved verbatim);
  causal rules (C3-T03).

## Dependencies and blockers

- **RC-06:** MP-R6-C1 must have extracted the module first; this ticket adds to
  it and must leave `at_or_before/2` and its tests untouched.
- DESIGN-E4 decision 7 (whether precision is shown) does not change the data,
  but the ticket waits on the gate per MP-REQ2.
- MP-E4-C1-T01 (entry shape with `pos`, `observed_at`, `refs.tool_call_id`).
- Concurrent with: C2-T01, C3-T03 (separate functions in the same module;
  merge order T01 then T03).

## Verified starting point

- Deck rule at `45a290e3` (to be moved by R6-C1): `assign_entries/2`
  (`src/lib/aiur_web/streamdeck_logs.ex:306-320`), nil-timestamp guard
  `at_or_after?/2` (`:322-341`), `instant/1` parsing (`:343-351`), identity
  `{:bus, kind, id}` (`:267-281`), origin (`:287-305`).
- Exact-match inputs (contract §10): bus event
  `ticket_observation.provenance.source_event_id` (`agent_runner/tool_executor.ex:875-882`,
  `ticket_observation.ex:181-198`), and `Decision.source.event_id`
  (`tool_executor.ex:845-850`).
- `TicketObservation` has `observed_at` and `occurred_at`
  (`ticket_observation.ex:30-60`).

## Chosen design

```elixir
@type entry :: %{pos: pos_integer(), observed_at: DateTime.t(), session_seq: pos_integer(),
                 kind: String.t(), refs: map()}
@type session :: %{session_seq: pos_integer(), first_pos: pos_integer(), last_pos: pos_integer() | nil,
                   started_at: DateTime.t(), ended_at: DateTime.t() | nil}
@type event :: %{event_id: pos_integer(), kind: String.t(), topic: String.t(),
                 observed_at: DateTime.t() | nil, occurred_at: DateTime.t() | nil,
                 source_tool_call_id: String.t() | nil, decision_tool_call_id: String.t() | nil}

@spec exact(event(), [entry()]) :: {:ok, anchor()} | :none
@spec position(event(), [entry()], [session()]) :: {:ok, anchor()}   # observed or unanchored
@spec strongest([anchor()]) :: [anchor()]                               # one per {event_id, kind, conversation_id}
@spec anchor_id(anchor()) :: String.t()
```

- `exact/2`: find the entry with `refs.tool_call_id == event.source_tool_call_id`
  (or `decision_tool_call_id` for `command_requested`, `method:
  "decision_source"`); `placement: "at"`, `precision: "exact"`.
- `position/3` (`observed`): among entries whose `observed_at` is ≤ the event's
  `observed_at`, take the greatest `pos`; require that a session covering the
  event time exists (`started_at ≤ t ≤ ended_at || open`) and that no `gap`
  entry spans `t`; `placement: "after"`. Otherwise `unanchored`, `pos: nil`.
  A nil `observed_at` → `unanchored` (mirrors "an event with no usable
  timestamp claims nothing", `streamdeck_logs.ex:322-330`).
- **Tie rule:** entries with `observed_at` equal to the event's are before the
  event (`<=`). `at_or_before/2` keeps the deck's `>=` membership; the difference is
  documented in the moduledoc and pinned by test 5.
- `anchor_id/1`: `"anc_" <> base32(sha256(event_id, kind, conversation_id,
  precision))[0..25]` — precision included so a stronger anchor is a new line.
- Ladder order for `strongest/1`: `exact > causal > observed > unanchored`.
- Callers pass a bounded window of entries (C3-T02 reads `±200` entries around
  the time); the functions are O(n) in the window.

## Implementation steps

1. Add the types and four functions with `@spec`s and a moduledoc section
   "Positions (MP-E4)" that cites contract §10.
2. Add `anchor/…` record builder producing the contract §10 JSON map (`v: 1`,
   `event`, `conversation_id`, `pos`, `placement`, `precision`, `method`,
   `label`, `subject_ref`).
3. Unit tests (below). Do not edit `at_or_before/2` or its tests.

## Non-happy paths

- **Clock:** both sides are daemon `observed_at` (entry from the journal
  writer, event from `TicketObservation.observed_at`), so provider clock skew
  does not move anchors (contract §11).
- **Event inside a gap** → `unanchored`, never the entry before the gap.
- **Event before the first session** → `unanchored` (plan acceptance 4).
- **Two events at one position** → two anchors with the same `pos`; readers
  order them by `event_id` (plan §6).
- **Tool-call id collision across conversations** cannot occur: the window is
  one conversation's entries.

## Compatibility and rollout

- Pure additions to a module R6-C1 created. `streamdeck_logs_test.exs` must
  pass unmodified (RC-06 oracle). Rollback: revert.

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/anchors_position_test.exs \
  test/aiur_web/streamdeck_logs_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| 1 "exact beats observed when the tool call entry exists" | `precision: exact`, `pos` of the tool entry | `exact/2` match on `refs.tool_call_id` |
| 2 "command_requested anchors via decision source" | `method: decision_source` | the `decision_tool_call_id` branch |
| 3 "observed: last entry at or before" | `pos` of that entry, `placement: after` | `position/3` comparison (mutation: `<=` → `<` fails on the equal-time fixture) |
| 4 "event before the first session is unanchored" | `pos: nil`, `unanchored` | session-coverage check (mutation: replace with "nearest entry" fails) |
| 5 "tie: equal observed_at entry is before the event; at_or_before/2 unchanged" | position = the tied entry; `at_or_before/2` still puts the tied entry in the event's group | tie rule documentation pin |
| 6 "event during a gap is unanchored" | `unanchored` | gap check |
| 7 "nil observed_at is unanchored" | `unanchored` | nil guard |
| 8 "anchor_id stable across runs and differs by precision" | equal for same input; differs exact vs observed | `anchor_id/1` inputs |
| 9 "strongest keeps exact over observed for one event" | one anchor | ladder order |
| streamdeck_logs_test (unchanged) | green | — RC-06 oracle |

## Completion and handoff

- [ ] Tests green; `streamdeck_logs_test.exs` unmodified and green.
- [ ] Moduledoc cites contract §10.
- Dependents: MP-E4-C3-T02, MP-E4-C3-T03, MP-E4-C7-T01.
- Docs: none (the concepts page in C8-T02 explains precision).
