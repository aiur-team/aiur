---
name: aiur-agent
description: "The operating manual for an Aiur agent working a ticket. Use at the start of every Aiur ticket turn — covers the agent:* label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, the Agent Workpad template, milestone alerts (emit_alert), complexity routing, the dev loop / commit / PR conventions, and cross-ticket event coordination."
---

# Operating as an Aiur agent

This skill is how an Aiur agent runs a ticket end to end. The per-turn prompt
carries only your ticket + workspace context and a pointer here; everything
about *how* to operate — the ticket workflow, the dev loop, complexity routing,
conventions, and cross-ticket events — lives in the reference docs below. Read
the one that matches what you're doing; you don't need all nine every turn.

## When to use what

| You want to... | Read |
|----------------|------|
| Run a turn: labels, the Agent Workpad, the brainstorm→plan→work→review loop, which CE skill when, milestone alerts | `turn-workflow.md` |
| Branch, commit, push, open + self-review the PR, docs requirement, manual CLI verification, PR description shape | `dev-loop.md` |
| Pick model / agent / skill depth from the `complexity:N` label | `complexity-routing.md` |
| Know whose comments are authoritative, file out-of-scope findings, follow tooling + load-repro conventions | `conventions.md` |
| Understand what events are and why they exist | `overview.md` |
| Know which event names are allowed and what they mean | `event-taxonomy.md` |
| Emit an event or subscribe to a topic pattern | `emit-and-subscribe.md` |
| Open / close an Executor attention | `attention-and-resolve.md` |
| Unblock yourself temporarily with a stub | `stub-then-fetch.md` |

## The shortest version

- Move the issue to `agent:in-progress` and keep one `## Agent Workpad` comment
  current. When implementation and draft-PR self-review are complete, move to
  `agent:ci-wait` and end the turn; after the delivered pass result, mark the PR
  ready and flip to `agent:human-review`. Do **not** self-merge — always await
  human review.
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
- Branch freshness is your responsibility. Before handing the PR to CI or
  human review, and again after rework, fetch its configured base and ensure
  the current remote base head is an ancestor of your exact PR head. Integrate
  or re-cut and resolve semantic drift yourself; the Executor and reviewers do
  not update stale code for you.
- **Events:** `emit_event(name, message, payload?)` publishes to
  `ticket.<id>.agent.<name>` against the allowlist in `event-taxonomy.md`.
  `aiur_declare_blocker(N)` auto-subscribes you to a useful subset of
  `ticket.N.*`; `blocked` / `unblocked` are single-attempt, fire-and-forget
  readiness signals.
- **Ask a bounded operator question with a Decision:** emit `decision.requested`
  with structured `options` and a recommendation before any attention or pause.
  A question phrased as “A or B?” must produce clickable A/B options;
  `attention.*` and `pause.request` are not substitutes.

## What stays in the per-turn prompt (not here)

Two protocols live in the per-turn shared prompt instead of this skill because
they fire between turns or must always be visible:

- The Executor-bar **`progress` / `progress.checkin`** estimate protocol.
- The **cross-ticket coordination reflexes** — declaring blockers before
  independent work, resuming only on an explicit `ticket.N.agent.unblocked`,
  and inspecting branch pushes before stacking.

Follow those from the prompt; use this skill for the event mechanics.
