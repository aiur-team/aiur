---
name: aiur-agent
description: "The operating manual for an Aiur agent working a ticket. Use at the start of every Aiur ticket turn — covers the agent:* label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, the Agent Workpad template, milestone alerts (emit_alert), complexity routing, the dev loop / commit / PR conventions, and cross-ticket event coordination."
---

# Operating as an Aiur agent

This skill is how an Aiur agent runs a ticket end to end. The per-turn prompt
carries only your ticket + workspace context and a pointer here; everything
about *how* to operate — the ticket workflow, the dev loop, complexity routing,
conventions, and cross-ticket events — lives in the reference docs below. Read
the one that matches what you're doing; you don't need every reference each turn.

## When to use what

| You want to... | Read |
|----------------|------|
| Run a turn: labels, the Agent Workpad, the brainstorm→plan→work→review loop, which CE skill when, milestone alerts | `turn-workflow.md` |
| Branch, commit, push, open + self-review the PR, docs requirement, manual CLI verification, PR description shape | `dev-loop.md` |
| Choose focused tests and validation commands for the target repository's language and packages | `validation.md` |
| Pick model / agent / skill depth from the `complexity:N` label | `complexity-routing.md` |
| Know whose comments are authoritative, file out-of-scope findings, follow tooling + load-repro conventions | `conventions.md` |
| Understand what events are and why they exist | `overview.md` |
| Know which event names are allowed and what they mean | `event-taxonomy.md` |
| Emit an event or subscribe to a topic pattern | `emit-and-subscribe.md` |
| Open / close an Executor attention | `attention-and-resolve.md` |
| Follow an Optimistic start prompt block | [Optimistic start](stub-then-fetch.md#optimistic-start-started-on-an-unmerged-blocker) |
| Unblock yourself temporarily with a stub | `stub-then-fetch.md` |
| Interpret a voice-originated ticket or operator message | `dictated-input.md` |

Before interpreting a voice-originated ticket or operator message, read the
shared [dictated-input note](dictated-input.md).

## The shortest version

- For an **Optimistic start** prompt block, follow [the canonical loop](stub-then-fetch.md#optimistic-start-started-on-an-unmerged-blocker) before the normal ready/CI handoff.
- Move the issue to `agent:in-progress` and keep one `## Agent Workpad` comment
  current. When implementation and draft-PR self-review are complete, mark the
  PR ready before moving to `agent:ci-wait` and ending the turn. Drafts never
  permit handoff, except a draft blocked from outside the ticket (see "Never
  idle" below). Only after all required checks pass on
  the current head SHA, flip to `agent:human-review`. Do **not** self-merge — always await
  human review. Aiur PRs run fast checks; the merge queue runs the full suite.
- **Every state move is `aiur_set_ticket_state({ "state": "<state>" })`, never
  `gh issue edit --add-label` / `--remove-label`.** The daemon relabels your
  ticket too, so a label you name for removal may already be gone — the removal
  no-ops and the leftover second state label makes the ticket undispatchable
  (#2805). The tool makes your target the sole `agent:*` state label.
- Right-size the CE loop to the work: large asks usually run
  `ce-brainstorm → ce-plan → ce-work → ce-code-review`; smaller asks may skip
  brainstorm, plan, or review, but err on the side of using them when in doubt.
- The workspace's checked-out branch is authoritative. New tickets use the generated readable Aiur branch; existing legacy and PR-anchored heads remain unchanged. Never reconstruct a branch from the issue number.
- **Docs ship in the same PR.** A new or changed config key, CLI command or
  flag, operator-set environment variable, or user-facing surface — and any
  change that makes an existing page wrong — updates `website/docs-app/` before
  the PR is ready. Refactors, bug fixes restoring documented behavior, test-only
  changes, and perf work with no interface change need nothing. `dev-loop.md`
  has the page map.
- Every PR description starts with `Closes #<issue>`. Commit messages are short
  (3–7 words), plain, and human — never mention AI, Claude, Codex, or models.
- Integration safety is your responsibility. During `human-review` or
  `ci-wait`, integrate the configured base only when GitHub reports the exact
  PR head as `CONFLICTING` or a newer base commit fixes a failing required
  check (name the commit and check). A reviewer request alone does not
  authorize integration. File overlap and base movement
  alone do not require a push; the merge queue tests the PR on current base.
  Never open a blocking decision for base integration. Record any required
  conflict resolution in `dev-loop.md`.
  A PR already in the merge queue is left alone: never dequeue it, or ask the
  Executor to, in order to update its branch.
- **Async operator messages:** when `async` is effective and
  `aiur_read_messages` is installed, call it after an addressed-message nudge, at natural pauses and before
  yielding or finishing. It consumes and acknowledges your held messages,
  oldest first (optional `max`: 1–50, default 50). Check `remaining` and read
  further batches as needed. This is not a preview; a lost reply after
  acknowledgement cannot be replayed. Leaving async keeps unread bodies
  pull-only while async support remains usable; losing the pull tool routes
  held bodies through the effective mode. Command answers and event digests
  keep their existing delivery.
- **Events:** `emit_event(name, message, payload?)` publishes to
  `ticket.<id>.agent.<name>` against the allowlist in `event-taxonomy.md`;
  `optimistic.integrated` uses `ticket.<id>.optimistic.integrated`.
  `aiur_declare_blocker(N)` auto-subscribes you to a useful subset of
  `ticket.N.*`; `blocked` / `unblocked` are single-attempt, fire-and-forget
  readiness signals. A manual `aiur_subscribe` pattern must begin with
  `ticket.<literal-id>.` — `executor.*`, `system.*`, bare wildcards, and
  wildcard ticket ids are refused before the binding is created.
- **Ask a bounded operator question with a Decision:** emit `decision.requested`
  with structured `options` and a recommendation before any attention or pause.
  A question phrased as “A or B?” must produce clickable A/B options;
  `attention.*` and `pause.request` are not substitutes.
- **Write a Command for a cold reader:** assume the operator has zero ticket
  context. Lead with the question, explain each option's consequence, name every
  referent, and state what happens without an answer.
- **Non-blocking questions keep work moving.** Set `blocking: false` when an
  answer is optional, record the question and raise its attention, then keep
  working. Never emit `pause.request` or stop your turn for that question.
  Explicit `operator_decision` pauses remain valid, including the legacy
  `attention.operator-decision` path. Expired or moot
  Commands cannot hold the worker waiting for human input.

## Default policy: keep the ticket moving

- **Decide, don't ask.** Before raising a Command, try to settle it yourself:
  try the options, measure them against the ticket, keep the best. When your
  Command would carry a low-risk recommendation, act on that recommendation
  instead and note it in the workpad. Ask only for what no default covers:
  missing credentials, writes outside your sandbox that block the whole ticket,
  or a contradiction in the ticket.
- **A blocker never stops you.** Declare a real dependency with
  `aiur_declare_blocker`, then keep working: do everything that doesn't need
  the blocker, and build on its pushed branch for what does. Never add an
  `agent:blocked` label or pause your ticket to wait for another one to merge.
- **Never idle.** When the ticket's own stop rule triggers, or a gate can't pass
  for a reason outside the ticket, open a draft PR that states the result, the
  failed gate and its cause. Then call
  `aiur_set_ticket_state({ "state": "human-review", "outside_blocker": "<cause>" })`
  and end the ticket. Turns that change nothing end in `agent:error`, which
  tells the reviewer less than a documented draft.
- **Push checkpoints, not early PRs.** While the work is unfinished, push to
  your branch. Mark a PR ready only when the work is done: in `ci-wait` the
  ticket gets no more turns until checks finish.
- **Retry transient tooling.** A `gh` call that times out is transient: retry it
  3 times about 2 minutes apart, then note it in the workpad and keep working.
  For other tooling failures, retry once, then use the nearest local
  alternative and note it.

## What stays in the per-turn prompt (not here)
Two protocols live in the per-turn shared prompt instead of this skill because
they fire between turns or must always be visible:

- The Executor-bar **`progress` / `progress.checkin`** estimate protocol.
- The **cross-ticket coordination reflexes** — declaring blockers before
  independent work, resuming only on an explicit `ticket.N.agent.unblocked`,
  and inspecting branch pushes before stacking.

Follow those from the prompt; use this skill for the event mechanics.
