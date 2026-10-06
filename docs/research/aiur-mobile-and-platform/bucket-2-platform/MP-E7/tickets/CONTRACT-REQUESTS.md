# MP-E7 contract requests (for the coordinator)

MP-E7 owns `contracts/listener-mode.md` and has updated it in place (§3
rules 2 and 8, §4 `steer_carrier`, §5 durability and event, §7 receipts and
`aiur_read_messages`, §9 table including the conditional Gemini row, §10,
§11). The requests below concern documents MP-E7 does not own. Researched
2026-10-06 at aiur `45a290e3`, Khala `origin/main` `99e72a43`.

| ID | Target | Request | Needed by |
| --- | --- | --- | --- |
| CR-E7-1 | MP-R2 catalog (R2-C5) / `contracts/events-and-replay.md` | `ticket.<id>.agent.listen-mode.changed` (RC-08) would be labelled `:self` (the agent's own emission) in the IssueLog (`publisher.ex:339-352`), but a mode change comes from a human, the Executor or the system. Either the catalog carries an actor/attribution override for this topic, or the topic is renamed outside the agent's namespace. | MP-E7-C2-T05 |
| CR-E7-2 | MP-E3 chunks and `contracts/conversations-transcripts-anchors.md` | MP-E3-C5-T01 depends on **MP-E7-C6-T01** (Executor hook delivery), which is wave 4 (RC-05), while E3-C5 is wave 3. Either E3-C5-T01 ships in wave 3 with the composer disabled and the reason shown (as E3 chunks already allow, "No E7 → composer disabled"), or it moves to wave 4. Please record which. | MP-E3-C5, MP-E7-C6 |
| CR-E7-3 | MP-E3-C1-T04 (hook-config generator) | Must accept extra hook entries so MP-E7-C6-T03 can add the deliver hooks without a second generator. | MP-E7-C6-T03 |
| CR-E7-4 | MP-E4 / conversations contract | In wave 3 `Aiur.Listener.send/3` takes a ticket identifier. The `ConversationRef` overload (Executor subject) arrives with MP-E7-C6 / MP-E3. E4-C6-T03 should call the identifier form. | MP-E4-C6-T03 |
| CR-E7-5 | MP-E3 ticket IDs | MP-E3 chunks use single-digit ticket IDs (`MP-E3-C1-T01`); MP-E7 tickets cite them as `MP-E3-C1-T01`. Align when E3 tickets are written. | all C6 tickets |
| CR-E7-6 | `contracts/events-and-replay.md` / MP-R2 | Pending operator messages are not durable: `AgentQueueStore` is in-memory (`agent_queue_store.ex:2-3`; `durability: :durable` persists nothing). Any contract that promises restart survival of queued messages is wrong at base. MP-E7 reports the receipt `unknown` after a restart. | MP-E3, MP-E4, MP-N6 consumers |

## Owner items raised (for DESIGN-E7)

- **OWNER-NPM-FIRST-PUBLISH:** the first npm publish of the new Khala listener
  package needs owner setup (npm trusted publisher for the new package name)
  before MP-E7-C1-T03 can run.
- E7-D5 (mode lifetime) now blocks MP-E7-C2-T01 explicitly.
