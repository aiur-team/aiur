---
design_task: DESIGN-E3
feature_id: MP-E3
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-E3 implementation ticket (MP-E3-C1..C7)
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

1. **Harness order.** Claude first and Codex later, or both before release? (Codex reading depends on research RQ-E3-1/2.)
2. **Default listener mode for the Executor.** D13 says `sync` is the default. Is that right for the Executor, or should it default to `steer`?
3. **Content shown by default.** Messages only, or also reasoning and tool calls/output (collapsed)?
4. **Phone/watch visibility.** Pairing grants full access (D19). Should the Executor transcript be readable on paired devices by default, or need its own toggle?
5. **Takeover.** Allowed from the dashboard, or CLI only?
6. **Executor progress as a jump point.** Should the aiur-run skill emit an `executor.progress` event on its progress-table cadence so it appears as a jump point?
7. **Blockers scope.** Executor Commands + `aiur ask` items only, or also fleet-level blockers (tracker auth failed, GitHub connectivity lost)?
8. **Terminology.** "Executor", "Executor session", "attached", "detached" — confirm or rename.

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
- Decisions 1–8 in §3 are answered in writing.
- The opt-in story is explicit about what aiur reads (your session transcript)
  and where it stores it (locally, owner-only).
- Kevin writes "DESIGN-E3 approved" on the research PR or in
  `context-and-decisions.md`.

## 6. Not in scope

- Pause, resume, interrupt or spawn controls for the Executor (D15: controls
  stay where they are).
- Replacing Claude Remote Control. It keeps working.
- Multiple concurrent Executor conversations per instance.
