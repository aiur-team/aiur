---
ticket_id: MP-E6-C5-T06
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: aiur delivery of confirmed drafts and consults through MP-E7 listener mode (split from C5-T03)
status: blocked
blocked_by: [MP-E6-C5-T03, MP-E6-C11-T04, MP-E7-C3-T03, MP-E7-C3-T04, DESIGN-E6]
complexity: 2
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a (aiur host adapter)
base_sha: 0972f0297
researched: 2026-10-10
---

# MP-E6-C5-T06 — aiur delivery through E7

Plan: [../plan.md](../plan.md) §19.10 (dependency re-cut), §17.8. Split from C5-T03 so the core confirm rule (C5-T03) does not wait for MP-E7, which is not yet on GitHub.

## Identity and outcome

- **User value:** in aiur, a confirmed voice draft reaches the worker through listener mode with the "via voice" tag and receipts.
- **Deliverable:** `Aiur.VoiceConverse.Host.AgentChannel.instruct/4` and `ask/4` for worker targets via E7 `Aiur.Listener.send/3` with `origin: :voice_assistant` and `:checkpoint` delivery; receipt mapping to `{:receipt, delivery_id, …}`; consult reply capture. This is the delivery half of the old C5-T03 and the delivery mirror it described.
- **Non-goals:** the core confirm rule (C5-T03); Executor delivery (C12-T03).

## Acceptance criteria

- [ ] One confirm → one E7 send with `origin: :voice_assistant`, `delivery_policy: :checkpoint` and `client_request_id = draft_id` (the core `idempotency_key`). A repeated `instruct/4` with the same key returns the first `delivery_id`.
- [ ] Receipts from listener mode map to the core receipt messages: `accepted`/`held_async` → `:accepted`; `harness_queued`/`in_context`/`read` → `:delivered`; `failed` and `superseded` → `:failed`; `outcome_unknown`, a lookup error and an item not found → `:unknown` (never `:failed`).
- [ ] `ask/4` sends the core's framed text with the same options and returns a `ref`. The first agent message after the `harness_queued` (or later) receipt arrives at the subscriber as `{:agent_reply, ref, text}`.
- [ ] `ask/4` and `instruct/4` return in ≤ 300 ms (plan §17.4). Receipt reads and reply capture run in the adapter process, not in the caller.
- [ ] Without E7 present, `AgentChannel` reports `instruct` unsupported and the session states it (no crash).

## Verification

```bash
env -C src mise exec -- mix test test/aiur/voice_converse/host/agent_channel_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Drop the `origin` option: the send-shape test fails.

## Completion and handoff

- **Dependents:** C7-T03, C10-T04, C12-T03 (pattern).

## Plan pass (2026-10-10)

**Key decisions**

- The adapter calls `Aiur.Listener.send(target, text, client_request_id: draft_id, origin: :voice_assistant, delivery_policy: :checkpoint)`. Reason: MP-E7-C3-T03 defines this facade; Phase D adds `:voice_assistant` to the closed origin set.
- The adapter polls `Aiur.Listener.receipt/2` per open delivery and pushes only status changes. Reason: MP-E7-C3-T04 gives a pull API, not a subscription. Polling stops at a terminal receipt or at `consult_timeout_seconds`.
- The receipt mapping is one pure function with a table test. Reason: it is the only place where E7 receipt names meet the core atoms. It copies the C5-T03 amendment table and adds `superseded` and "item not found" from MP-E7-C3-T04.
- Reply capture subscribes to `Aiur.LiveConversation.subscribe/1` (on main, `live_conversation.ex:110`). It takes the first agent message after the `harness_queued` receipt. Reason: `in_context` and `read` come from MP-E7-C5, which is not a blocker. The adapter accepts them when they exist.
- E7 presence is a runtime check (`Code.ensure_loaded?(Aiur.Listener)` and the `listener-modes` component state). `capabilities/1` then omits `instruct` and `ask`. Reason: the core already states an absent capability (plan §17.4 "absent → no `ask_agent`, no instruction drafts, stated").
- The module holds no draft, confirm or consult state (plan §17.8 size rule). The "one outstanding consult" rule and the 5-minute timeout stay in the core (C5-T04).

**Risks**

- E7 send or receipt signatures change before merge → depend on the facade only, and keep one test fixture that names every option. A signature change fails that test.
- Receipt polling adds load with many sessions → poll at 1 s, back off to 5 s after `:accepted`, stop at terminal. `max_sessions` bounds the total.
- A restart wipes the in-memory E7 queue, so the receipt reads "not found" → map it to `:unknown`. The core keeps the draft `sent` with an "unknown" note (C5-T03).
- The wrong agent message is taken as the consult reply (for example, a reply that the agent wrote before it read the question) → require `occurred_at` after the delivery receipt. Test it with an earlier message in the fake stream.

**Test strategy**

- Unit tests with fakes (`test/aiur/voice_converse/host/agent_channel_test.exs`): a fake listener module injected through config records `send/3` calls and returns scripted receipts; a fake LiveConversation source emits agent messages. The tests cover the send shape, idempotent re-send, the full receipt table, reply capture order, the 300 ms return and the absent-E7 capability.
- Integration: one test with the real `Aiur.Listener` against a fake harness (MP-R7 fake) after E7 merges. It confirms a draft end to end and asserts the `:delivered` receipt. It is in the same file, tagged `:integration`.
- Browser: none here. C7-T03 owns the confirm UI.
- Manual with real keys: none. The adapter calls no paid API. Cost cap: USD 0.
- Mutation guards: drop the `origin` option → the send-shape test fails. Map "item not found" to `:failed` → the receipt-table test fails. Remove the `occurred_at` filter → the reply-order test fails.

**Open points**

- C7-T03 and C10-T04 depend on aiur delivery but their `blocked_by` lists C5-T03 and not C5-T06. C11-T04 still names C5-T03 as the `AgentChannel` owner. The Executor (pack owner) adds C5-T06 to C7-T03 and C10-T04, and updates the C11-T04 non-goal. This pass does not edit those files.

Changed in plan pass: the acceptance criteria now name the `:checkpoint` policy and `client_request_id`, list the full receipt mapping, and add criteria for consult reply capture and the 300 ms return. The old text did not test the `ask/4` half of the deliverable. `blocked_by` is correct and is not changed.
