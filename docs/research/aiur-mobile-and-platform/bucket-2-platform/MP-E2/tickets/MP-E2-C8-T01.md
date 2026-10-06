---
ticket_id: MP-E2-C8-T01
feature_id: MP-E2
chunk_id: MP-E2-C8
bucket: 2-platform
title: Concept docs for routing, escalation, native questions and supersede
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T03, MP-E2-C3-T03, MP-E2-C4-T04, MP-E2-C6-T02]
prior_units: [U6]
prior_boundaries: [DOCS]
prior_features: [MP-N4/N5 (link to the human-needed event)]
prior_findings: [AGENTS.md "Docs ship with the change" (behaviour pages), contract §4–§8]
size_owner: "DOCS (concepts/commands.md 68; concepts/executor.md 32 — both small)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C8-T01 — Concept docs for routing, escalation, native questions and supersede

## Identity and outcome

- Bucket 2, MP-E2, chunk C8 (docs and rollout).
- **User value:** an operator can read, in one place, who is asked first, when a Command
  becomes theirs, what happens to an agent's own question, and when they can still replace
  an answer.
- **Deliverable:** updated `website/docs-app/concepts/commands.md` and
  `concepts/executor.md`. Reference pages (`configuration.md`, `cli.md`) are updated by the
  tickets that add each key/command (C1-T02, C2-T04, C2-T05, C4-T02, C4-T05, C5-T02,
  C6-T01, C6-T03, C7-T04); this ticket only verifies they are present and consistent.
- **Non-goals:** skills (C8-T02/T03).

## Dependencies and blockers

- DESIGN-E2 approved copy (terms "Needs you", chip names, cause names).
- Behaviour tickets merged: C2-T03, C3-T03, C4-T04, C6-T02 (the docs must not describe
  unmerged behaviour — a wrong doc is worse than a missing one).

## Verified starting point (`45a290e3`)

- `website/docs-app/concepts/commands.md` (68 lines), `concepts/executor.md` (32 lines),
  `reference/cli.md` (416), `reference/configuration.md` (860), `skills.md` (106);
  `guide/gui.md:28-39` (Commands rows).
- Sidebar `website/docs-app/.vitepress/config.ts` — no new page, so no sidebar change.

## Chosen design

`concepts/commands.md` gains sections (prose, no new page):

1. **Who is asked** — the contract §4 table in operator words.
2. **When a Command becomes yours** — causes (approved names), default timeouts and the
   `decisions.escalation.*` keys (link to configuration), "no re-ask", expiry wins.
3. **Native questions** — Codex/Claude opt-in gates, hold vs release, secrets never
   collected, approvals unaffected (D10).
4. **Answering and replacing** — first answer wins, Replace until delivered, Send
   correction, the Executor never replaces your answer.
5. **The Executor asks you** — `aiur command request`, answers on `executor-wait`.

`concepts/executor.md`: acknowledgement (`executor-ack`), deadlines, asking the human.

## Implementation steps

1. Edit the two concept pages.
2. Cross-check every key/command named exists in `configuration.md` / `cli.md` (grep).
3. `npm --prefix website run build` (or the docs build command in `website/package.json`)
   to catch broken links.

## Non-happy paths

n/a — documentation only; risk is inaccuracy, handled by the dependency on merged
behaviour and the grep check.

## Compatibility and rollout

n/a — docs.

## Verification

```bash
git grep -n -E "decisions\.escalation|decisions\.native_capture|require_suggested_responses" -- website/docs-app/reference/configuration.md
git grep -n -E "executor-ack|command request" -- website/docs-app/reference/cli.md
python3 scripts/check-config-docs.py
```

Expected: every key and command named in the concept pages has a reference entry;
`check-config-docs.py` passes. Mutation check: n/a (no code). Reviewer reads the page
against the merged behaviour.

## Completion and handoff

- [ ] Two concept pages updated; reference entries verified present.
- Dependents: none.
