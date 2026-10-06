---
ticket_id: MP-E4-C7-T01
feature_id: MP-E4
chunk_id: MP-E4-C7
bucket: 2-platform
title: "Switch the Stream Deck logs transcript source onto the conversation journal"
status: blocked
blocked_by: [DESIGN-E4, DESIGN-R6, MP-R6-C1-T01, MP-E4-C2-T01, MP-E4-C1-T03]
prior_units: [U6, U8]
prior_boundaries: [SD, PRJ, WEB]
prior_features: [MP-R6 (C1 owns the neutral anchoring extraction, RC-06)]
prior_findings: [RC-06 (E4-C7 shrinks to the data-source switch); MP-R6 plan §5, §7]
size_owner: "U8 SD owner (streamdeck_logs.ex 637 lines; this ticket reduces or keeps it)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C7-T01 — Stream Deck logs read the journal

## Identity and outcome

- Bucket 2 · MP-E4 · C7 · T01 (the only ticket of C7 after RC-06).
- **User value:** the deck's logs mode keeps working after a daemon restart and
  after workspace removal, because its transcript comes from the durable journal
  instead of the per-launch IssueLog file.
- **Deliverable:** `AiurWeb.StreamdeckLogs.load/1` reads its 50-row transcript
  window through `Conversation.History` (tail page) and adapts entries to the
  feed-entry shape the deck already projects. Grouping (`Anchors.at_or_before/2`,
  moved by MP-R6-C1) and bus events (IssueLog history, 40 rows) are unchanged.
- **Non-goals:** any change to keys, paging, LIVE key, badges, `wire/1`, or the
  `streamdeck:fleet` protocol (MP-R6 §7.6); moving the deck to anchors (the deck
  keeps its emit/consumed twin identity, which anchors do not model).

## Dependencies and blockers

- **RC-06:** MP-R6-C1 must have extracted `Aiur.Conversation.Anchors.at_or_before/2`
  and made `StreamdeckLogs` delegate to it; this ticket only swaps the transcript
  source.
- DESIGN-R6 (owner confirms no deck behaviour change) and DESIGN-E4 (journal
  exists by design).
- MP-E4-C2-T01, MP-E4-C1-T03.

## Verified starting point

- `StreamdeckLogs.load/1` (`src/lib/aiur_web/streamdeck_logs.ex:628-636`):
  transcript from `AgentEventFeed.list(identifier, %{"limit" => 50})`
  (IssueLog per-launch file; `agent_event_feed.ex:76-91`), events from
  `AgentEventFeed.bus_events(identifier)` (40 rows, `:100-114`).
- Feed entry shaping: private `AgentEventFeed.entry/1` (`agent_event_feed.ex:158-200`)
  turns IssueLog maps (`"role"`, `"body"`, `"timestamp"`, `"payload"`) into deck
  rows (message / diff with `badge`, `role`, `timestamp`).
- Oracle: `src/test/aiur_web/streamdeck_logs_test.exs` (26 KB), which drives
  `project/1` with in-memory fixtures; `load/1` is not exercised there.

## Chosen design

- `AgentEventFeed.feed_entry/1` (`@doc false`, public) exposes today's private
  `entry/1` unchanged.
- PROPOSED `Aiur.Conversation.FeedAdapter.to_feed_map/1`: journal entry →
  IssueLog-shaped map: `"role"` from entry role/kind (`agent`→`"assistant"`,
  `command`→`"command"`, `tool_result`/`diff`→`"tool"`, `operator_message`→`"user"`,
  `system`→`"system"`, `reasoning`→`"reasoning"`), `"body"`, `"timestamp"` =
  `occurred_at || observed_at`, `"payload"` rebuilt from `output`/`meta`
  (`diff` → `%{"tool" => "edit", "changes" => [%{"diff" => output, "path" => title}]}`).
  `gap` entries map to a `system` row "No record …".
- `load/1`: resolve `Ref.worker/1` from the identifier's tracker identity (the
  deck channel already focuses on an identifier; resolution uses the units
  snapshot like the drawer). If the conversation has entries →
  `History.list_entries(ref, tail: true, limit: 50)` → adapter → `feed_entry/1`.
  If it has none or is `:not_found` (pre-journal ticket) → today's
  `AgentEventFeed.list/2` path, so nothing regresses during rollout.
- Bodies: the journal keeps up to 64 KiB where IssueLog kept 1,000 chars; the deck
  formats lines through `line/1`, which already cuts for key faces, so key faces
  do not change; the emulator readout can show longer text. This is the one
  visible difference and is recorded for DESIGN-R6.

## Implementation steps

1. Make `entry/1` public as `feed_entry/1` (rename only).
2. `FeedAdapter` with a table test.
3. `load/1` source switch with the fallback.
4. Parity test (below).

## Non-happy paths

- Unjoinable identity → fallback path (no journal).
- Journal unavailable → fallback path, logged once per identifier.
- Journal has entries but IssueLog also has newer ones (should not happen once
  C1-T03 tees every record): the journal wins; the fallback is only for "no
  journal".

## Compatibility and rollout

- No protocol change; the deck sidecar is untouched. Rollback: revert `load/1`.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/streamdeck_logs_test.exs test/aiur_web/streamdeck_logs_journal_test.exs \
  test/aiur/conversation/feed_adapter_test.exs test/aiur/agent_event_feed_test.exs
npm --prefix src/browser run test:streamdeck-flow
```

| Test | Expected | Fails without |
| --- | --- | --- |
| `streamdeck_logs_test.exs` (unmodified) | green | — RC-06 oracle |
| journal "same records via IssueLog and via journal give identical `project/1` keys" (bodies < 1,000 chars) | equal projections | adapter mapping |
| journal "after a simulated restart (IssueLog dir empty) the deck still shows the transcript" | rows present | the source switch (mutation: revert to `AgentEventFeed.list` fails) |
| journal "no conversation → fallback to IssueLog" | IssueLog rows | fallback |
| adapter table test per kind incl. `gap` | expected maps | each clause |
| browser `streamdeck-operator-flow` (existing) | green | — regression guard |

Manual (MP-R6 §7.5): on the `/streamdeck` emulator, open logs for a running
agent, restart the daemon (`aiurdev restart`), and confirm the logs mode still
shows the earlier transcript.

## Completion and handoff

- [ ] Oracle unmodified and green; the body-length difference noted for DESIGN-R6.
- Dependents: none.
- Docs: one line in `website/docs-app/guide/stream-deck.md` ("logs survive a
  daemon restart").
