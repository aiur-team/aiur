---
name: using-aiur
description: "The operating manual for an Aiur agent working a ticket. Use at the start of every Aiur ticket turn — covers the agent:* label lifecycle, the brainstorm→plan→work→review turn workflow and which CE skill to use when, the Agent Workpad template, milestone alerts (emit_alert), complexity routing, and the dev loop / commit / PR conventions."
---

# Operating as an Aiur agent

This skill is how an Aiur agent runs a ticket end to end. The per-turn prompt
carries only your ticket + workspace context and a pointer here; everything
about *how* to operate lives in these reference docs. Read the one that matches
what you're doing — you don't need all four every turn.

## When to use what

| You want to... | Read |
|----------------|------|
| Run a turn: labels, the Agent Workpad, the brainstorm→plan→work→review loop, which CE skill when, milestone alerts | `turn-workflow.md` |
| Branch, commit, push, open + self-review the PR, manual CLI verification, PR description shape | `dev-loop.md` |
| Pick model / agent / skill depth from the `complexity:N` label | `complexity-routing.md` |
| Know whose comments are authoritative, file out-of-scope findings, follow tooling + load-repro conventions | `conventions.md` |
| Emit, subscribe to, or react to **cross-ticket** events | the **`aiur-agent`** skill |

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
- Every PR description starts with `Closes #<issue>`. Commit messages are short
  (3–7 words), plain, and human — never mention AI, Claude, Codex, or models.
- Branch freshness is your responsibility. Before handing the PR to CI or
  human review, and again after rework, fetch its configured base and ensure
  the current remote base head is an ancestor of your exact PR head. Integrate
  or re-cut and resolve semantic drift yourself; the Executor and reviewers do
  not update stale code for you.

## What stays in the per-turn prompt (not here)

Two protocols live in the per-turn shared prompt instead of this skill because
they fire between turns or must always be visible:

- The Executor-bar **`progress` / `progress.checkin`** estimate protocol.
- The **`/aiur-agent`** pointer and the cross-ticket coordination reflexes.

Follow those from the prompt; use the `aiur-agent` skill for the cross-ticket
event mechanics.
