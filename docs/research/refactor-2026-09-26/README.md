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

The brainstorm and plan built on this research live in `docs/brainstorms/`
and `docs/plans/`.

## Starting inventory (measured 2026-09-26)

| Source | Size |
| --- | --- |
| Repositories with Executor state | aiur, archon, khala, architecture-docs, private-multisig; croptracker and kevinweaver-dev also have `.aiur/` |
| `/aiur-meta` logs | aiur 93, archon 22 |
| Retros | aiur 39, khala 7, archon 6, architecture-docs 6 |
| Executor handoffs | khala 61, aiur 18, archon 5, architecture-docs 2 |
| Executor wake-stream records | aiur 4,749; khala 2,199; architecture-docs 1,881; archon 810; private-multisig 117 |
| Run log directories | 40 (865 MB) |
| Agent workspaces on disk | 26 GB |
| Codex sessions | 6,534 |

## Disclosure rules for this branch

This repository is public. Findings are committed with secrets redacted, and
content from private repositories is reported as counts and categories only,
never quoted.
