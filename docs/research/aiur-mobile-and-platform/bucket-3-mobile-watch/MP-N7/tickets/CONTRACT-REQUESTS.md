---
feature_id: MP-N7
researched: 2026-10-06
for: coordinator
---

# MP-N7 contract and cross-feature requests

1. **MP-E5 (RC-16) ticket ID.** MP-N7-C4-T04/T05 depend on the device-authenticated voice
   path in `contracts/voice-session.md` §3.5. MP-E5's chunks.md predates RC-16 and has no
   ticket for it. Request: MP-E5 Phase C names the ticket; replace the placeholder
   "RC-16 MP-E5 device voice path" in both N7 tickets. The path must accept
   `client.kind: "watch"` on joins made by the phone's device credential.
2. **Watch Command card ownership (MP-N6-C5-T01 vs MP-N7-C2-T03/C3-T03).** Proposal: MP-N7
   implements the watch card screens; MP-N6 owns the Command response rules (states,
   option ordering, copy) and the "Open on phone" handoff (MP-N6-C5-T03). MP-N6-C5-T01
   becomes "rules and fixtures for the watch card", consumed by N7.
3. **Notification payload fields for the watch (MP-N4 / MP-N1-C6-T01).** The decrypted
   payload must expose, in `userInfo`, `aiur_dest {machine_id, instance_id, decision_id}`
   and the category `AIUR_COMMAND` (MP-N7-C2-T04). For the conditional MP-N7-C2-T06 it must
   also carry option ids/labels (≤ 3) and the Command `version`.
4. **Wear bridging (MP-N4-C6-T02).** N7-RQ2 resolution: the phone posts Command
   notifications with `WearableExtender().setBridgeTag("aiur-command")` and
   `setDismissalId("<instance_id>:<decision_id>")`; the Wear app excludes that tag from
   bridging and posts its own notification (MP-N7-C3-T04). MP-N4-C6-T02 should set exactly
   these values (shared constant in `fixtures/watch-link/constants.json`).
5. **Device-validation overlap.** MP-N4 V-W1..V-W4 and MP-N1 device-validation.md DV-W1..W9
   are run once, in MP-N7-C6-T01/T02. Request: MP-N1 device-validation.md §3 adds the new
   rows DV-W1b, W2b, W4b, W7b, W7c, W10, W11, W12, W13 (defined in the C6 tickets), and
   MP-N4-C7 links the watch rows to the C6 reports.
6. **`client.surface: "watch"`** is self-reported by the phone on behalf of the watch
   (the watch has no credential). MP-E2/MP-N6-C1-T03 should accept it from a device
   credential as an attribution field, not as an authorization input.
7. **Watch snapshot fields (MP-N1-C3-T04).** The projection must include, per instance,
   `row_state` from MP-N3 `MetaRow`, the Facts listed in MP-N7-C1-T01, and pre-resolved
   affordances `answer_command`, `mic_dictate_system`, `mic_dictate_server`, `mic_converse`,
   `build_progress` (capability model §7 lists all but `mic_dictate_system`; request to add it).
