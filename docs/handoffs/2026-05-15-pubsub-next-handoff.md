# PubSub Next Handoff

Created: 2026-05-15
Current branch: `symphony/pubsub-work`
Base commit: `979404b` (`fix(cli): deliver operator input interrupt-first (#26)`)

## Why This Handoff Exists

The CLI operator-input work has landed on `main` through PR #26. The next work
should return to the broader PubSub goal from the May 12 requirements, but from
the current codebase reality rather than the older plan's starting point.

Use this handoff as the current baseline for the next agent or session.

## Recently Landed Context

PR #26 merged the interrupt-first CLI operator-input work:

- CLI composer edits render from cached dashboard state, avoiding snapshot-refresh
  lag and transient `Orchestrator snapshot unavailable` frames.
- `AgentChat.send/2` defaults to interrupt delivery with `:queue_next` fallback.
- Codex and Claude adapters can interrupt an active turn for interrupt-requested
  operator messages, then `AgentRunner` drains the queued text as the next turn.
- Checkpoint delivery skips interrupt-requested queue items, so urgent operator
  input is not stolen by the passive checkpoint path.
- Queued text disappears from the grey queued-input section once the matching
  operator message appears in the canonical agent log.
- `AgentLog` no longer includes workflow template text such as `### Validation`
  and `- [ ] ...` inside issue-prompt summaries.
- CI was green before merge:
  - `make-all`
  - `validate-pr-description`

The old root-level `handoff.md` was intentionally removed after this document
became the up-to-date handoff.

## Source Documents

Primary PubSub source:

- `docs/brainstorms/2026-05-12-agent-queue-and-pubsub-requirements.md`
- `docs/plans/2026-05-12-feat-agent-queue-and-pubsub-plan.md`

Recent operator-input source:

- `docs/brainstorms/2026-05-14-cli-pending-input-and-operator-delivery-requirements.md`
- `docs/plans/2026-05-14-cli-interrupt-first-input-plan.md`
- `docs/handoffs/2026-05-14-cli-chat-reroute-handoff.md`

Important note: the May 12 PubSub plan is partly stale. Its early units describe
work that now exists. Treat it as design intent, not as a current task list.

## Current Implemented Baseline

The queue and delivery substrate already exists:

- `elixir/lib/symphony_elixir/agent_queue.ex`
- `elixir/lib/symphony_elixir/agent_queue_item.ex`
- `elixir/lib/symphony_elixir/agent_queue_store.ex`
- queue ownership in `elixir/lib/symphony_elixir/orchestrator.ex`
- delivery and drain logic in `elixir/lib/symphony_elixir/agent_runner.ex`
- adapter checkpoint and interrupt handling in:
  - `elixir/lib/symphony_elixir/codex/coding_agent.ex`
  - `elixir/lib/symphony_elixir/claude/coding_agent.ex`

There is also already a first cut of dependency-event enqueueing in
`Orchestrator`:

- poll reconciliation compares previous and current `Issue.blocked_by`
- dependency added/removed events are enqueued
- blocker terminal/non-terminal transitions are enqueued
- coordination events use the same `AgentQueue` primitive as operator messages
- running agents are notified via `{:agent_queue_updated, ...}`

There is existing Phoenix PubSub only for dashboard observability:

- `SymphonyElixir.PubSub`
- `SymphonyElixirWeb.ObservabilityPubSub`

Do not confuse that observability PubSub with the desired agent coordination
PubSub model. The next work may reuse Phoenix PubSub internally, but the product
primitive is the queue-backed agent/event delivery model.

## What Still Needs PubSub Work

The next work should focus on making blocker-ticket PubSub a coherent product
slice rather than just queue events emitted during polling.

Recommended next scope:

1. Audit current dependency-event behavior against the May 12 requirements.
   - Verify which transitions are already emitted.
   - Verify event bodies, dedupe keys, causal refs, and subscription metadata.
   - Confirm blocked issues that are not running retain queued events for later.

2. Make subscription state explicit enough to reason about.
   - Today subscription is mostly implicit in `Issue.blocked_by` during polling.
   - Decide whether v1 needs an explicit subscription index in orchestrator state
     or whether derived-on-poll is sufficient.
   - Keep tracker dependency metadata as the authority for blocker relationships.

3. Define and test the event catalog for v1.
   - `:dependency_added`
   - `:dependency_removed`
   - `:blocker_became_terminal`
   - `:blocker_became_non_terminal`
   - Avoid ordinary progress noise by default.

4. Improve observability for coordination events.
   - Running table / detail API should expose enough queue metadata to debug why
     a blocked issue received an event.
   - Agent log rendering should keep coordination events visually distinct from
     operator messages and issue prompts.

5. Add end-to-end tests for the blocker PubSub slice.
   - repeated unchanged blocker snapshots do not spam the queue
   - dependency edge added creates one durable event
   - dependency edge removed creates one durable event
   - non-terminal to terminal emits one unblock-relevant event
   - terminal to non-terminal emits one reblock-relevant event
   - queued coordination events drain through the same queue delivery path as
     other non-interrupt items

## Suggested First Implementation Pass

Start with a characterization pass, not a rewrite:

1. Read `Orchestrator.sync_polled_issue_state/2` and the dependency helpers near
   `emit_dependency_transition_events/3`.
2. Extend tests around the existing behavior in
   `elixir/test/symphony_elixir/orchestrator_status_test.exs`.
3. If behavior matches the desired v1 event catalog, add observability/API tests
   before changing structure.
4. If behavior is too implicit, introduce the smallest explicit subscription
   state needed to make tests and debugging clear.

Keep the implementation aligned with the current queue primitive. Avoid creating
a second message lane, separate inbox, or separate transport-specific queue.

## Verification Baseline

Before starting PubSub changes, the current mainline should pass:

```text
make -C elixir all
```

The last verified PR run passed `make-all` and `validate-pr-description`.

For narrower local loops, use:

```text
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs
mix test test/symphony_elixir/agent_queue_test.exs
mix test test/symphony_elixir/status_dashboard_view_test.exs
```

## Boundaries

In scope next:

- blocker-ticket PubSub as the first real event flow
- explicit subscription/event behavior where needed
- queue/event observability and tests

Out of scope unless the user redirects:

- freeform agent-to-agent chat
- a separate PubSub transport lane unrelated to `AgentQueue`
- redesigning the CLI composer again
