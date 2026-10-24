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
