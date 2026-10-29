# Ticket estimates and live ETA

Contract: issue #3159 (MP-E8-C7-T03), adopted design defaults.

## Implementation

1. Persist validated overrides and the last 20 journal entries per positive ticket number, atomically before acknowledging writes. Refuse unsafe, corrupt, foreign or future stores without silently replacing data. Resolve plan/now rows from the complexity table plus overrides; unavailable store means unknown estimates.
2. Expose show/set/clear through the shared launcher and guarded daemon RPC. Wire estimates and observed runtime capacity into the strict payload, fixtures, index subscriptions and diffs. Use shared frontend helpers at every card/list/modal/Gantt/ETA site, preserving the design fixture values and escaped override cues.

## Validation

Exercise validation, persistence/restart, corruption/version/repository/unsafe paths, failed writes, concurrent journaling and change signals. Exercise unknown and ambiguous complexity through the assembled index, estimate updates and live capacity diffs, strict schema rejection, shell argument encoding, CLI output, partial/unavailable ETA and browser diff rendering. Run new-test mutations in an isolated worktree, scoped tests, compile/format/lint, structural and pre-PR gates.

Manual Executor-root CLI/TUI smoke belongs in the PR as exact post-deploy steps. Keep the PR stacked and draft while #5569 is open.
