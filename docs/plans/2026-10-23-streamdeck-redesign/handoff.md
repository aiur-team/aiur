# Executor handoff

- **Feature:** `streamdeck-redesign`, plan_version 1, researched at `6a7d6b445`.
- **Plan:** `docs/plans/2026-10-23-001-feat-streamdeck-redesign-plan.md`.
- **Selector:** label `feature:streamdeck-redesign`; epic issue below.
- **Source precedence:** Kevin's decisions of 2026-10-23 → ticket issues on GitHub (after
  filing, edits go to the issue, not to this pack) → Aiur runtime state → this pack.
- **Disposition at filing:** every member `agent:parked`, `priority:3`. Scheduled just before
  MP-N per Kevin 2026-10-23; promote when MP-E2/E3/E4 and the current build order are mostly
  done. On promotion run continuous-build intake (`aiur feature create`, `aiur feature add`,
  enqueue) and staff SD-101 first, then SD-201 and SD-102.
- **Before promotion:** park #5181 and redirect PR #5284 (Q1); ask #5998/#5999 owners for the
  server blocks first (Q2).
- **Feature boundary:** ends when SD-901 merges. Voice (SD-407/SD-408) may stay open behind
  MP-E6 (Q7).
- **Discovery policy:** P0/P1 acceptance blockers return to the owning SD ticket. P2/P3 and
  optimizations go to `deferred-findings.md`. Do not grow the ticket set otherwise.
- **Integration owner:** SD-901.

## Logical ID to issue map

| ID | Issue |
|----|-------|
| SD-101 | #6025 |
| SD-102 | #6026 |
| SD-103 | #6027 |
| SD-104 | #6028 |
| SD-105 | #6029 |
| SD-201 | #6030 |
| SD-202 | #6031 |
| SD-203 | #6032 |
| SD-204 | #6033 |
| SD-205 | #6034 |
| SD-206 | #6035 |
| SD-207 | #6036 |
| SD-301 | #6037 |
| SD-302 | #6038 |
| SD-303 | #6039 |
| SD-304 | #6040 |
| SD-401 | #6041 |
| SD-402 | #6042 |
| SD-403 | #6043 |
| SD-404 | #6044 |
| SD-405 | #6045 |
| SD-406 | #6046 |
| SD-407 | #6047 |
| SD-408 | #6048 |
| SD-901 | #6049 |

Epic: #6024 (sub-issue of #5840). Plan PR: #6023. Filed 2026-10-23 with `agent:parked`,
`needs-triage`, `priority:3`, `feature:streamdeck-redesign`, `area:*`, `complexity:N` and
`phase:N`. `needs-triage` is there because the repository's issue-disposition guard (#1793)
accepts only `agent:todo`, `agent:queued`, `human:todo`, `needs-triage`, `build-order` or
`epic` as a disposition, so `agent:parked` alone is refused. Remove `needs-triage` at promotion.

Native edges written: 82 `blocked_by` (in-set edges from `graph.json` plus #5589, #5945,
#5998, #5999, #4142, #4145, #5729). All 25 members are sub-issues of #6024.

From here on, edits go to the issues, not to this pack.
