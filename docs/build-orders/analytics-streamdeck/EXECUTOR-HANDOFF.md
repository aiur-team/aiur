# Executor handoff

Canonical handoff: `docs/executor/analytics-streamdeck-handoff.md` (authority
envelope, launch command, hazards, monitoring). This pack adds:

- Build Order: its-everdred/aiur:analytics-streamdeck, plan v1.
- Selector: the 26 GitHub issues in README.md's mapping table (root issue
  links them all).
- Source precedence: operator decisions > research docs (approved intent) >
  GitHub ticket facts > Aiur runtime state > this pack's prose.
- Discovery policy: P0/P1 acceptance blockers may be promoted; contained
  findings return to the owning ticket; P2/P3 stay in deferred-findings.md.
  Freeze creation if created outpaces completed.
- Terminal condition: build-order.json feature_boundary.completion_condition.
- Next agent: use aiur-run; write a 3-5 sentence goal restating Executor role,
  authority, selector, terminal condition, immediate actions.
