# Command routing process

Implement MP-E2-C2-T03 against predecessor APIs present at 9d7c0b49f.

## Source review

REFRESH-MP-E2-C2-T03-4fbe1095 resolved: supervision moved from
`src/lib/aiur.ex` into `src/lib/aiur/application/children.ex:222-260`.
DecisionStore starts before the proposed router; DecisionExpiry starts later.
Defer now lives in `src/lib/aiur/decision_store/withdrawals.ex:115-137`.
Facts use `DecisionStore.record_command_fact/4`; PubSub still sends
`{:decision_changed, id, version}`. Roster.build supports non-recording reads.
The routing policy and escalation configuration are merged predecessors.

## Implementation

1. Add a supervised `commands/routing.ex` process and `routing/sweep.ex`:
   subscribe before boot sweep, use injected clock/roster/store/config, scan on
   bounded timers and refresh changed Commands. Persist routing, escalation and
   first human-needed facts; recover interrupted fact pairs from projection.
   Read audit order to detect unconsumed defers and explicit Executor escalation.
   Fail roster reads toward humans, retain timer on failed writes. No re-ask.
2. Add Policy.deferrable?/1 and guard accepted defers in Withdrawals; keep generic
   dashboard conflict copy. Document routing and defer behavior in commands.md.

## Verification

`src/test/aiur/commands/routing_test.exs` exercises real isolated DecisionStore:
initial route and PubSub, acknowledgement/answer deadlines, boot catchup and
restart deduplication, empty/stalled/failing roster, terminal/answered skip,
first-visibility repair, explicit escalation, defer refusal and rerouting,
kill switch, failed writes with retry, and non-recording roster reads.
Run affected tests, lint, structural checks and pre-pr. Mutation-check new tests
in a separate worktree. Manual CLI smoke is a post-deploy Executor check.

## Risks

Durable facts do not advance decision versions. Use audit event order, not
version or clock comparison, to recognize a defer once. Keep the existing
escalation deduplication contract. Do not edit decision_attention.ex (#2819).
