# Aiur Events — Attentions

`attention.<slug>` events surface a ❗ chip in the Executor’s agent list. They are how an agent says "I need the Executor to look at this before I can keep going."

The `agent.attention.*` family is **not** agent-exclusive. The orchestrator
also publishes into it — `attention.state_divergence`,
`attention.waiting_for_human` (and `.resolved`), `attention.error-<cause>`,
`attention.error-lifetime_latch`, and `attention.unsupported_model` — so a
subscriber to `ticket.<id>.agent.attention.#` sees orchestrator-authored
attentions alongside your own. Opening and closing the ❗ chips you author
works exactly as below; you don't resolve the orchestrator's. Your
`attention.resolved` only clears the slugs you opened, so keep your own
attention slugs distinct from system ones.

## Opening an attention

```jsonc
{
  "name": "attention.scope-question",
  "message": "OK to namespace blocker tools under aiur_* prefix?",
  "payload": { "context": "U13 design — see thread", "alternatives": ["aiur_block_on", "declare_blocker"] }
}
```

When this fires:

- ❗ appears in the second emoji slot on your row in the agent list
- If multiple attentions are open, it renders as `❗N`
- The Executor can press `Enter` on your row to expand the open-attentions detail (slug + message + timestamp)

## Closing an attention

When the question is resolved (Executor replied via PR comment, you decided yourself, the blocker resolved), emit:

```jsonc
{
  "name": "attention.resolved",
  "message": "Decided to use aiur_* prefix per Executor’s reply on PR #99",
  "payload": { "slug": "scope-question" }
}
```

The `payload.slug` **must match** the slug from the original `attention.<slug>`. Otherwise the ❗ doesn't clear.

## Reflexes

- **Don't let attentions accumulate.** If you've opened more than 2, you're either using attentions for things they're not for, or you've forgotten to close ones the Executor already answered.
- **Resolve before unrelated work.** If an attention is open, prefer to close it before starting unrelated work — the Executor is waiting.
- **The Executor does NOT clear attentions for you.** Opening the pane, reading the chip, replying — none of that clears the ❗. Only your `attention.resolved` clears it.

## Executor’s view

When ❗ shows up, the Executor typically:

1. Presses `Enter` on your row to see the message
2. Goes to your PR and leaves a comment with the answer
3. (Doesn't need to do anything in Aiur — your next turn will pick up the new comment as an event and you decide to resolve)
