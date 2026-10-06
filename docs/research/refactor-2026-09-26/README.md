# Refactor research — 2026-09-26

Research input for a large Aiur refactor: carving Aiur into sub-packages and
repositories, and fixing the root operational problem — **long gaps where
neither the Executor nor the agents make progress**, often as agents open pull
requests or time out.

## Questions

1. **Census** — how many tickets, pull requests, agent workspaces, agent
   sessions, Executor sessions, handoffs, `/aiur-meta` logs and retros exist
   per repository. (`census/`)
2. **Recurring problems** — a ranked taxonomy mined from Executor meta logs,
   retros and handoffs. (`meta/`)
3. **Idle gaps** — measured from wake streams, run telemetry, Executor
   transcripts and GitHub timelines; each gap attributed to a cause. (`gaps/`)
4. **Merged fixes** — which operational fixes held and which recurred.
   (`fixes/`)
5. **Agent failure modes** — what agents get stuck on, from their own session
   logs. (`agents/`)
6. **Feature boundaries** — a codebase survey and proposed package/repo
   boundaries. (`codebase/`)
7. **Code review** — a full review of the codebase for duplication,
   anti-patterns, large files, and unnecessary complexity, kept as a detailed
   findings list. (`review/`)
8. **Feature inventory** — every CLI command, config key, interface,
   integration and subsystem, with evidence of real use from configs,
   Executor transcripts and run logs, lines of code and tests per feature,
   and a keep / simplify / merge / cut / externalize recommendation. Every
   cut is challenged by a skeptic. Includes the line-count reduction case.
   (`features/`)

The goal: research the recurring bugs, feature boundaries and code size before
changing ownership. Package or repository splits remain conditional on a
measured benefit and a behavior-preserving seam.

## Code review method

The review reads a frozen snapshot of `main` at `3339b88` so line numbers stay
stable: 1,032 library files (262k lines), 866 test files (308k lines), plus the
website, launcher, scripts, skills and prompts — about 650k lines in 28 chunks.

1. **Review** — one reviewer per chunk, plus four cross-cutting duplication
   sweeps over all of `src/lib`: by function name, by normalized function
   body, by domain concept, and by duplicated constants and regexes.
2. **Verify** — every P0/P1 finding goes to two independent skeptics: one
   checks the cited lines say what is claimed, one checks it is a real problem
   at that severity. P2/P3 findings are marked unverified, not dropped.
3. **Completeness** — a critic finds unread files and unapplied lenses; its
   follow-ups are reviewed and verified the same way.
4. **Synthesize** — one deduplicated list grouped by category and by feature
   boundary, then a critic checks the report against the raw findings.

The brainstorm and plan built on this research live in `docs/brainstorms/`
and `docs/plans/`.

The [published 0.0.7 checkpoint](synthesis/merged-main-465aca-release-checkpoint.md)
records a complete `main@465aca643` text census, the 357 oversized paths and
current-source behavior gates. The [U8 package ledger](synthesis/u8-release-007/proposal.md)
assigns every oversized path one provisional writer. The earlier [b4bc review](synthesis/merged-main-b4bc-review.md)
records the dual P1 review. Each checkpoint is pinned; affected findings still
need implementation-head checks before code work.

## Relationship to the modular platform pack

A later pack, [aiur-mobile-and-platform](../aiur-mobile-and-platform/context-and-decisions.md)
(2026-10-06, base `45a290e3`), plans a modular platform, a build queue, command
escalation, conversations, voice, and mobile and watch apps (features MP-R1–R7,
MP-E1–E7, MP-N1–N7). It reuses this research rather than repeating it: its
[existing-refactor-research baseline](../aiur-mobile-and-platform/baseline/existing-refactor-research.md)
indexes these files, MP-R1 extends the 36-boundary map and carve order, and its
tickets cite this research's boundaries, findings and U8 size owners. The U0–U9
units stay as planned; the per-unit cross-references are in
[the plan](../../plans/2026-09-29-001-refactor-production-readiness-plan.md#relationship-to-the-modular-platform-pack).

## Starting inventory (measured 2026-09-26)

| Source | Size |
| --- | --- |
| Repositories with Executor state | aiur, archon, khala, architecture-docs, kevinweaver-dev (public); private-repo-a (private), private-repo-b (private) |
| `/aiur-meta` logs | aiur 93, archon 22 |
| Retros | aiur 39, khala 7, archon 6, architecture-docs 6 |
| Executor handoffs | khala 61, aiur 18, archon 5, architecture-docs 2 |
| Executor wake-stream records | aiur 4,749; khala 2,199; architecture-docs 1,881; archon 810; private-repo-a (private) 117 |
| Run log directories | 40 (865 MB) |
| Agent workspaces on disk | 26 GB |
| Codex sessions | 6,534 |

## Disclosure rules for this branch

This repository is public. Findings are committed with secrets redacted, and
content from the two private repositories — private-repo-a (private) and private-repo-b (private) — is
reported as counts and categories only, marked `(private)`,
never quoted.
