---
ticket_id: MP-E4-C6-T01
feature_id: MP-E4
chunk_id: MP-E4-C6
bucket: 2-platform
title: "Composer through the listener-mode send path, with a delivery overlay reconciled against the journal"
status: blocked
blocked_by: [DESIGN-E4, DESIGN-E7, MP-E7-C3-T03, MP-E7-C3-T04, MP-E4-C5-T01]
prior_units: [U8]
prior_boundaries: [WEB, RUN]
prior_features: [MP-E7 (listener mode; RC-05)]
prior_findings: [RC-05; D15; listener-mode contract §7 receipts; contract conversations-transcripts-anchors §9]
size_owner: "U8 WEB owner (new component; no dashboard_live.ex growth)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C6-T01 — Composer and delivery overlay

## Identity and outcome

- Bucket 2 · MP-E4 · C6 · T01.
- **User value:** send a message to the agent from its full conversation and see
  exactly what became of it — accepted, queued for the next boundary, handed to
  the agent, failed, or unknown — never a false "delivered".
- **Deliverable:** `AiurWeb.Conversation.Composer` (component) and
  `AiurWeb.Conversation.DeliveryOverlay` (pure reconciliation) in
  `ConversationLive`, sending through the listener-mode path that MP-E7-C3
  provides, with the effective mode shown read-only. The overlay module is
  reused by MP-E3-C5-T01 for the Executor.
- **Non-goals:** the mode selector (MP-E7-C7, DESIGN-E7); pause, resume,
  interrupt, spawn (D15: controls stay where they are); Executor delivery.

## Dependencies and blockers

- **RC-05:** this write chunk depends on **MP-E7-C3** (every send routed through
  the mode; E7-C3 ships behind a flag that keeps today's behaviour until
  DESIGN-E7 is approved). There is no interim `AgentChat`-only step: the plan's
  "step 1" is dropped (plan §5 updated).
- DESIGN-E4 (composer copy, delivery states), DESIGN-E7 (mode indicator copy).
- MP-E4-C5-T01. Concurrent with: C6-T02.

## Verified starting point

- Send API at `45a290e3`: `Aiur.AgentChat.send/3` returns `{:ok, request_id}` or
  `{:error, {:outcome_unknown, info}}` / `{:error, reason}`; idempotent by
  `message_id` (`src/lib/aiur/agent_chat.ex:12-55`); default
  `delivery_policy: :interrupt` (`:27`) — the default MP-E7-C3 replaces with the
  effective mode.
- Receipt query: `AgentChat.delivery_status/2` → `:pending | :delivered |
  :consumed` (`agent_chat.ex:68-80`); MP-E7-C3-T4 maps these onto contract §7
  receipts (`accepted`, `held_async`, `harness_queued`, `in_context`, `read`,
  `failed`, `outcome_unknown`).
- Today's drawer send keeps one `message_id` per user action and keeps the draft
  on an unknown outcome (`dashboard_live.ex:2655-2693`, #2717). Reuse that rule.
- The journal writes the delivered message as an `operator_message` entry with
  `refs.delivery_id == request_id` (C1-T03).
- Writable gate: `Endpoint.config(:dashboard_writable) == true`
  (`dashboard_live.ex:1129`); router write scope requires `:api_write` and
  `:require_writable` for HTTP sends (`router.ex:153-164`).

## Chosen design

- **Send:** `handle_event("send", %{"text" => t})` in `ConversationLive`, only
  when writable; builds the client request id with the #2717 rule; calls
  `Aiur.Listener.send(identity, text, client_request_id)` (MP-E7-C3-T03, the
  contract §9 send API; in wave 3 it takes the worker identifier or
  `TrackerIdentity`, MP-E7 CR-E7-4). It routes through the effective mode once
  E7's flag leaves `:legacy`, and behaves like today's `AgentChat.send/3`
  before that.
- **Overlay:** `DeliveryOverlay` keeps `%{delivery_id => %{text, state,
  updated_at}}`. Inputs: the send result (mapped by
  `Aiur.Listener.receipt_for_send_result/1`), receipt polling with
  `Aiur.Listener.receipt/2` (MP-E7-C3-T04; every 2 s while non-terminal, max
  10 min), and `{:entries_appended}` from the journal. E7-C3-T04 reports
  `harness_queued` where it cannot see `in_context`; the journal entry is what
  clears the overlay. Pending messages do not survive a daemon restart
  (`AgentQueueStore` is in memory, MP-E7 CR-E7-6), so a non-terminal item whose
  receipt query errors becomes `unknown`. Transitions:

| From | Event | To |
| --- | --- | --- |
| — | `{:ok, id}` | `accepted` |
| `accepted` | receipt `harness_queued` | `queued` ("queued for next boundary" when mode is `sync`) |
| any non-terminal | journal `operator_message` with `refs.delivery_id == id` | **removed** (the entry is the record) |
| any | receipt `failed` | `failed` (terminal, reason shown, draft restored) |
| — | `{:error, {:outcome_unknown, _}}` | `unknown` (terminal until retry; never "delivered") |
| `accepted`/`queued` | 10 min without a journal entry | `unknown` with "check the agent" copy |

- **Effective mode** (read-only chip): from the control capability field MP-E7-C2
  adds (`requested`, `effective`, `effective_reason`); unknown → "mode
  unknown", never a guessed mode.
- **Read-only dashboard:** composer not rendered; a one-line notice instead.

## Implementation steps

1. `DeliveryOverlay` pure module + tests.
2. `Composer` component (text area, send, state list) styled per DESIGN-E4.
3. `ConversationLive` events, receipt polling (`Process.send_after/3`), journal
   reconciliation in the existing `{:entries_appended}` handler.
4. Docs: `guide/gui.md` "Conversations" section gains "Send a message" with the
   delivery states (AGENTS.md: changed documented behaviour of the composer).

## Non-happy paths

- **Timeout:** `outcome_unknown` keeps the draft and the id; pressing Send again
  with the same text retries idempotently (#2717).
- **Agent not running:** E7/AgentChat returns an error → `failed` with reason.
- **Async mode:** receipt `held_async` → state "saved; the agent reads it when it
  chooses" (copy per DESIGN-E7); no timeout to `unknown`.
- **Two tabs:** each tab's overlay is local; the journal entry clears both.
- **Socket reconnect:** overlay is lost; terminal truth is the journal (entry
  present or not). Acceptable and documented.

## Compatibility and rollout

- With E7-C3's flag off, behaviour equals today's drawer send (same API, same
  default). Rollback: remove the composer; the drawer still sends.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/conversation/delivery_overlay_test.exs \
  test/aiur_web/live/conversation_composer_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| overlay "journal entry with delivery_id removes the overlay item" | item gone | reconciliation |
| overlay "outcome_unknown never becomes delivered" | state `unknown` | the unknown clause (mutation: map to `delivered`/removed fails) |
| overlay "10 min without entry → unknown" | `unknown` | timeout rule |
| composer "read-only renders no composer" | no form | writable gate |
| composer "retry after unknown reuses the message id" | send fun called twice with same id | #2717 rule |
| composer "sends through Aiur.Listener.send/3" (send fun injected through Endpoint config, as `:agent_chat_send_fun` is today, `dashboard_live.ex:2689-2693`) | listener fun called; `AgentChat.send/3` not called directly | — guards RC-05 (fails if the composer bypasses the listener path) |
| composer "effective mode unknown renders 'mode unknown'" | text | nil branch |

Manual (AGENTS.md "Manual testing"): with `scripts/aiurdev --test`, open a running
agent's `/conversations/<id>`, send a message mid-turn, observe `queued` then the
operator entry appearing; also send through the TUI chat pane and confirm the
same journal entry appears in the view.

## Completion and handoff

- [ ] Overlay reused by MP-E3-C5-T01 (no copy).
- [ ] `guide/gui.md` updated in the same PR.
- Dependents: MP-E3-C5-T01, MP-E5 (mic on the composer), MP-N6.
