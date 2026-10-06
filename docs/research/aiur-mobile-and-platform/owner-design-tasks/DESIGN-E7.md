---
design_task: DESIGN-E7
feature_id: MP-E7
owner: Kevin
status: open (awaiting explicit approval)
blocks: [MP-E3-C5-T01, MP-E4-C6-T01, MP-E7-C1-T01, MP-E7-C1-T02, MP-E7-C1-T03, MP-E7-C1-T04, MP-E7-C1-T05, MP-E7-C2-T01, MP-E7-C2-T02, MP-E7-C2-T03, MP-E7-C2-T04, MP-E7-C2-T05, MP-E7-C3-T01, MP-E7-C3-T02, MP-E7-C3-T03, MP-E7-C3-T04, MP-E7-C3-T05, MP-E7-C4-T01, MP-E7-C4-T02, MP-E7-C4-T03, MP-E7-C4-T04, MP-E7-C5-T01, MP-E7-C5-T02, MP-E7-C5-T03, MP-E7-C5-T04, MP-E7-C6-T01, MP-E7-C6-T02, MP-E7-C6-T03, MP-E7-C6-T04, MP-E7-C7-T01, MP-E7-C7-T02, MP-E7-C7-T03, MP-E7-C7-T04, MP-E7-C7-T05]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-E7 (waived entries excluded). Earlier wording: every MP-E7 implementation ticket (MP-E7-C1..C7); C1 Khala tickets also need E7-D1"
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
   (`AgentPresencePanel.tsx:139`). Recommended: **the conversation drawer
   header, plus a read-only mode badge on the unit row**, because a mode change
   is made while reading the conversation and the row only needs to show it.
2. **Requested versus effective.** How the UI shows that a harness cannot do
   the requested mode (for example `async` on `claude-repl`, which has no
   pull path), and the reason.
3. **Delivery status of each sent message:** accepted, waiting for turn end
   (sync), held for the agent to read (async), handed to the agent, in
   context, read, failed, outcome unknown (contract §7).
4. **Async unread count** per agent, and what the operator sees after
   switching away from async (E7-D4).
5. **CLI:** command name and output for get/set mode, and how
   `aiur message` reports which mode applied. Recommended: **`aiur listen-mode
   <ticket> [steer|sync|async]`** (the MP-E7-C7 draft), and `aiur message`
   prints the mode that applied.
6. **TUI:** whether the AgentList shows the mode and whether a key changes it.
   Recommended: **show it; no key in v1**, because the TUI already has a dense
   key map and the dashboard and CLI can change it.
7. **Executor composer** (with DESIGN-E3): same selector, or a fixed mode?
   Recommended: **the same selector**, with the default from E7-D8.

Surfaces affected: dashboard (`/`, conversation drawer, `/chat/...`), TUI
AgentList and chat pane, CLI, HTTP API errors. Stream Deck and phone/watch:
no selector unless you ask; their sends follow the agent's mode.

## 2. Decisions needing your input

- **E7-D1 (MP-Q1).** Accept that the "one shared package" is a versioned spec
  + TypeScript reference + conformance fixtures, homed and published from
  the Khala repo, with aiur implementing it in Elixir? Recommended: **accept**,
  because a spec plus fixtures shares behaviour without a runtime dependency
  (RC-36: the router stays in core and the spec is a build-time input).
  [ ] accept  [ ] other home: ____
- **E7-D2.** On harnesses with no non-cancelling mid-turn input (headless
  Claude today), offer `steer` as "steer (interrupts current turn)" — which
  is today's dashboard behaviour — or hide/disable steer there?
  Recommended: **offer, labelled**, because it is today's behaviour and
  disabling it would remove a working path.
  [ ] offer, labelled  [ ] disable with reason
- **E7-D3.** Who may change a worker's mode? Recommended: **human and Executor,
  audited**, because the Executor already steers workers and every change is
  recorded with its actor. [ ] human only  [ ] human and Executor (audited)
- **E7-D4.** After `async → sync/steer`, unread messages. Recommended: **notice
  only**, because a sudden batch of old messages would land as one confusing turn.
  [ ] notice only, bodies stay pull-only (proposed)  [ ] skip silently
  (Khala)  [ ] deliver as one batch
- **E7-D5.** Mode lifetime: [ ] per ticket run, survives respawn and
  restart (proposed)  [ ] per agent session. This answer blocks MP-E7-C2-T01 by name
  (Phase D). Recommended: **per ticket run**, because a respawn or restart
  should not silently reset a mode you chose.
- **OWNER-NPM-FIRST-PUBLISH** (Phase D, from MP-E7). The first npm publish of the new
  Khala listener package needs owner setup: an npm trusted publisher for the new package
  name. MP-E7-C1-T03 cannot run before it. Recommended: **set up trusted
  publishing**, because it avoids a long-lived npm token in CI.
  [ ] set up  [ ] publish another way: ______
- **E7-D6.** Default change: today the dashboard, Stream Deck and
  `aiur message` interrupt the active turn. With `sync` as default they will
  wait for the turn to end. Recommended: **accept, and add a per-message "send
  now" (which is `steer` for that one message)**, because `sync` stops surprise
  interrupts while "send now" keeps today's urgent path. Until answered, E7-C3
  ships behind a flag that keeps today's behaviour (RC-05).
  [ ] accept  [ ] keep a per-surface "send now"
  override (which is `steer` for that one message)
- **E7-D7.** Is a global default-mode config key wanted (for example
  `agent.listen_mode`), or is per-agent setting enough? Recommended: **per-agent
  is enough for v1**, because no key is needed while the default is fixed by
  D13 and E7-D8; a key can be added without breaking anything.
  [ ] per-agent only  [ ] add a global key
- **E7-D8 Default listener mode for the Executor** (Phase D; **this gate owns
  the question**, DESIGN-E3 decision 2 links here). D13 makes `sync` the
  default. Options: (a) `sync` for the Executor too; (b) `steer` for the
  Executor only, workers stay `sync`. Recommended: **(b)**, because the
  Executor runs long monitoring turns, so `sync` could hold your message for a
  whole loop, and you usually message the Executor to redirect it now.
  [ ] (a) sync  [ ] (b) steer for the Executor

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
- Answers to every decision in § 2 recorded here: E7-D1…E7-D8 and
  OWNER-NPM-FIRST-PUBLISH.
- Explicit written approval from Kevin. Until then, every MP-E7 ticket stays
  blocked and no implementer chooses copy, placement or defaults.
