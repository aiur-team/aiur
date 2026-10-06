# MP-R6 requests to the coordinator

## CR-R6-1 — MP-E4 chunks: retire E4-C3-T01 as written (RC-06)

`bucket-2-platform/MP-E4/chunks.md` lists "MP-E4-C3-T01 Neutral
`Conversation.Anchors.at_or_before/2` (extracted rule, same tests)". Under RC-06,
MP-R6-C1-T01 performs that extraction. It creates `Aiur.Conversation.Anchors`
with `at_or_before/2`, `with_origin/2`, `event_identity/2` and `origin_id/0`.
Please have the E4 owner make E4-C3 depend on MP-R6-C1-T01, and drop or recast
C3-T01 as "extend Anchors" (exact/causal precision, `pos`). Otherwise two
tickets would move the same code.

## CR-R6-2 — module name, contract §10 (owner MP-E4)

`Aiur.Conversations` (plural) already exists. It is the tmux conversation-pane
facade (`src/lib/aiur/conversations.ex:1-19`). R6 uses `Aiur.Conversation.Anchors`
(singular, the E4 plan § 3 namespace). Please have the contract owner confirm
the name in `contracts/conversations-transcripts-anchors.md`, or pick another
one. R6-C1-T01 follows the contract.

## CR-R6-3 — badge vocabulary home

R6-C1-T01 adds `Aiur.AgentEventFeed.directions/0`, the five badges `EMIT
CONSUME AGENT SYSTEM INFO`, in the module that produces them
(`agent_event_feed.ex:142-156,278-281`). `StreamdeckKeyFaceContract` then
asserts agreement against it. If the E4 contract defines anchor `kind`/label
vocabularies (§10 jump-point catalogue), they are separate from these direction
badges. No contract change is needed; this is recorded so E4-C4's catalogue does
not reuse `directions/0` by accident.
