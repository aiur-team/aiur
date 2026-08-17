---
name: aiur-agent
description: "Cross-ticket event publishing + subscription system for Aiur agents. Use when working in Aiur on a ticket and you need to emit, subscribe to, or react to events from other tickets — coordination signals, blocker declarations, attentions, progress milestones."
---

# Aiur Events

When you're working on an Aiur ticket and another ticket might need a signal from you, or you need a signal from them, the events system is how. Read the four reference docs in this skill in the order that matches what you're trying to do.

## When to use what

| You want to... | Read |
|----------------|------|
| Understand what events are and why they exist | `overview.md` |
| Know which event names are allowed and what they mean | `event-taxonomy.md` |
| Emit an event or subscribe to a topic pattern | `emit-and-subscribe.md` |
| Open / close an Executor attention | `attention-and-resolve.md` |
| Unblock yourself temporarily with a stub | `stub-then-fetch.md` |

## Quick reference

- **Emit:** `emit_event(name, message, payload?)` — name must be in the allowlist (`event-taxonomy.md`)
- **Subscribe to a pattern:** `aiur_subscribe(topic_pattern)` — watch one literal ticket with AMQP suffix wildcards, such as `ticket.42.#` or `ticket.42.branch.*`
- **Declare a blocker:** `aiur_declare_blocker(issue_number)` — auto-subscribes you to a useful default subset
- **Open an attention:** `emit_event("attention.<slug>", "what you need")`; close it with `attention.resolved` + `payload: {slug: "<the-slug>"}`
- **Ask a bounded operator question:** emit `decision.requested` with structured `options` and a recommendation before any attention or pause. A question phrased as “A or B?” must produce clickable A/B options; `attention.*` and `pause.request` are not substitutes.
- **Write a Command for a cold reader:** assume the operator has zero ticket context. Lead with the question, explain each option's consequence, name every referent, and state what happens without an answer.

Tools fail loudly with structured errors — if you call `emit_event("system.foo", ...)` you'll get back a `event_name_not_in_allowlist` payload listing the valid forms.
Agent-created subscriptions fail before binding unless they begin with
`ticket.<literal-id>.`; `executor.*`, `system.*`, bare wildcard, and wildcard
ticket-id patterns are reserved or too broad for ticket agents.
