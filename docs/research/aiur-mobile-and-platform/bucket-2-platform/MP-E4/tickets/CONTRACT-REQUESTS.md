# MP-E4 contract requests (for the coordinator)

MP-E4 owns `contracts/conversations-transcripts-anchors.md` and updated it in
place (§3, §5, §6, §9, §10, §11, §14, §15). The items below concern documents
MP-E4 does not own, or answer requests other features addressed to MP-E4.
Researched 2026-10-06 at `45a290e3`.

| ID | Target | Request / answer | Needed by |
| --- | --- | --- | --- |
| CR-E4-1 | `contracts/events-and-replay.md` §4.2 (MP-R2) | The reserved envelope field `anchor` is described as `(session, transcript_offset)`. Per RC-07 it must be `{conversation_id, pos, placement, precision}` (conversations contract §10). The bus still never computes it. | MP-N4/N6 deep links |
| CR-E4-2 | `contracts/listener-mode.md` §8 / MP-E7-C6 | When the hook transport delivers a batch into the attached Executor session, the frame must carry each message's `delivery_id` in text the Executor transcript records (for example a trailing `[aiur:delivery <id>]` line), so the Executor journal entry gets `refs.delivery_id` and the delivery overlay can clear. Workers need no echo: their journal entry is written at aiur's delivery point. | MP-E3-C5-T01, MP-E4-C6-T01 |
| CR-E4-3 | MP-R1-C8-T06 (CR-C8-1 to MP-E4) | **Answered** in contract §6 "Layering": the journal write side (`Aiur.Conversation.{Ref, Entry, Session, Store, Journal, Ingest}`) sits at the agent-runner layer; the read side (`History`, `Anchors`, `AnchorResolver`, `JumpPoints`) is the projection layer and the in-daemon read facade. **Collision:** R1-C8-T06 plans `Aiur.Conversations` as the read facade, but `Aiur.Conversations` already exists as the tmux conversation-pane facade (`src/lib/aiur/conversations.ex:1-19`). Please have R1-C8-T06 use `Aiur.Conversation.History` or rename. | MP-R1-C8-T06 |
| CR-E4-4 | RC-05 scope | MP-E4-C6-T02 (inline Command answers) and MP-E3-C6-T03 do not use the listener path; listener-mode contract §2 excludes Command answers. They carry the MP-E7-C3 dependency only because RC-05 is chunk-level. Propose lifting it for these two tickets. Kept until the coordinator decides. | MP-E4-C6-T02, MP-E3-C6-T03 |
| CR-E4-5 | MP-R6 CR-R6-1 / CR-R6-2 | **Answered:** the module name is `Aiur.Conversation.Anchors` (contract §10). MP-E4-C3-T01 is recast as "extend Anchors" (`position/3`, `exact/2`, `strongest/1`, `anchor_id/1`) and depends on MP-R6-C1-T01; it does not move code. MP-E4-C7-T01 only switches the deck's transcript source. | MP-R6-C1-T01 |
| CR-E4-6 | MP-E7 CR-E7-4 | **Adopted:** MP-E4-C6-T01 calls the identifier form of `Aiur.Listener.send/3` in wave 3 and `Aiur.Listener.receipt/2`. | MP-E4-C6-T01 |
| CR-E4-7 | MP-R2-C6 (export journal) | The anchor resolver cannot recover events published while the daemon was down (`live` class). When R2-C6's export journal is enabled, a follow-up ticket should backfill anchors from `seq` using the cursor MP-E4-C3-T02 stores in `resolver.json`. Please list that dependency on R2-C6's consumer side. | after MP-R2-C6 |
| CR-E4-8 | `value-and-sequencing.md` / MP-E4 plan §5 | The plan's "step 1: composer on `AgentChat` before E7" is dropped under RC-05; the composer ships once, on `Aiur.Listener.send/3` (whose flag keeps today's behaviour). Plan §5 and chunks.md are updated. | — |
| CR-E4-9 | DESIGN-E4 (owner) | Add the measured disk figure from MP-E4-C1-T00 to decision 5 (retention). Preliminary (2026-10-06): 112 KB/h/agent p50 lower bound; 228 KB/h p50 and 3.0 MB/h p90 upper bound at a 64 KiB body cap. | DESIGN-E4 |
