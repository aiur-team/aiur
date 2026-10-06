---
ticket_id: MP-E3-C7-T02
feature_id: MP-E3
chunk_id: MP-E3-C7
bucket: 2-platform
title: "Docs and skills: Executor conversation concepts, privacy statement, aiur-run/aiur-intro opt-in"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T03, MP-E4-C8-T02]
prior_units: [U9]
prior_boundaries: [n/a]
prior_features: [MP-E4 (concepts/conversations.md)]
prior_findings: [AGENTS.md "Docs ship with the change"; DESIGN-E3 acceptance "the opt-in story is explicit about what aiur reads"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C7-T02 — Executor conversation docs and skills

## Identity and outcome

- Bucket 2 · MP-E3 · C7 · T02.
- **User value:** the operator knows, before opting in, exactly what aiur reads
  (their own session transcript), where it keeps it (locally, owner-only), what
  it writes (project-local Claude hook settings, or nothing for Codex), and how
  to undo it.
- **Deliverable:** a "Talk to the Executor from the dashboard" section in
  `website/docs-app/concepts/executor.md`; links to `concepts/conversations.md`
  (MP-E4-C8-T02); `.claude/skills/aiur-run/SKILL.md` and
  `.claude/skills/aiur-intro/SKILL.md` mention the opt-in in one paragraph each.
- **Non-goals:** CLI reference (C1-T03, C4-T05, C7-T01 own their rows).

## Dependencies and blockers

- DESIGN-E3 (terminology, decisions 1–8 answered). MP-E3-C1-T03 (commands
  exist), MP-E4-C8-T02 (conversations page to link).

## Verified starting point

- `website/docs-app/concepts/executor.md` has sections "Who drives", "Executor
  surfaces", "Keeping tickets moving" (`:1-24` headings).
- Skills: `.claude/skills/aiur-run/SKILL.md`, `.claude/skills/aiur-intro/SKILL.md`
  (AGENTS.md "Orientation"); the docs page for skills is
  `website/docs-app/skills.md`.

## Chosen design

Section outline (≤ 80 lines): what it is (no Remote Control needed); opt in
(`aiur executor-attach --harness claude|codex`, Codex trust step); what aiur
reads and stores (the attached session's transcript, copied into the local
journal, owner-only, kept per DESIGN-E4 retention); what it writes
(`.claude/settings.local.json` marked entries; token/URL files under the
executor state dir); sending messages (listener modes, link to DESIGN-E7 docs
when they exist; "disabled until delivery is installed"); status and blockers;
opt out (`aiur executor-detach`, what remains on disk and how to delete it);
phone visibility per DESIGN-E3 decision 4.

## Implementation steps

1. Page section; 2. skill paragraphs; 3. `skills.md` one line if it summarizes
   skill content; 4. docs build `env -C website/docs-app bun run build`.

## Non-happy paths

- If DESIGN-E3 chooses print-only install, the page must not claim aiur writes
  settings.

## Compatibility and rollout

n/a — documentation.

## Verification

- Docs build passes; reviewer greps every path and command in the section
  against the merged code. Mutation check: n/a.

## Completion and handoff

- [ ] Section, skill paragraphs, links merged.
