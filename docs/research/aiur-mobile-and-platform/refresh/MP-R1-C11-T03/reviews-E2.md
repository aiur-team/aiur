# Source reviews for MP-E2

Owner: MP-E2 feature owner. These are source-verification holds, not rejected product designs.

For each named item, read the current owner and rewrite the cited starting point and implementation placement. Close only after current semantics are checked; preserve product/predecessor gates. Historical citation text is retained as evidence, not executable guidance.

| Item / ticket | Historical citation | Source baseline | Reason |
| --- | --- | --- | --- |
| REFRESH-MP-E2-C1-T02-4fbe1095 | `src/lib/aiur/decision_validation.ex:40-58` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T03-4fbe1095 | `src/lib/aiur/decision_store.ex:2616-2623` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T04-4fbe1095 | `src/lib/aiur/decision_projection.ex:844-883` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C1-T04-4fbe1095 | `src/lib/aiur_web/operator_control_center/decision_presenter.ex:22-95` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T03-4fbe1095 (resolved) | `src/lib/aiur/application/children.ex:222-260` | 9d7c0b49f | Store precedes Routing; expiry follows it. Defer moved to `decision_store/withdrawals.ex:115-137`; see `docs/plans/2026-10-26-command-routing.md`. |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:88-89` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `src/lib/aiur/agent_control_cli.ex:354-366` | 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C2-T04-4fbe1095 | `src/lib/aiur/executor_command_cli.ex:8-66` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C4-T02-4fbe1095 (resolved) | `src/lib/aiur/app_server/turn_loop.ex:9-52` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
| REFRESH-MP-E2-C4-T03-4fbe1095 (resolved) | `src/lib/aiur/decision_dispatch.ex:36-66` | 45a290e3053423100a73b534c620fdd12ebe11ad | LINES-CHANGED: source range has no unique byte-identical destination |
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

## REFRESH-MP-E2-C6-T02-4fbe1095 — closed (2026-10-27)

Source verified on the ticket branch before implementation. Dispatch eligibility
now lives in `decision_store/retry.ex:184–203`, called by
`decision_store/dispatch.ex:170–172,290–303`. Additive facts use
`commands/event_data.ex`, `commands/projection.ex` and
`decision_store/command_facts.ex`. `executor_listener.ex:222–248` keeps alerts
and blocking request wakes separate; answered delivery belongs before that path.
`executor_wake_projection.ex:28–60` excludes all Executor topics; add only
`executor.decision.answered`. `Commands.Topics.publish/4` journals the typed
answer envelope with its action under `data`. Inbox enqueue persists pending
records but coalesces by topic class/ticket: answer records require a distinct
decision key so two Commands cannot erase each other's wake. Preserve U3's
ordering/claim behavior. Product and predecessor gates remain unchanged.

## REFRESH-MP-E2-C4-T02-4fbe1095 — closed (2026-10-27)

Reviewed source at `1d096249d`. Shared receive handling now lives in
`app_server/turn_loop.ex:38–110`: queue updates still call `Interrupts` and
`state.timeout_ms` still bounds idle receives. Replay and relay acknowledgements
precede that loop; capture must leave both intact. Loop defaults are built at
`app_server/adapter.ex:108–129`; approval dispatch is `codex/approvals.ex:35–53`
with trusted execution context from `codex/turn_loop.ex:167–198`. Holds belong in
that dispatch, before fallback policy, without safe-checkpoint processing.
Accounting integration is `token_accounting.ex:114–154`; the stall and duration
guards belong in `runtime_watchdog.ex:327` and `:92`. C4-T00 findings report
Q1–Q3 PASS; the capture facade landed in #6550. Product and predecessor gates
are retained; the capture gate stays disabled pending reply/release support.

## REFRESH-MP-E2-C4-T03-4fbe1095 — closed (2026-10-27)

Re-resolved on the implementation checkout for #6408. `DecisionDispatch.dispatch/2`
builds original-answer correlation and routes through `Commands.DeliveryTarget`;
corrective revisions have their own dispatcher. `Answering.decode_question_answers/2`
and `render_question_answers/2` provide C3's structured encoding. C4's hold is retained
by `Codex.TurnLoop`; `AppServer.Interrupts` suppresses unrelated queue interrupts.
`OperatorMessages.Calls` owns queue claims behind `Orchestrator.Calls`; runner
`TurnCallbacks` carries callbacks through both turn entry points and the app-server
adapter. `QueueDrain` delegates validation and delivery evidence to
`AgentRunner.DeliveryCorrelation`. The store's queue-item settlement contract remains
unchanged. These symbols replace the historical line ranges for implementation.

## REFRESH-MP-E2-C6-T03-4fbe1095 — closed (2026-10-27)

Source reviewed before implementation on ticket #6421. `asks_cli.ex:13–56`
now routes legacy operations through `Commands.create_ask/resolve_ask/open_asks/all_asks`.
CLI dispatch is `cli.ex:38,161–162`, parsing lives in `cli/subcommands.ex:106–165`,
and local launcher execution is `engine/oneshot.sh:171–173` with dispatch in
`aiur-engine.sh:259–261`. C6-T01 landed as `ControlCLI.ExecutorRequest.request/2`
with caller identity (the alias adds an optional result renderer); C6-T02 delivery is merged.
The alias uses these current APIs, preserves local legacy reads/resolution, and
loads the current Command version before Executor withdrawal. Current IDs use
the `dec_` prefix plus 16 hex characters; the historical bare-hex description is stale. Historical ranges
are superseded; the design and compatibility requirements are retained.
