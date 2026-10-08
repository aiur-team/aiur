---
ticket_id: MP-R2-C4-T05
feature_id: MP-R2
chunk_id: MP-R2-C4
bucket: 1 (refactor; docs)
title: Document the bus placement rule and durability classes in concepts/message-bus.md (existing behaviour only)
status: ready
blocked_by: [DESIGN-R2 §1]
prior_units: [U9]
prior_boundaries: [BUS #10, docs-site #40]
prior_features: []
prior_findings: [MP-R2 F1, F2, F5]
size_owner: n/a (message-bus.md 106 lines; stays < 200)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C4-T05 — `message-bus.md`: placement rule and durability classes

## Identity and outcome

- **Bucket 1, MP-R2, chunk C4.** Documentation of behaviour that already
  exists at `45a290e3`; no product change.
- **Value.** Operators and agent authors learn which events can be relied
  on after a restart and which cannot, and contributors learn where a new
  fact goes (Exchange vs PubSub). Today the page says only "Events are
  signals; consumers follow validated references or correlation fields to
  the durable source of truth" (`message-bus.md:14`).
- **Deliverable.** Two short sections added to
  `website/docs-app/concepts/message-bus.md` and one corrected sentence.
- **Non-goals.** Nothing about the proposed export feed, `seq`, `gap`,
  `reset` or `events.export.*` (C5–C7 are off by default and not shipped;
  documenting them now would describe a surface that does not exist).
  Those docs ship with C6-T01/C7 tickets.

## Dependencies and blockers

- DESIGN-R2 §1 only. It documents behaviour true at `45a290e3` and stays
  true after C1–C4 (they preserve behaviour), so it can merge before, during
  or after C2. Concurrent with everything.

## Verified starting point (45a290e3)

| Fact to document | Evidence |
| --- | --- |
| Page: 106 lines; sections Topic shape, Agent events, Tracker and repository events, Automatic subscriptions, Manual subscription scope, Dependencies, Commands and decisions, GitHub observation | `website/docs-app/concepts/message-bus.md:1-106` |
| Sidebar entry exists | `website/docs-app/.vitepress/config.ts:152` |
| Opening sentence says the exchange is for "durable coordination" — but most topics are not durable (F1) | `message-bus.md:3` vs `src/lib/aiur/issue_log.ex:545-560,573-581` |
| Ids: unique per instance, restart-safe, gaps allowed, not a delivery order | `src/lib/aiur/events/id_generator.ex:1-56,83-85`; `exchange.ex:93-108` |
| Agent-emitted events are kept per ticket only with a trusted identity while the ticket's writer exists | `issue_log.ex:545-560,616-621`; `agent_runner/tool_executor.ex:123,441` |
| GitHub/CI/PR events are live only; an agent restarted later does not replay them | `agent_runner/bootstrap_digest.ex:74-92,106-126`; F1 |
| Executor stream `executor.*` is journaled and replayed from a watermark | `executor_events.ex:63-75,143-154`; `executor_listener.ex:44-75` |
| Executor wakes for non-`executor.*` topics published while the listener is down are lost | `executor_listener.ex:144-178` |
| Command lifecycle: DecisionStore persists, then publishes with the durable id, then PubSub | `decision_store.ex:2552-2575,4603-4618` |
| Alerts are also recorded in the alert ledger | `alerts.ex:191-197` |
| Only Exchange → PubSub bridges exist (`TicketActivity`, `TicketHistoryProvider`, `DecisionMetrics`) | inventory §6; C1-T05 `placement_rule_test.exs` |

## Chosen design

Edits (plain language, tables like the rest of the page, no internal
module names except where the page already uses them):

1. Line 3: "Aiur uses a shared topic exchange to signal coordination
   between tickets, agents, and the Executor." ("durable" removed: it is
   false for most topics.)
2. New section **"What survives a restart"** after "Topic shape":

| Class | Topics | After a restart or disconnect |
| --- | --- | --- |
| Live | GitHub, CI, PR and branch events (`ticket.<id>.pr.*`, `.ci.*`, `.branch.push`, `.issue.commented`, `system.<branch>.branch.push`) | Not replayed. Consumers re-read GitHub or the tracker. |
| Logged | Events an agent emits for its own ticket (`ticket.<id>.agent.*`) | Kept in that ticket's event log while Aiur tracks the ticket; replayed to the agent on its next turn. |
| Ledgered | Alerts and attentions (`ticket.<id>.agent.attention.*`, `system.*` alerts) | Kept in the alert feed; not replayed as events. |
| Journaled | Executor stream (`executor.*`) and Command lifecycle | Written before delivery; the Executor replays from its cursor. |

   Plus two sentences: "Event IDs are unique per instance and increase in
   the order they are assigned, not the order they are delivered; use them
   to deduplicate, not to sort." and "Wakes for non-Executor topics that
   arrive while the Executor listener is down are not replayed; read
   `aiur status` and the tracker after a restart."
3. New section **"Where a new fact goes"** (for contributors) after
   "GitHub observation": four bullets — coordination fact with identity or
   routing → topic exchange; "re-read X" notifications → PubSub with a
   version, never truth; persist first, then publish with the durable id,
   then notify (Commands are the example); bridges run exchange → PubSub
   only. Link: "Signals, not state — see the opening rule."

## Implementation steps

1. Edit `message-bus.md` as above (≈35 added lines; page stays < 200).
2. Docs build (command below) to catch link and markdown errors.
3. No sidebar change (page exists).

## Non-happy paths

- If a C2/C3 PR merged first and changed behaviour (it must not), the
  table would be wrong: the reviewer re-checks each row's evidence at the
  merge head.
- If DESIGN-R2 owner wording changes "live/logged/ledgered/journaled",
  use the approved words here and in the contract.

## Compatibility and rollout

Docs only. Rollback: revert.

## Verification

- Each table row re-verified at the merge head with the evidence column
  (record `git show <head>:<path> | sed -n` outputs for the four class rows
  in the PR body).
- Docs build, as the `website` workflow runs it
  (`.github/workflows/website.yml:50-54`):
  `env -C website/docs-app bun install --frozen-lockfile && env -C website/docs-app bun run build`.
- Rendered check: open the built page locally and confirm both tables
  render (screenshot in the PR body).
- No automated test; no mutation check applies (docs).

## Completion and handoff

- [ ] Line 3 corrected; two sections added; evidence re-checked at head.
- [ ] Docs build green; page screenshot attached.
- AGENTS.md "Docs ship with the change": this is the docs-only half for
  C1–C4; C6-T01 and C7-T01..T04 carry their own `configuration.md` /
  `cli.md` rows.
- Dependents: contract §6 and this page must agree; C4-T04 checks both.
