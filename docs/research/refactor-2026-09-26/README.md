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

The goal: research issues, the feature list and improvements before a full
rewrite that fixes the recurring bugs, reduces line count, and decomposes Aiur
into smaller packages and repositories.

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

## Starting inventory (measured 2026-09-26)

| Source | Size |
| --- | --- |
| Repositories with Executor state | aiur, archon, khala, architecture-docs, kevinweaver-dev (public); private-multisig (private), croptracker (private) |
| `/aiur-meta` logs | aiur 93, archon 22 |
| Retros | aiur 39, khala 7, archon 6, architecture-docs 6 |
| Executor handoffs | khala 61, aiur 18, archon 5, architecture-docs 2 |
| Executor wake-stream records | aiur 4,749; khala 2,199; architecture-docs 1,881; archon 810; private-multisig (private) 117 |
| Run log directories | 40 (865 MB) |
| Agent workspaces on disk | 26 GB |
| Codex sessions | 6,534 |

## Disclosure rules for this branch

This repository is public. Findings are committed with secrets redacted, and
content from the two private repositories — private-multisig (private) and croptracker (private) — is
reported as counts and categories only, marked `(private)`,
never quoted.
