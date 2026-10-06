---
ticket_id: MP-E7-C3-T04
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Aiur.Listener.receipt/2: map queue state to the contract §7 receipts (Elixir API only)"
status: ready
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C3-T01]
prior_units: [U3, U6]
prior_boundaries: [MSG (16)]
prior_features: [integrations-43, cli-15, subsystems-14]
prior_findings: []
size_owner: n/a (listener.ex and a new receipt module; operator_messages.ex untouched)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T04 — Delivery receipts

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3.
- **User value:** every surface can tell "accepted", "waiting for the turn",
  "held for the agent", "handed to the agent", "failed" and "outcome unknown"
  apart, and never claims "delivered" when it does not know (MP-E4-C6 test
  "overlay never says 'delivered' on `outcome_unknown`").
- **Deliverable:** `Aiur.Listener.receipt(request_id, timeout \\ 5_000)`
  (PROPOSED, in `listener.ex`, logic in `src/lib/aiur/listener/receipt.ex`)
  returning `{:ok, %{receipt: atom, queue_status: atom, listener_mode: atom | nil, observed_at: DateTime.t()}}`
  or `{:error, reason}`; and `Aiur.Listener.receipt_for_send_result/1` mapping
  a `send/3` error tuple (`{:error, {:outcome_unknown, _}}`) to
  `outcome_unknown`.
- **Non-goals:** HTTP exposure and CLI wording (no status route exists:
  `router.ex:158-159` has only `POST /api/v1/:id/messages`; any new route or
  output is MP-E7-C7 with DESIGN-E7 copy); `in_context` transcript matching
  (needs MP-E4's journal; returned as `harness_queued` until then); `read`
  (MP-E7-C5).

## Dependencies and blockers

- DESIGN-E7; MP-E7-C3-T01 (`consume_at: :pull`, `listener_mode_at_claim`).
- Concurrent with MP-E7-C3-T02/T03.

## Verified starting point (aiur `45a290e3`)

- `AgentChat.delivery_status/2` returns the raw queue status
  (`agent_chat.ex:67-79`) via `operator_message_status/3`
  (`operator_messages.ex:114-125`).
- Item fields used: `status` (`agent_queue_item.ex:6`), `provider_delivered_at`
  (:30), `failure_reason` (:35), `delivery` (:18).
- The visible-message projection already distinguishes queued / delivered /
  failed (`capabilities.ex:69-74`: `provider_delivered_at` ⇒ `:delivered`).
- Unknown outcome is an error tuple, never a failure
  (`agent_chat.ex:51-55`; `operator_messages.ex:73-95`, #2717).

## Chosen design

| Queue state | Receipt |
| --- | --- |
| `:pending`, `consume_at: :pull` | `held_async` |
| `:pending` otherwise | `accepted` |
| `:delivered` without `provider_delivered_at` | `accepted` (claimed, not yet confirmed by the provider) |
| `:delivered` or `:consumed` with `provider_delivered_at` | `harness_queued` |
| `:failed` | `failed` (with `failure_reason`) |
| `:superseded` | `failed` with reason `:superseded` |
| lookup `{:error, :timeout}` / unavailable | `{:error, …}` → callers render `outcome_unknown` |
| item id not found (restart wiped the in-memory queue) | `unknown`, never `failed` |

`observed_at` is set when the read returns, so a surface that renders the
receipt can render its age (AGENTS.md "If a surface computes an age, it
renders the age").

## Implementation steps

1. Add `receipt.ex` (pure mapping, ~60 lines) and the facade function.
2. Add a GenServer read that returns the item (not only its status): reuse `{:operator_message_status, id}` by adding `{:operator_message_snapshot, id}` beside it in `operator_messages.ex` **only if** the existing status read cannot carry `delivery` and `provider_delivered_at` — prefer a new handler module function to keep `operator_messages.ex` from growing.
3. Tests.

## Non-happy paths

- Daemon restart between send and receipt read: the in-memory queue is empty
  (`agent_queue_store.ex:2-3`), so the id is not found → `unknown` (a
  collapsed cause named at the source, not `failed`).
- Timeout → `{:error, {:outcome_unknown, _}}`.

## Compatibility and rollout

- New read API; `AgentChat.delivery_status/2` unchanged. Rollback: revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/receipt_test.exs test/aiur/orchestrator/operator_messages/message_status_test.exs
```

Tests (`Aiur.Listener.ReceiptTest`):

- "pending pull item maps to held_async".
- "claimed item without provider confirmation maps to accepted, not harness_queued".
- "provider-confirmed item maps to harness_queued".
- "missing item id maps to unknown, never failed".
- "timeout maps to outcome_unknown".
- "receipt carries observed_at".

Mutation checks (unknown-path rule): replace the not-found branch with
`failed` → the missing-id test fails; replace it with the most recent known
status → the same test fails.

## Completion and handoff

- [ ] Receipt API merged; no HTTP/CLI change.
- Dependents: MP-E4-C6-T03 and MP-E3-C5-T02 (delivery overlay), MP-E7-C5 (`read` receipt), MP-E7-C7 (HTTP/CLI rendering).
- Docs: none in wave 3.
