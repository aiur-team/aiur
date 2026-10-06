---
design_task: DESIGN-R7
feature_id: MP-R7
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-R7 implementation ticket (MP-R7-C1..C6)
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
   package move (C4)?  [ ] yes  [ ] also require a full dogfood run.
2. The `aiur-claude` sibling's `turn/steer` appears to drop text (R7 plan
   F7). It is unused today. File it now on the sibling repo, or leave it
   for MP-E7?  [ ] file now  [ ] leave for E7.

## 3. States

No new screens or states. Contributor documentation (C6) is the only
written change.

## 4. Acceptance

Complete when every § 1 box is approved and § 2 answers are recorded.
