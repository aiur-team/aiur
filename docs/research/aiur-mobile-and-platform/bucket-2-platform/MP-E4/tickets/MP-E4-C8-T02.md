---
ticket_id: MP-E4-C8-T02
feature_id: MP-E4
chunk_id: MP-E4-C8
bucket: 2-platform
title: "Concepts page: conversations, where transcripts live, retention, secrets, jump-point precision"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C1-T03]
prior_units: [U9]
prior_boundaries: [n/a]
prior_features: []
prior_findings: [AGENTS.md "Docs ship with the change"; contract conversations-transcripts-anchors §6, §10, §12]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C8-T02 — Conversations concepts page

## Identity and outcome

- Bucket 2 · MP-E4 · C8 · T02.
- **User value:** the operator knows that every conversation is kept on this
  machine, where, how big it gets, that it may contain secrets, and how to delete
  one by hand.
- **Deliverable:** `website/docs-app/concepts/conversations.md` and its sidebar
  entry; cross-links from `guide/gui.md` (C5-T04) and `concepts/executor.md`
  (MP-E3-C7-T02).
- **Non-goals:** API reference (C2-T02 documents routes in `guide/gui.md`).

## Dependencies and blockers

- DESIGN-E4 decisions 4 (masking) and 5 (retention) set the page's claims.
- MP-E4-C1-T03 (behaviour exists to document); MP-E4-C1-T00 (measured size).
- Ships in the same PR as C1-T03 if that PR is the first user-visible change
  (the journal directory appears on disk); otherwise right after.

## Verified starting point

- Concepts pages: `website/docs-app/concepts/{executor,units,commands,build-orders,ticket-lifecycle,operating-aiur,message-bus}.md`;
  sidebar entries `website/docs-app/.vitepress/config.ts:146-152`. AGENTS.md: a
  new page must be added to the sidebar.
- Storage root: `Paths.decision_state_dir/0` = `$AIUR_BG_STATE_DIR` (default
  `<cwd>/.aiur-state`) `/<AIUR_INSTANCE_KEY>/<project>` (`config/paths.ex:322-357`);
  conversations under `conversations/` (C1-T01).

## Chosen design

Page outline (≤ 150 lines, plain language, STE style as the other concepts pages):

1. **What a conversation is** — one per worker ticket and one for the Executor;
   sessions inside it; positions.
2. **Where it lives** — the directory, file names, owner-only permissions; it is
   outside the workspace and survives workspace removal and daemon restarts.
3. **How big it gets** — the measured bytes/hour/agent from MP-E4-C1-T00 with its
   date, and the body bound ("middle of very long outputs is not stored").
4. **Retention** — per DESIGN-E4 decision 5 (expected: kept until you delete it).
   How to delete: stop the daemon, remove `<…>/conversations/<conversation_id>/`.
5. **Secrets** — transcripts may contain secrets an agent printed; masking
   behaviour per decision 4; never commit or share the directory.
6. **Jump points** — kinds (C4-T01 table) and precision: exact, linked to a
   command, approximate, not linked; why some events have no position.
7. **Imported history** — what "Earlier history is not available" and imported
   sessions mean (C8-T01).
8. **Alerts** — `system.conversation.journal.degraded` and what to do.

## Implementation steps

1. Write the page; add `{ text: 'Conversations', link: '/concepts/conversations' }`
   to the concepts sidebar group.
2. Link from `guide/gui.md` "Conversations" and `concepts/units.md`.
3. Build the docs site locally to check the sidebar link:
   `env -C website/docs-app bun run build` (`vitepress build .`,
   `website/docs-app/package.json:8`; the app ships a `bun.lock`).

## Non-happy paths

- If DESIGN-E4 chooses masking, the page must not claim transcripts are
  secret-free; masking is display-time only.

## Compatibility and rollout

n/a — documentation.

## Verification

- Docs build passes; the sidebar shows the page; every path in the page matches
  the code (reviewer check: the directory name and alert name grep-match
  `paths.ex` and `journal.ex`).
- Mutation check: n/a (no test).

## Completion and handoff

- [ ] Page + sidebar + cross-links merged.
- Dependents: MP-E3-C7-T02 (links here for the Executor privacy statement).
