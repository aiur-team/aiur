# Source reviews for MP-E2

Owner: MP-E2 feature owner. These are source-verification holds, not rejected product designs.

For each named item, read the current owner and rewrite the cited starting point and implementation placement. Close only after current semantics are checked; preserve product/predecessor gates. Historical citation text is retained as evidence, not executable guidance.

| Item / ticket | Historical citation | Source baseline | Reason |
| --- | --- | --- | --- |
| REFRESH-MP-E2-C1-T02-4fbe1095 | `src/lib/aiur/decision_validation.ex:40-58` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T03-4fbe1095 | `src/lib/aiur/decision_store.ex:2616-2623` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T04-4fbe1095 | `src/lib/aiur/decision_projection.ex:844-883` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T04-4fbe1095 | `src/lib/aiur_web/operator_control_center/decision_presenter.ex:22-95` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T03-4fbe1095 | `src/lib/aiur.ex:417` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:88-89` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `src/lib/aiur/agent_control_cli.ex:354-366` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `src/lib/aiur/executor_command_cli.ex:8-66` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C4-T02-4fbe1095 | `src/lib/aiur/app_server/turn_loop.ex:9-52` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C4-T03-4fbe1095 | `src/lib/aiur/decision_dispatch.ex:36-66` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C5-T00-4fbe1095 | `src/lib/aiur/claude/coding_agent.ex:302-399` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C5-T02-4fbe1095 | `src/lib/aiur/claude/coding_agent.ex:302-383` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C5-T03-4fbe1095 | `src/lib/aiur/decision_store.ex:4725-4764` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C6-T01-4fbe1095 | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:88-89` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C6-T01-4fbe1095 | `src/lib/aiur/agent_control_cli.ex:354-366` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C6-T02-4fbe1095 | `src/lib/aiur/executor_listener.ex:183-193` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C6-T02-4fbe1095 | `src/lib/aiur/executor_wake_projection.ex:9-42` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C6-T03-4fbe1095 | `src/lib/aiur/asks_cli.ex:1-95` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C7-T03-4fbe1095 | `src/lib/aiur/orchestrator/status_report.ex:1040-1070` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C7-T05-4fbe1095 | `packages/streamdeck/src/channel.ts:238-270` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |

## REFRESH-MP-E2-C7-T05-4fbe1095 — closed (2026-10-26)

Current source review: `channel.ts` dispatches Commands pushes at 261–262 and
sends `answer_command` at 285–286; DTOs live in `channel-types.ts:158–172`.
Input handling moved to `controller/commands.ts` (`pressCommandsKey`,
`approveCommand`); faces live in `commands.ts` (`detailKeyDescriptors`,
`detailPanel`). The server handler is `streamdeck_channel.ex:157–171`, with
payload construction and facade submission in `streamdeck_channel/command_answers.ex`.
`Decision.questions` is normalized by `Commands.RequestContent` with atom-key
`multi_select` and first-question option IDs; the answer facade and native
answer decoder already accept single-question `option_id` replies. Guard
placement: `StreamdeckCommands`, called after the channel's focused-agent check.
The channel keeps its current length. Product and predecessor gates are retained.
