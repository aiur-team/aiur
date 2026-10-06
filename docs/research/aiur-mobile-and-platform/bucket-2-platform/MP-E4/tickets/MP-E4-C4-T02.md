---
ticket_id: MP-E4-C4-T02
feature_id: MP-E4
chunk_id: MP-E4-C4
bucket: 2-platform
title: "Command ↔ conversation links: decision index, 'Open in conversation' on the Command detail"
status: blocked
blocked_by: [DESIGN-E4, DESIGN-E2, MP-E4-C3-T02, MP-E4-C5-T01]
prior_units: [U8]
prior_boundaries: [DEC, WEB, PRJ]
prior_features: [MP-E2 (Command contract: Decision.source)]
prior_findings: [plan acceptance 5; contract conversations-transcripts-anchors §10 (decision_source)]
size_owner: "U8 WEB owner (decision_detail.ex 164 lines; no dashboard_live.ex growth)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C4-T02 — Command ↔ conversation links

## Identity and outcome

- Bucket 2 · MP-E4 · C4 · T02.
- **User value:** from a Command, one click opens the requester's conversation
  at the moment it asked (plan acceptance 5); from the conversation, the
  Command chip opens the Command.
- **Deliverable:** a durable `decision_id → {conversation_id, pos}` index kept
  by the resolver; `History.command_anchor/1`; an "Open in conversation" link
  in `DecisionDetail`; Command chips data for the conversation view (rendered
  in C5-T03).
- **Non-goals:** answering inside the conversation (C6-T02); Executor-originated
  Commands' link target (MP-E3 consumes the same index once the Executor
  conversation exists).

## Dependencies and blockers

- DESIGN-E4 (link placement in the conversation), DESIGN-E2 (Command detail
  layout is MP-E2's surface: the link placement there needs its approval).
- MP-E4-C3-T02 (anchors with `subject_ref.decision_id`), MP-E4-C5-T01 (route
  `/conversations/:conversation_id?pos=`).
- Concurrent with: C4-T01.

## Verified starting point

- `Decision.source` = `%{agent_id, session_id, event_id}`; `event_id` is the
  tool invocation id (`src/lib/aiur/agent_runner/tool_executor.ex:845-850`;
  `decision.ex:17,113-117`).
- Lifecycle topic: `ticket.<identifier>.agent.decision.requested`
  (`decision_store.ex:4604`).
- Detail component: `AiurWeb.OperatorControlCenter.DecisionDetail.decision_detail/1`
  (`components/operator_control_center/decision_detail.ex:12-40`, attrs
  `decision`, `history`, `action_state`, `writable`, `filter`, `query`),
  rendered by `DashboardLive` for `/commands/:decision_id` (`router.ex:143`).

## Chosen design

- **Index:** the resolver appends `{v, decision_id, conversation_id, pos,
  anchor_id, precision}` to `<conversation_state_dir>/decision-index.jsonl`
  whenever it writes a `command_requested` anchor (the resolver is the only
  writer; one fsynced line per anchor, via `DecisionLog.append/2`). On boot an
  ETS cache is filled from the file. A stronger anchor later appends a new line;
  readers take the strongest.
- **Read:** PROPOSED `History.command_anchor(decision_id) :: {:ok, %{conversation_id,
  pos, precision}} | :none`.
- **Detail link:** `DecisionDetail` gets an optional attr
  `conversation_link` (`nil | %{href, precision}`); `DashboardLive` computes it
  once per detail render with `History.command_anchor/1` and passes it. The
  link renders `"/conversations/#{id}?pos=#{pos}"`. Copy per DESIGN-E4
  (proposed: "Open in conversation"; when `precision` is `observed`:
  "Open in conversation (approximate)").
- **No anchor** (event before the journal existed, unjoinable ticket) → the
  link is absent and a muted "Conversation position unknown" is shown, never a
  link to the conversation top.
- **Chips:** the conversation view reads `command_requested` /
  `command_resolved` anchors from `list_anchors/2` and links each to
  `/commands/:decision_id` (render in C5-T03).

## Implementation steps

1. Resolver: index append + ETS cache (≤ 40 lines in `anchor_resolver.ex`).
2. `History.command_anchor/1`.
3. `DecisionDetail` attr + markup (≤ 20 lines); `DashboardLive` passes the attr
   (≤ 5 lines; U8 owner: no other growth).
4. Docs: one sentence in `website/docs-app/concepts/commands.md` ("A Command
   links to the moment its agent asked").

## Non-happy paths

- Command from an agent whose conversation was never journaled (pre-journal
  history) → no link, "position unknown".
- Command superseded or answered → the link still points at the request; the
  resolved anchor is a second chip.
- Two Commands from one tool call cannot occur (one invocation id per call).
- Read-only dashboard → the link shows (reading is allowed).

## Compatibility and rollout

- Additive attr with default `nil`; existing Command detail tests unchanged.
  Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/conversation/decision_index_test.exs \
  test/aiur_web/components/operator_control_center/decision_detail_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "command_requested anchor writes one index line; reboot reads it back" | `command_anchor/1` returns pos after cache rebuild | index append / boot load |
| "stronger anchor later wins" | exact over observed | strongest selection |
| "detail shows link with pos" | `href` contains `?pos=` | attr markup |
| "detail without anchor shows position unknown, no link" | text present, no `<a>` to `/conversations` | the nil branch (mutation: link to `?pos=1` fails) |
| "approximate copy for observed precision" | "(approximate)" | precision branch |

Browser (with C5-T03): `env -C src/browser node scripts/run-browser-tests.mjs
tests/conversation-jump.browser.spec.mjs` includes "from a Command, Open in
conversation highlights the request entry".

## Completion and handoff

- [ ] Index, read, link merged; `concepts/commands.md` sentence in the same PR.
- Dependents: MP-E4-C6-T02, MP-N6 (phone "open in context"), MP-E3 Executor
  Commands.
