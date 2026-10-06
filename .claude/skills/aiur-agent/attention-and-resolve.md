# Aiur Events — Attentions

`attention.<slug>` events surface a ❗ chip in the Executor’s agent list. They
ask the Executor to look at the ticket. Aiur also projects them as legacy
Commands with `human_required` and `irreversible` policy. The Executor cannot
answer those Commands with `executor-answer`, even when the text asks only for
an observed fact.

When you need an **answer**, emit `decision.requested` instead. For a factual
observation such as "Did the consent page open on the retry?", use
`kind: "factual_observation"`, `authority: "supervisor_allowed"`, and
`reversibility: "reversible"`, with a free-text question and enough context to
identify the retry. This lets the Executor give a redacted observation through
`executor-answer --custom-response`. Keep product policy, spend, publication,
and irreversible actions `human_required` and escalate them to the human.
If you also need a ❗ chip, emit the attention first, then immediately emit
`decision.requested` with the same `attention_slug` to enrich its legacy
Command with the correct policy before asking for an answer.

```jsonc
{
  "name": "decision.requested",
  "message": "Did discovery consent open and complete on the retry?",
  "payload": {
    "kind": "factual_observation",
    "authority": "supervisor_allowed",
    "reversibility": "reversible",
    "blocking": true,
    "context": { "short_summary": "Report the redacted observed outcome of the owner's retry." }
  }
}
```

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
  "name": "attention.retry-status",
  "message": "Investigating why the approved retry did not open consent",
  "payload": { "context": "No answer is needed yet" }
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
- **Generic attentions do not expire automatically.** The Executor does not clear them for you; emit a matching `attention.resolved` when the question is resolved.
- **Configured-base CI attentions are condition snapshots.** Slugs `<base>-red`, `<base>-ci-red`, and `<base>-ci-red-<detail>` expire at the first re-ask after 15 minutes without a fresh assertion. This applies to live attentions and restored attentions after restart. If the branch is still red, emit the same `attention.<slug>` again; each assertion restarts the 15-minute window. Expiry emits the matching `.resolved` event.

## Executor’s view

When ❗ shows up, the Executor typically:

1. Presses `Enter` on your row to see the message
2. Goes to your PR and leaves a comment with the answer
3. (Doesn't need to do anything in Aiur — your next turn will pick up the new comment as an event and you decide to resolve)
