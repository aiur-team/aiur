---
title: Conversation read seam and wave-0b adapter
execution: code
artifact_readiness: implementation-ready
---

# Conversation read seam and wave-0b adapter

## Goal

Implement #3162 against the full MP-E8-C11-T03 contract at research commit
6732f5f9f448b1857a9643993849635f85321e19. Preserve the existing drawer.
The workspace log supplies retained history; the live projection supplies state
and remote windows. Missing past history must say “Conversation not retained”.

## Decisions

- Follow current component facades (`Aiur.Conversation.History`), adding bounded
  history access there instead of crossing the conversations component privately.
- Keep parsing, adapter mapping, LiveView lifecycle and DOM rendering separate.
- Use the existing frame's fx body seam; add a compatible registration seam if needed.
- Keep private paths and handles server-side. Validate ids, repository, paths and
  byte cursors before reading. No prompt bodies, raw JSON or tool output on wire.
- Port the checked-in design source in bounded reads; no external import needed.
- No composer, minimap behavior, event producers, typing or command controls.

## Implementation units

### U1: Bounded transcript reader

Files: `src/lib/aiur/agent_log/page_reader*.ex`, `src/lib/aiur/agent_log.ex`,
`src/lib/aiur/conversation/history.ex`, `components/conversations.json`,
`src/test/aiur/agent_log/page_reader_test.exs`.
Implement tail/before/since with 64 KiB reads, budgets, line cursors and generation
checks. Preserve contiguous merge runs and resend the open final group.
Test bounded reads, gap-free pages, delta replacement, malformed/partial/oversize
lines, invalid cursors, truncation and file replacement.

### U2: Conversation source

Files: `src/lib/aiur_web/build/conversation_source*.ex`,
`src/lib/aiur_web/build/conversation_source/`, associated mirror tests.
Build the source seam and wave-0b adapter from current snapshot, workspace and
live history facades. Refresh snapshot only on open/change; poll cached refs.
Test missing/empty/local/remote/legacy sources, unknown snapshot, repository and
symlink refusal, sanitized entry mapping and unknown timestamps.
Dependencies: U1 (parallel implementation against agreed reader API).

### U3: Modal client and design fixtures

Files: `src/priv/static/build-home/modal/conversation*.js`, frame/state/hook wiring,
fixture exporter and support, browser conversation specs and fixture JSON.
Port all item branches and skeleton. Page on top scroll, preserve the anchor,
cap at 500 rows, replace ids, drop stale replies, close subscriptions, render
state/age and unknown-time/model cues. Export deterministic design conversations.
Test hostile text, paging, retry, trimming, state cues, close and late replies;
compare fixture kinds and pixels in the design parity harness.
Independent of U1/U2 while wire messages follow the research contract.

### U4: Protocol and LiveView integration

Files: payload schema/validator extensions, BuildLive, a small conversation
controller, fixture source and LiveView tests; AgentLogModal composer extraction.
Own one pinned source ref and timer; cancel/unsubscribe on switch/close, validate
requests and replies, follow handle changes without losing file history.
Test first/older/reset replies, parameter refusal, read-only access, composer,
subscription order, polls and state/append pushes. Dependencies: U2/U3 integration.

## Verification contract

Run collected mirror/direct-caller tests with max-cases 4, exporter checks,
affected browser specs via their package scripts, compile/format/lint, bare
receive and structural gates. New behavior tests require mutation evidence in
an isolated worktree. Run pre-pr before push and again after PR creation; verify
ready status and fresh head/base evidence before ci-wait.

## Risks and review

Bounded I/O must also bound retained line memory; partial trailing lines wait.
Generation fingerprints can change once for a growing short prefix; resets are
safe. Subscription calls must execute in the LiveView process, not a read task.
Do not treat an unavailable snapshot as proof a session ended. Ensure footer
ages are rendered and unknown causes stay unknown. Plan review: these risks
are represented in unit tests and the adapter/source separation.

## Manual acceptance

Executor-root real CLI/TUI smoke cannot run in an issue workspace. Record exact
post-deploy steps in the PR body without claiming execution here.
