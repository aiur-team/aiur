---
design_task: DESIGN-E3
feature_id: MP-E3
owner: Kevin
status: open (awaiting explicit approval)
blocks: [MP-E3-C1-T01, MP-E3-C1-T02, MP-E3-C1-T03, MP-E3-C1-T04, MP-E3-C2-T01, MP-E3-C2-T02, MP-E3-C3-T02, MP-E3-C3-T03, MP-E3-C4-T01, MP-E3-C4-T02, MP-E3-C4-T03, MP-E3-C4-T04, MP-E3-C4-T05, MP-E3-C5-T01, MP-E3-C6-T01, MP-E3-C6-T02, MP-E3-C6-T03, MP-E3-C7-T01, MP-E3-C7-T02, MP-E5-C5-T02, MP-E7-C6-T01, MP-E7-C6-T03, MP-N1-C4-T06, MP-N3-C4-T03]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-E3 (waived entries excluded). Earlier wording: every MP-E3 implementation ticket (MP-E3-C1..C7)"
shared_with: DESIGN-E4 (conversation rendering, composer, event navigation), DESIGN-E7 (mode selector), DESIGN-E2 (Command cards), DESIGN-E5 (mic on the composer), DESIGN-N3 (Executor status on the meta-dashboard)
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-2-platform/MP-E3/plan.md
related_contract: ../contracts/conversations-transcripts-anchors.md
---

# DESIGN-E3 — Kevin: design and approve the Executor conversation surface and its opt-in

**Implementation of MP-E3 is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's explicit
written approval.

## 1. What you are designing

Today the only way to talk to the Executor away from its terminal is Claude
Remote Control. MP-E3 adds an aiur-native Executor view in the dashboard: the
Executor's conversation, its status, its blockers and background agents, and a
message box. The Executor is your own external Claude Code or Codex session, so
aiur only sees it after you **opt in** by installing hooks.

The conversation itself (entry rendering, event jump points, history paging,
composer and delivery states) is the same component as worker conversations,
designed in **DESIGN-E4**. This task designs what is Executor-specific.

## 2. Surfaces

| Surface | Exists today? | What you design |
| --- | --- | --- |
| Dashboard Executor view (route proposed `/executor`) | No | Layout, header, panels, how it differs visually from a worker conversation. |
| Entry point from the dashboard | No | Where the Executor is reached (nav item, header chip, units table row). Brief §3: on the phone the Executor chat is secondary, not the landing view. |
| Executor status header | No (CLI has `aiur status`, `executor-roster`) | Which fields show, order, compact form for MP-N3. |
| Blockers panel | Partly (Commands inbox for workers) | How Executor-originated Commands and `aiur ask` items look here vs the Commands inbox. |
| Background agents panel | No | Rows for subagents/tasks: name/type, running/finished, last message. |
| Composer | Drawer composer exists for workers | Executor-specific copy; listener-mode indicator (from DESIGN-E7). |
| Opt-in / setup | No | CLI output of `aiur executor-attach --check`, plus the dashboard "not attached" state with setup steps. |
| Takeover | No | Whether the dashboard can replace a live attached session, and its confirmation. |

## 3. Decisions that need your input

Plan IDs are shown beside each question (MP-E3 plan §10 numbers them differently;
tickets cite the plan ID).

1. **Harness order** (= OQ-E3-1). Claude first and Codex later, or both before release?
   (Codex reading depends on research RQ-E3-1/2.) Recommended: **Claude first**, because
   Codex transcript reading still waits on RQ-E3-1/2 and should not hold the Claude path.
2. **Default listener mode for the Executor** (= OQ-E3-3). **Answered in
   [DESIGN-E7 E7-D8](DESIGN-E7.md#2-decisions-needing-your-input)**, which owns every
   listener-mode default; this gate only shows the result in the composer.
3. **Content shown by default** (= OQ-E3-4). Messages only, or also reasoning and tool
   calls/output (collapsed)? Recommended: **messages plus collapsed tool calls; reasoning
   hidden**, the same default as DESIGN-E4 decision 3, so the Executor view and worker
   views read alike.
4. **Phone/watch visibility** (= OQ-E3-2). Pairing grants full access (D19). Should the
   Executor transcript be readable on paired devices by default, or need its own toggle?
   Recommended: **readable by default**, because D19 already grants full access and a
   separate toggle would imply a protection that pairing does not give.
5. **Takeover** (= OQ-E3-5). Allowed from the dashboard, or CLI only? Recommended: **CLI
   only in v1**, because replacing a live session is rare and destructive, and the CLI is
   where the session runs.
6. **Executor progress as a jump point** (= OQ-E3-6). Should the aiur-run skill emit an
   `executor.progress` event on its progress-table cadence so it appears as a jump point?
   Recommended: **yes**, because progress tables are the Executor's natural chapter marks.
7. **Blockers scope.** Executor Commands + `aiur ask` items only, or also fleet-level
   blockers (tracker auth failed, GitHub connectivity lost)? Recommended: **include
   fleet-level blockers**, because they are what actually stops the Executor.
8. **Terminology.** "Executor", "Executor session", "attached", "detached" — confirm or
   rename. Recommended: **confirm**, because "Executor" is already the term in the skills
   and the CLI.
9. **Hook install on attach** (Phase D, CR-E3-8; blocks MP-E3-C1-T04). For Claude, should
   `aiur executor-attach` write the hooks into the repository's `.claude/settings.local.json`
   automatically (proposed), or only print them for you to install? Codex is print-only
   either way, because its hook trust is interactive. Recommended: **install
   automatically**, because `settings.local.json` is per-user and gitignored, and a printed
   snippet is the most common setup mistake. [ ] install automatically  [ ] print only

## 4. States to design

| State | Meaning | Must show |
| --- | --- | --- |
| Not opted in | No hooks installed / never attached | Plain explanation, the one command to attach, link to docs. Never looks like "idle". |
| Attached, waiting for first hook | Hooks installed, no event yet (Codex hooks may need trust in the TUI) | "Waiting for the Executor session" + `--check` hint. |
| Loading history | Backfill in progress | Progress or skeleton; partial history marked partial. |
| Working | Executor mid-turn | Activity indicator, last activity age. |
| Waiting for input | Executor asked a question or is at a prompt | Prominent; links the Command if one exists. |
| Idle | Turn finished, session alive | Last activity age. |
| Unknown / stale | No hook inside the TTL | "Status unknown, last seen N min ago". Must never read as idle. |
| Ended / detached | Session ended or expired | Final state; history still readable. |
| Session boundary | `/clear`, compaction, resume, takeover | Divider in the conversation. |
| Background agents unsupported | Harness has no subagent hooks | "Not available for this harness", never "0". |
| Input unavailable | No proven listener route, or E7 not installed | Composer disabled with the reason. |
| Read-only dashboard | `observability.dashboard_writable` false | Read everything; no composer, no answers. |
| Transcript unreadable | File moved or unreadable | Error with the reason; status may still work. |
| Permission denied | Not authenticated | Standard dashboard auth. |
| Message queued / delivered / failed / unknown | From DESIGN-E4 delivery states | Same visuals as workers. |

## 5. Acceptance conditions

- Every state in §4 has a screen or explicit spec, including copy.
- The Executor view is visually distinct from a worker conversation but uses
  the DESIGN-E4 entry rendering.
- Every decision in §3 is answered in writing (1 and 3–9 here, including 9 hook install;
  2 in DESIGN-E7 E7-D8).
- The opt-in story is explicit about what aiur reads (your session transcript)
  and where it stores it (locally, owner-only).
- Kevin writes "DESIGN-E3 approved" on the research PR or in
  `context-and-decisions.md`.

## 6. Not in scope

- Pause, resume, interrupt or spawn controls for the Executor (D15: controls
  stay where they are).
- Replacing Claude Remote Control. It keeps working.
- Multiple concurrent Executor conversations per instance.
