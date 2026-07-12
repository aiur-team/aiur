---
title: "feat: Add bulk todo queue command"
type: feat
status: completed
date: 2026-07-12
---

# feat: Add bulk todo queue command

## Summary

Add a distribution-free `aiur --todo <ids...> [--only]` path that reads the current workflow configuration, streams a result for every ticket mutation, and exits non-zero when any requested ticket fails. Keep `--only` safe by dequeuing other pending tickets without interrupting tickets already in a mid-flight state.

---

## Problem Frame

Operators currently have to open GitHub or invoke `gh` repeatedly to queue a selected ticket set. Scoping a run also requires finding and manually clearing every other pending ticket, which is slow and easy to get wrong.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- `--only` follows the issue's recommended safe default: remove the configured `<prefix>:todo` label from other tickets, while preserving configured non-`todo` active labels so live or resumable work is not interrupted.
- A passed ticket already carrying a configured non-`todo` active label is a successful no-op with explicit feedback; the command does not downgrade it to `todo`.
- The explicit `--only` flag is sufficient operator intent, so the initial command does not add a confirmation prompt or a separate `--yes` flag.
- Duplicate passed IDs are processed once in first-seen order.
- `--only` cleanup runs only when every requested ID validates successfully; requested-ticket failures still allow the remaining requested IDs to queue, but fail closed before dequeuing any other ticket.

---

## Requirements

- R1. `aiur --todo <id...>` validates each requested open GitHub issue, adds the config-derived `<label_prefix>:todo` label only when needed, and prints feedback immediately for every requested ID.
- R2. Existing `todo` labels are idempotent no-ops, configured mid-flight active labels are preserved, and terminal or nonexistent requested tickets are reported without aborting later IDs.
- R3. When every requested ID validates successfully, `--only` enumerates open tickets across configured active states, excludes the selected IDs, removes the config-derived queue label from every other pending ticket, and streams each removal. Any requested-ID failure skips this cleanup entirely.
- R4. Repository, label prefix, active states, and terminal states come from the detected workflow configuration and GitHub adapter rather than command-local defaults.
- R5. The final summary reports queued and cleared counts, and any per-ticket or enumeration failure produces a non-zero process exit.
- R6. The command runs as a standalone one-shot command without requiring an Aiur daemon or tmux session.

---

## Scope Boundaries

- Do not change orchestrator pickup, scheduling, or lifecycle-transition behavior.
- Do not remove non-`todo` active labels from other tickets or interrupt live agents.
- Do not add a dashboard/TUI control surface, confirmation UI, or a second bare `todo` subcommand in this iteration.
- Do not generalize the operation to non-GitHub trackers.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/agent_control_cli.ex` owns operator-facing command behavior, streaming output, dependency injection seams, and exit outcomes.
- `src/lib/aiur/cli.ex` already handles distribution-free one-shot entrypoints such as `init` and `--version`.
- `packaging/npm/aiur-cli/libexec/aiur-engine.sh` dispatches command shapes before the run path; its `start_clean` launch is the daemon-free pattern to reuse.
- `src/lib/aiur/github/tracker.ex`, `src/lib/aiur/github/issues.ex`, and `src/lib/aiur/github/issue_state.ex` provide normalized reads and idempotent raw label writes.
- `src/lib/aiur/github/config.ex` and `src/lib/aiur/config.ex` expose the configured repo, prefix, active states, and terminal states.

### Institutional Learnings

- The shared launcher engine is the single command surface for `aiur` and `aiurdev`; new command dispatch belongs there rather than in the dev shim.
- A distribution-free one-shot must start the Req application explicitly before using the GitHub HTTP client, matching the existing `aiur init` runtime pattern.

---

## Key Technical Decisions

- Run `--todo` through the release's distribution-free `start_clean` path so it can coexist with a running node and never creates a tmux session.
- Keep ticket orchestration in `Aiur.AgentControlCLI`, with injectable configuration and tracker functions so all behavior can be tested without GitHub traffic.
- Fetch requested tickets individually. This preserves per-ID error isolation and makes nonexistent, closed, terminal, already queued, and mid-flight outcomes independently reportable.
- Enumerate `--only` candidates using all configured active states, but remove only the same config-derived queue label that the command adds. This honors custom state discovery while preserving running work.
- Fail closed before `--only` cleanup when any requested ID fails validation, so a typo, closed issue, or transient read failure cannot broaden the destructive result.
- Perform mutations sequentially so output is genuinely streamed in ticket order and summary counts reflect completed operations.

---

## Open Questions

### Resolved During Planning

- Should `--only` clear every configured active label? No; use the issue's recommended safe dequeue interpretation and preserve non-`todo` mid-flight states.
- Should destructive confirmation be added? No; keep the requested non-interactive contract and treat `--only` as explicit opt-in.
- Should a passed mid-flight ticket be downgraded? No; preserve it and print a successful no-op line.
- Should `--only` continue after a requested ticket fails? Requested queue processing continues, but cleanup of other tickets is skipped so partial validation cannot narrow the queue unexpectedly.

### Deferred to Implementation

- Exact operator wording and error formatting may follow the closest existing CLI output conventions discovered while implementing, while retaining the required per-ticket and summary information.

---

## Implementation Units

### U1. Implement config-driven queue operations

**Goal:** Add the standalone bulk queue/dequeue behavior and its isolated, streaming result accounting.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/agent_control_cli.ex`
- Test: `src/test/aiur/agent_control_cli_test.exs`

**Approach:**
- Resolve the detected workflow's GitHub settings before mutating anything and report setup failures as command failures.
- Normalize and deduplicate passed IDs, fetch each requested issue separately, and classify it from normalized state and labels before deciding whether to add the queue label.
- Accumulate successful selections and failures while printing each result immediately.
- For `--only`, proceed only after every requested ID validates; otherwise print that cleanup was skipped. A successful validation pass fetches tickets in configured active states and removes the queue label from other pending tickets one at a time, preserving all other labels.

**Patterns to follow:**
- Existing injected action functions and output helpers in `src/lib/aiur/agent_control_cli.ex`.
- Normalized `Aiur.Issue` labels returned by `src/lib/aiur/github/issues.ex`.

**Test scenarios:**
- Happy path: three open unlabeled issues receive the custom-prefix queue label in input order, each prints feedback, and the summary reports three queued tickets.
- Edge case: an issue already carrying the queue label performs no write but remains a successful queued result with feedback.
- Edge case: an issue carrying a configured mid-flight label is preserved, receives no queue label, and prints that it was kept active.
- Error path: nonexistent, closed, terminal, and tracker-error IDs each print a failure, later IDs still run, and the final result is non-zero.
- Safety: any requested-ID failure with `--only` leaves every non-requested ticket unchanged and reports that cleanup was skipped.
- Happy path: `--only` enumerates all custom configured active states, excludes selected IDs, removes the custom queue label from other pending issues, and reports each removal and the cleared count.
- Edge case: `--only` leaves other mid-flight active labels and terminal tickets untouched.
- Error path: one failed removal does not suppress later removals and makes the final result non-zero.

**Verification:**
- Every requested ticket and completed removal produces an immediate line, the summary counts completed queue/clear outcomes, and failures are isolated while affecting the final exit status.

### U2. Route and document the daemon-free CLI contract

**Goal:** Make the new flag reachable through both release launchers without starting a workflow, and document the supported command.

**Requirements:** R1, R5, R6

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur/cli.ex`
- Modify: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Modify: `src/README.md`
- Modify: `packaging/npm/aiur-cli/README.md`
- Modify: `AGENTS.md`
- Test: `src/test/aiur/cli_test.exs`
- Test: `src/test/aiur_engine_test.exs`

**Approach:**
- Parse `--todo` as a variadic ticket operation with optional `--only`, rejecting empty or malformed target lists before any mutation.
- Dispatch the leading flag through the distribution-free one-shot launcher, load the local `.env`, and let the Elixir entrypoint propagate the queue operation's exit code.
- Extend help and command tables while keeping run-path flags and live-node control commands unchanged.

**Patterns to follow:**
- `init` and `--version` one-shot dispatch in `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
- Pure `Aiur.CLI.evaluate/2` parsing tests in `src/test/aiur/cli_test.exs` and fake-release boot-shape tests in `src/test/aiur_engine_test.exs`.

**Test scenarios:**
- Happy path: spaced and comma-separated numeric IDs plus a trailing `--only` parse into one normalized ordered ID list and the enabled option.
- Edge case: duplicate IDs are collapsed without reordering.
- Error path: no IDs, nonnumeric IDs, unsupported options, or `--only` without `--todo` return usage errors and never enter the run path.
- Integration: engine dispatch for `--todo` uses `start_clean` evaluation with no node name, cookie, tmux, or control RPC dependency.
- Integration: command help lists the new syntax and existing run/control routes retain their prior behavior.

**Verification:**
- Both the npm `aiur` launcher and `scripts/aiurdev` share the same one-shot route, and a fake release proves that route is distribution-free.

---

## System-Wide Impact

- **Interaction graph:** launcher dispatch → `Aiur.CLI` parsing → `Aiur.AgentControlCLI` → config-backed GitHub tracker reads/writes.
- **Error propagation:** setup errors and per-ticket failures become readable stderr feedback and a non-zero one-shot exit; successful tickets still complete.
- **State lifecycle risks:** sequential, idempotent writes avoid duplicate labels; safe `--only` never removes running-state labels.
- **API surface parity:** the shared engine keeps npm and dev commands aligned; no daemon RPC or TUI API changes are needed.
- **Integration coverage:** engine fake-release tests prove dispatch shape, while injected tracker tests prove cross-layer mutation ordering and exit accounting.
- **Unchanged invariants:** existing control commands still require a live node, and normal foreground/background launches retain the guardrails and tmux lifecycle.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A partially failing GitHub batch leaves a mixed result | Stream every outcome, continue independent work, summarize completed mutations, and exit non-zero. |
| A bad requested ID turns `--only` into an unexpectedly broad dequeue | Require all requested IDs to validate before removing any other ticket's queue label. |
| `--only` accidentally interrupts live work | Remove only the config-derived queue label from other tickets; preserve every non-`todo` active state. |
| The one-shot path lacks HTTP runtime dependencies | Start Req explicitly before tracker calls and cover the release boot shape in tests. |
| Custom label/state configuration drifts from defaults | Derive all queried active labels and written queue labels from current workflow accessors. |

---

## Documentation / Operational Notes

- Add the command to shared launcher help and both operator command tables.
- Call out that `--only` dequeues other pending work but does not stop agents already in progress.
- Call out that `--only` cleanup is a non-atomic read-modify-write with no cross-process coordination: overlapping `--todo ... --only` invocations can drop each other's tickets.

---

## Sources & References

- Related issue: #725
- Related code: `src/lib/aiur/agent_control_cli.ex`
- Related code: `packaging/npm/aiur-cli/libexec/aiur-engine.sh`
- Related code: `src/lib/aiur/github/issues.ex`
