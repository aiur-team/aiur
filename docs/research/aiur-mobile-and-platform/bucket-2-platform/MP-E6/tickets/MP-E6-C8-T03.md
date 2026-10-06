---
ticket_id: MP-E6-C8-T03
feature_id: MP-E6
chunk_id: MP-E6-C8
bucket: 2-platform
title: Link a delivered draft to its position in the agent conversation (E4 anchor)
status: blocked
blocked_by: [DESIGN-E6, DESIGN-E4, MP-E6-C8-T01, MP-E4-C3-T02, MP-E7-C3-T04]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C8-T03 — Draft → agent conversation link

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C8.
- **User value:** from a voice transcript, one click shows the exact place in the agent's
  conversation where a confirmed instruction or consult landed, and what the agent did next.
- **Deliverable:** when a draft reaches `delivered`, record `delivery{draft_id, delivery_id,
  pos}` where `pos` is the E4 journal position of the entry with that `delivery_id`
  (RC-07: the journal position is the anchor address); the history view renders a link to
  `/conversations/:conversation_id?pos=N` (E4-C5 route, final path per DESIGN-E4).

## Dependencies and blockers

- **Gates:** DESIGN-E6 (where the link sits in the history detail), DESIGN-E4 (the
  conversation route's final path and the `pos` query parameter).
- **Predecessors:** MP-E4-C3-T02 (journal positions and anchors), MP-E7-C3-T04 (delivery ids
  and receipts), C8-T01 (history detail view that renders the link).
- **Contracts:** conversations-transcripts-anchors §5 (`operator_message` is written at the
  delivery point with `refs.delivery_id`), §7 (History API `list_entries/2` with a required
  `principal`, `subscribe/1` messages `{:entries_appended, conversation_id, [Entry]}`);
  RC-07 (the journal position is the anchor address); voice-session §9 (`delivery` record).

## Verified starting point (base `45a290e3` and contracts)

- No anchor or journal position exists at base; both are proposed by MP-E4
  (`contracts/conversations-transcripts-anchors.md` §7, lines 214-235 of the contract on
  2026-10-06). The conversation page route is proposed by MP-E4-C5-T01:
  `live("/conversations/:conversation_id", ConversationLive, :show)` with `?pos=N` reserved for
  MP-E4-C5-T03.
- For workers the `delivery_id` is the `AgentChat` queue item id, which the journal records as
  `refs.delivery_id` on the `operator_message` entry (conversations contract §5 and the MP-E7
  row of its reconciliation table). The send path returns it through
  `Aiur.Listener.send/4` → `delivery_id` (voice-session §11, MP-E7 row).
- The voice transcript already records `delivery{draft_id, message_id, status}` (C6-T01); this
  ticket adds the position.

## Chosen design

- New module `Aiur.VoiceConversation.DeliveryAnchor` (one `Task` per delivered draft, under the
  voice-conversation task supervisor started by C4-T01).
- **Trigger:** the draft reaches `delivered` (C5-T03 flow) with a `delivery_id` and a
  `ConversationRef` for the target (worker or Executor).
- **Resolution, race-free:** subscribe to `conversation:<conversation_id>` **first**, then call
  `Aiur.Conversation.History.list_entries(ref, principal: :internal, tail: true, limit: 200,
  kinds: [:operator_message])` and look for `refs.delivery_id == delivery_id` (the entry may
  have been written before the subscription). If absent, wait for `{:entries_appended, _,
  entries}` containing it, for at most 10 minutes (`:resolve_window_ms`, injected).
- **Record:** append and fsync `delivery_anchor{draft_id, delivery_id, conversation_id, pos,
  status: "resolved" | "unresolved", at}` to the voice transcript (C6-T01 writer), then
  broadcast so an open history view updates.
- **Unresolved:** after the window, or if the History API returns `{:error, :unavailable}`,
  record `status: "unresolved"` with `pos: null`. The view shows "Position unknown" and no
  link. A position is never guessed (not the latest position, not a time-based estimate).
- **Rendering (C8-T01 component):** a resolved record renders a link to
  `/conversations/:conversation_id?pos=N` (path per DESIGN-E4). Placement and label are
  DESIGN-E6 copy; only that is design-pending.
- **Executor target:** the same rule with the Executor `ConversationRef` (MP-E3); if the
  Executor conversation capability is unavailable, record `unresolved` at once.

## Implementation steps

1. `src/lib/aiur/voice_conversation/delivery_anchor.ex`: `start(draft, delivery_id, ref,
   opts)` with injected history module, PubSub, writer and clock.
2. Call it from the C5-T03 confirm flow when the receipt reaches `delivered`.
3. Add the `delivery_anchor` record kind to the C6-T01 writer's record list and to the C6-T02
   reader (unknown kinds already render raw, C8-T01).
4. Render the link or "Position unknown" in the C8-T01 detail component
   (`src/lib/aiur_web/live/voice_history/…`, the module C8-T01 creates).
5. Tests below; docs line.

## Non-happy paths

| Case | Behaviour |
| --- | --- |
| Entry written before the subscription | found by the initial `list_entries` read |
| Entry never written (delivery reported but journal gap) | `unresolved` after the window |
| History API `:unavailable` | `unresolved` at once, one debug log line |
| Daemon restart inside the window | task is lost; boot does not resume it; the record stays absent and the view shows "Position unknown" (absent and `unresolved` render the same) |
| Agent restarted into a new session | the entry is in the session that received it; the link points there (E4 sessions overlap pages) |
| Draft `failed` or `stale` | no task, no record |

## Compatibility and rollout

Additive record kind; older history views render it as a raw line. Ships with DESIGN-E6 and
DESIGN-E4 approval. Rollback: revert; existing `delivery_anchor` lines stay as raw lines.

## Verification

| Test (`src/test/aiur/voice_conversation/delivery_anchor_test.exs`, fake History and PubSub) | Expected | Must fail without |
| --- | --- | --- |
| "a delivered draft records the journal position of its delivery id" | entries at pos 40 (other id) and 41 (this id) → record `pos: 41, status: resolved` | matching on `refs.delivery_id` |
| "an entry written before subscription is found by the initial read" | fake history already holds the entry; no PubSub message → resolved | the initial `list_entries` read |
| "an unresolved delivery records unresolved with no position" | window elapses (injected clock) → `pos: null, status: unresolved` | the timeout branch (replace with latest pos → fails) |
| "history unavailable records unresolved at once" | fake returns `{:error, :unavailable}` | the unavailable branch |
| "the record is on disk before the broadcast" | subscriber kills itself on receipt; file has the line | append-before-broadcast order |

| Test (`src/test/aiur_web/voice_history_test.exs`, extends C8-T01) | Expected | Must fail without |
| --- | --- | --- |
| "resolved anchor renders a conversation link with pos" | `href` ends `?pos=41` | the link branch |
| "unresolved anchor renders Position unknown and no link" | text present; no `href` to `/conversations` | the unknown branch (replace with a link to the latest pos → fails) |

```bash
env -C src env -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test test/aiur/voice_conversation/delivery_anchor_test.exs test/aiur_web/voice_history_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree; hash-check `~/.aiur/github-budget/agent-token` before and
after. **Mutation check.** Use the latest position instead of the matched one: the first test
fails. Each "Must fail without" row is checked by reverting that hunk in a worktree and
reporting the command in the PR.

## Docs

`website/docs-app/guide/` voice page (C9-T01 creates it): one sentence that a confirmed voice
instruction links to where it landed in the agent conversation, or says "Position unknown".

## Completion and handoff

- [ ] Anchored links for delivered drafts, unresolved state, tests, docs sentence.
- **Dependents:** none.
