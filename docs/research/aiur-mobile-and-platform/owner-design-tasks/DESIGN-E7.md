---
design_task: DESIGN-E7
feature_id: MP-E7
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-E7 implementation ticket (MP-E7-C1..C7); C1 Khala tickets also need E7-D1
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-2-platform/MP-E7/plan.md
contract: ../contracts/listener-mode.md
shared_with: DESIGN-E3 (Executor composer indicator; default mode for the Executor), DESIGN-E4 (delivery indicator on the composer), DESIGN-E5 (voice sends go through the mode), DESIGN-N6 (phone/watch replies go through the mode)
---

# DESIGN-E7 — Kevin: design and approve listener-mode selection and status

**MP-E7 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What you need to design

1. **Mode selector per agent** (`steer`, `sync`, `async`; default `sync`).
   Where it lives: unit row in the fleet table, conversation drawer header,
   composer, or more than one. Khala's copy for reference: "Steer ·
   interrupts", "Sync · next turn", "Async · on demand"
   (`AgentPresencePanel.tsx:139`).
2. **Requested versus effective.** How the UI shows that a harness cannot do
   the requested mode (for example `async` on `claude-repl`, which has no
   pull path), and the reason.
3. **Delivery status of each sent message:** accepted, waiting for turn end
   (sync), held for the agent to read (async), handed to the agent, in
   context, read, failed, outcome unknown (contract §7).
4. **Async unread count** per agent, and what the operator sees after
   switching away from async (E7-D4).
5. **CLI:** command name and output for get/set mode, and how
   `aiur message` reports which mode applied.
6. **TUI:** whether the AgentList shows the mode and whether a key changes it.
7. **Executor composer** (with DESIGN-E3): same selector, or a fixed mode?

Surfaces affected: dashboard (`/`, conversation drawer, `/chat/...`), TUI
AgentList and chat pane, CLI, HTTP API errors. Stream Deck and phone/watch:
no selector unless you ask; their sends follow the agent's mode.

## 2. Decisions needing your input

- **E7-D1 (MP-Q1).** Accept that the "one shared package" is a versioned spec
  + TypeScript reference + conformance fixtures, homed and published from
  the Khala repo, with aiur implementing it in Elixir?
  [ ] accept  [ ] other home: ____
- **E7-D2.** On harnesses with no non-cancelling mid-turn input (headless
  Claude today), offer `steer` as "steer (interrupts current turn)" — which
  is today's dashboard behaviour — or hide/disable steer there?
  [ ] offer, labelled  [ ] disable with reason
- **E7-D3.** Who may change a worker's mode? [ ] human only  [ ] human and
  Executor (audited)
- **E7-D4.** After `async → sync/steer`, unread messages:
  [ ] notice only, bodies stay pull-only (proposed)  [ ] skip silently
  (Khala)  [ ] deliver as one batch
- **E7-D5.** Mode lifetime: [ ] per ticket run, survives respawn and
  restart (proposed)  [ ] per agent session
- **E7-D6.** Default change: today the dashboard, Stream Deck and
  `aiur message` interrupt the active turn. With `sync` as default they will
  wait for the turn to end. [ ] accept  [ ] keep a per-surface "send now"
  override (which is `steer` for that one message)
- **E7-D7.** Is a global default-mode config key wanted (for example
  `agent.listen_mode`), or is per-agent setting enough?

## 3. States to design

| State | Where | Notes |
| --- | --- | --- |
| Loading | selector | mode record not yet read |
| Default (sync, never changed) | selector | distinguish "default" from "chosen sync"? |
| Pending change | selector | until the change event confirms (Khala uses 15 s) |
| Conflict | selector | another device changed it first (409); show the winner |
| Effective ≠ requested | selector, composer | reason text |
| Steer emulated by interrupt | selector, composer | only if E7-D2 = offer |
| Agent not running | selector, composer | mode kept for the ticket; sends refused today (`:no_running_agent`) |
| Agent paused | composer | messages wait for resume |
| Async unread N | unit row, drawer | count, and "read by agent" transition |
| Delivery receipts | message bubble | accepted / waiting / held / handed / in context / read / failed / unknown |
| Offline / daemon unreachable | selector, composer | stale data marked with age (AGENTS.md "If a surface computes an age, it renders the age") |
| Permission denied | selector | read-only dashboard without credentials |
| Error | selector, composer | write failed; retry |

## 4. Acceptance conditions

- Screens or interaction sketches for § 1 items 1–7 and every § 3 state.
- Copy for the three modes, the effective-mode reasons and each receipt.
- Answers to E7-D1…D7 recorded here.
- Explicit written approval from Kevin. Until then, every MP-E7 ticket stays
  blocked and no implementer chooses copy, placement or defaults.
</content>
</invoke>
