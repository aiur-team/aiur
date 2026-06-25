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

- Move the issue to `agent:in-progress`, keep one `## Agent Workpad` comment
  current, and flip to `agent:human-review` when the PR is ready for review. Do
  **not** self-merge — always await human review.
- Right-size the CE loop to the work: large asks usually run
  `ce-brainstorm → ce-plan → ce-work → ce-code-review`; smaller asks may skip
  brainstorm, plan, or review, but err on the side of using them when in doubt.
- The branch is exactly `aiur/<issue-number>` — never invent another name.
- Every PR description starts with `Closes #<issue>`. Commit messages are short
  (3–7 words), plain, and human — never mention AI, Claude, Codex, or models.

## What stays in the per-turn prompt (not here)

Two protocols live in the per-turn shared prompt instead of this skill because
they fire between turns or must always be visible:

- The operator-bar **`progress` / `progress.checkin`** estimate protocol.
- The **`/aiur-agent`** pointer and the cross-ticket coordination reflexes.

Follow those from the prompt; use the `aiur-agent` skill for the cross-ticket
event mechanics.
