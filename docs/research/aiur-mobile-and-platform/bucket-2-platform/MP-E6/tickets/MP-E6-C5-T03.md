---
ticket_id: MP-E6-C5-T03
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: Confirm and discard drafts; deliver instructions through the listener-mode send with draft_id idempotency
status: blocked
blocked_by: [E6-OQ1 (default adopted - on-screen Confirm only), MP-E6-C5-T02]
prior_units: []
prior_boundaries: [VOX, MSG]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C5-T03 — Confirmation and delivery

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C5.
- **User value:** what the operator confirms is exactly what the agent receives, once, with
  a visible delivery state; nothing else ever reaches the agent.
- **Deliverable:** session calls `confirm_draft(conversation_id, draft_id, edited_text?)` and
  `discard_draft/2` (contract §3.3 client events); confirm of an `instruction` draft →
  `Aiur.Listener.send(conversation_ref, text, client_request_id = draft_id, origin:
  :voice_assistant)` (listener-mode contract §7); receipts mirrored into the draft
  (`accepted/held_async → sent`, `harness_queued/in_context/read → delivered`,
  `failed → failed`, `outcome_unknown → sent` with an "unknown" note) and pushed as
  `delivery` events.
- **Confirmation modality (E6-OQ1):** recommended on-screen Confirm only. If the owner allows
  a spoken confirm, a tool `confirm_draft(draft_id)` is added that still requires the client
  to show the draft and receive a `confirm_draft` client event — speech can request, the
  button sends. The ticket implements the chosen option only.

## Dependencies and blockers

- **Owner:** E6-OQ1; DESIGN-E6 (states, copy).
- **Predecessors:** C5-T02; MP-E7-C3-T03 and C3-T04 (all sends through the listener mode, and receipts;
  `send(conversation_ref, text, client_request_id) → delivery_id`, receipts §7).
- **Contract request (MP-E7, `CONTRACT-REQUESTS.md` R-4):** an `origin` option recorded on the
  queue item and the conversation entry. Without it, delivery still works but the agent
  transcript cannot label the message as voice-originated (DESIGN-E6 §2 surface).

## Verified starting point (base `45a290e3`)

- Today's send: `Aiur.AgentChat.send/3` with `message_id` idempotency (#2717,
  `agent_chat.ex:12-49`); MP-E7-C3 routes it through the listener mode.
- Retry-without-duplicate semantics: same id returns the first item (`agent_chat.ex:22-25`;
  listener-mode §3 rule 7).

## Chosen design

- `edited_text` replaces the draft text (recorded as a new `draft` record with
  `edited: true`) before sending; ≤ 4,000 chars.
- Confirm on a `stale` or `discarded` draft → `{:error, :target_stale}` / `:invalid_transition`.
- Target liveness re-checked at confirm (port `target_alive?/1`); `false` → `stale`
  (`:unknown` → proceed; the send path reports the truth).
- Two confirms (double tap, two tabs on the same session) → second is a no-op returning the
  current status; the listener's `client_request_id` dedup covers a race across processes.

## Implementation steps

1. Session API and client-event handling; 2. listener send adapter (injected);
   3. receipt subscription (`AgentChat.delivery_status/2` per E7-C3-T04); 4. tests.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Agent ended before confirm | `stale` with reason "agent ended" |
| Send returns `outcome_unknown` | draft `sent` + note; retry allowed with the same id |
| Session ends with a confirmed-but-unsent draft | delivery continues (the send is already queued); status written when the receipt arrives via the transcript index (C6-T02) |

## Compatibility and rollout

Requires E7; until then confirm returns `capability_unavailable` and the UI (C7-T03) is not
shipped. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "an unconfirmed draft never calls the send port" | — |
| "confirm sends once with client_request_id = draft_id and origin voice_assistant" | stub records exactly one call |
| "double confirm sends once" | — |
| "confirm of a stale draft is refused with target_stale" | — |
| "edited text is what gets sent and is recorded" | — |
| "receipts map to draft statuses; unknown receipt keeps sent with an unknown note" | — |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/confirm_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Generate a fresh `client_request_id` per confirm: the double-confirm
test fails at the listener stub's dedup assertion.

## Completion and handoff

- [ ] Confirm/discard and delivery mirror; docs in C9-T01.
- **Dependents:** C7-T03, MP-N6-C4-T03, MP-N7 converse.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- The confirm path is core code: `VoiceConverse.confirm_draft(conversation_id, draft_id,
  origin: :client, edited_text: …)`. That is the only caller of `AgentChannel.instruct/4`
  (plan §17.11). Core invariant test with `FakeAgentChannel`: no tool, provider event or
  host callback can call `instruct/4`; a double confirm calls it once per `draft_id`.
- The E7 send (`Aiur.Listener.send/3`, `origin: :voice_assistant`, `client_request_id =
  draft_id`) and the receipt mapping (`accepted/held_async → :accepted`,
  `harness_queued/in_context/read → :delivered`, `failed → :failed`,
  `outcome_unknown → :unknown`) move to `Aiur.VoiceConverse.Host.AgentChannel` (aiur adapter).
  The core mirrors the normalized receipts into the draft.

## Amendment 2026-10-10 — /talk and native providers

Source: [../plan.md](../plan.md) §19 (/talk skill) and §20 (native providers and preferences). Kevin, 2026-10-10 (verbatim): "earlier i asked about making convo mode usable by executors, i even want to usable by any agent via a skill separate from aiur" and "just to flag, i originally said i only wanted air convo to support eleven, this means full support for native model convo wrappers to use model APIs in aiur too and .config settings to choose preferences".

- **Split:** this ticket is now the core confirm/discard rule only (`VoiceConverse.confirm_draft/3` with `origin: :client` calls `AgentChannel.instruct/4` once per `draft_id`). aiur delivery through MP-E7 moves to the new **C5-T06**, which keeps the E7 and DESIGN-E6 blockers.
- E6-OQ1: the core implements the recommended answer (on-screen Confirm only). A spoken confirm, if Kevin ever allows it, only focuses the button; no code path changes.
