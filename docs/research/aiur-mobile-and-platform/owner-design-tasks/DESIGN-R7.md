---
design_task: DESIGN-R7
feature_id: MP-R7
owner: Kevin
status: open (awaiting explicit approval)
blocks: [MP-E7-C4-T01, MP-R7-C1-T01, MP-R7-C1-T02, MP-R7-C1-T03, MP-R7-C1-T04, MP-R7-C2-T01, MP-R7-C2-T02, MP-R7-C2-T03, MP-R7-C3-T01, MP-R7-C3-T02, MP-R7-C3-T03, MP-R7-C3-T04, MP-R7-C3-T05, MP-R7-C3-T06, MP-R7-C4-T01, MP-R7-C4-T02, MP-R7-C4-T03, MP-R7-C4-T04, MP-R7-C4-T05, MP-R7-C5-T01, MP-R7-C5-T02, MP-R7-C6-T01]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R7 (waived entries excluded). Earlier wording: every MP-R7 implementation ticket (MP-R7-C1..C6)"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R7/plan.md
linked_design_tasks: DESIGN-E7 (listener-mode selector; the first user-visible use of the adapter's capabilities)
---

# DESIGN-R7 — Kevin: confirm that the harness-adapter extraction changes nothing you see

**MP-R7 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [ ] **No change in how a message reaches an agent.** Each path keeps its
  current behaviour (R7 plan finding F3):
  - dashboard drawer, Stream Deck and `aiur message` interrupt the active
    turn and deliver next;
  - `POST /api/v1/:id/messages` waits for the next checkpoint;
  - the TUI chat pane lets the backend decide (immediate for `claude-repl`,
    checkpoint otherwise);
  - Command answers interrupt, falling back to the next turn.
  (Changing these is MP-E7, gated by DESIGN-E7.)
- [ ] **No change to backend names or config.** `agent.routing` values
  (`codex`, `claude`, `claude-repl`, `muse`, `kimi`, `deepseek`,
  `openrouter`, `+remote`), model labels, `aiur init` backend choices and
  install hints stay identical.
- [ ] **No change to Remote Control**, the TUI `r` key, pane Ctrl+C, pause
  and resume.
- [ ] **No change to skills installed into workspaces** (`.claude/skills`,
  `.codex/skills` link, `.agents/skills`).
- [ ] **Packaging.** The npm `aiur-cli` install and `aiurdev build` produce a
  release that runs every backend as before. No new install step.

## 2. Decisions needing your input

1. Is a foreground manual run (one Codex and one Claude agent, a chat-pane
   message to each, per AGENTS.md "Manual testing") enough proof for the
   package move (C4)? Recommended: **yes**, because it exercises both delivery
   families through the real TUI, which is the AGENTS.md definition of manual
   testing.  [ ] yes  [ ] also require a full dogfood run.
2. The `aiur-claude` sibling's `turn/steer` appears to drop text (R7 plan
   F7). It is unused today. File it now on the sibling repo, or leave it
   for MP-E7? Recommended: **file now**, because a working `turn/steer` is a
   precondition of MP-E7-C4.  [ ] file now  [ ] leave for E7.

## 3. States

No new screens or states. Contributor documentation (C6) is the only
written change.

## 4. Acceptance

Complete when every § 1 box is approved and § 2 answers are recorded.
