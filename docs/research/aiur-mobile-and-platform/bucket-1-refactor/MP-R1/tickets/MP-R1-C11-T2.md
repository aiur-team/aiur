---
ticket_id: MP-R1-C11-T2
feature_id: MP-R1
chunk_id: MP-R1-C11
bucket: 1-refactor
title: Per-move plan refresh and ticket-start size-owner resolution (recurring runbook)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C11-T1]
prior_units: [U0, U8]
prior_boundaries: []
prior_features: []
prior_findings: []
size_owner: n/a (research docs only)   # this ticket is where RC-23 is implemented
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C11-T2 — Per-move plan refresh and ticket-start size-owner resolution

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C11.
- **User value:** every later-wave ticket (MP-R2 … MP-N7, and MP-R1's own later tickets)
  cites paths, lines, contract states and a size owner that are true at the moment an
  implementer picks it up. Nobody rediscovers what a refactor move changed.
- **Deliverable:** a recurring, owned procedure with two triggers:
  1. **After each MP-R1 move PR merges** (C5, C6, C7, C8, C9 tickets, and MP-R2/R5/R6/R7
     moves that change `components.json` paths): run the C11-T1 tool for
     `<previous refresh sha>..<merged main sha>` and update the affected tickets.
  2. **At ticket start (RC-23, binding):** before any MP ticket moves from `ready` to
     in-progress, resolve its `size_owner` against the **then-current** U8 ledger and
     record the result in the ticket.
- **Owner:** the coordinator or the Executor (plan.md §9 C11: "not an agent ticket
  alone"). A worker agent may run the tool and draft edits, but the Executor reviews
  and commits the ticket edits on the research branch.
- **Non-goals:** changing contracts (owners do that), re-deciding designs, editing
  `main`.

## Dependencies and blockers

- **DESIGN-R1** (feature gate), **MP-R1-C11-T1** (tool).
- **RC-23:** U8 ledger pinned at `465aca643`, pack pinned at `45a290e3`; each ticket
  resolves its size owner at start.
- **RC-19/RC-20:** when a move touches U2 paths (`orchestrator/issue_sync.ex`,
  `orchestrator/dispatch_policy.ex`) or U5 paths (`github/labels.ex`,
  `github/issues.ex`), the refresh must check that the MP-E1-C1 hooks still exist at the
  new head and that the build queue still calls the single label-writer seam; a missing
  hook is reported to the move ticket's owner as a regression, not silently re-pointed.
- **Concurrent:** runs alongside every move; one refresh at a time on the research
  branch (serialize to avoid edit conflicts in ticket files).

## Verified starting point

- Pack base `45a290e3`; U8 ledger `docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv`
  at `465aca643` (37 packages, 357 paths; `proposal.md`). U0 owns ledger refreshes and
  the transitional size gate (U0-U9 plan, U0 and U8 sections); MP tickets consume the
  ledger, they never edit it.
- Path map: [migration-plan.md §4](../migration-plan.md) PR-01 … PR-16 with the
  "Affects tickets of" column naming the dependent features.
- Ticket frontmatter fields to update: `base_sha`, `size_owner`, and the body's
  "Verified starting point" (phase-C instructions).

## Chosen design

### Procedure A — after a move merges

1. `python3 -I tools/plan_refresh.py --from <last refresh sha> --to <merged sha> ...`
   (C11-T1).
2. For each ticket listed with `MOVED`, `LINES-SHIFTED`, `LINES-CHANGED`, `GONE` or
   `SPLIT?`:
   - `MOVED`/`LINES-SHIFTED`: update the citation mechanically.
   - `LINES-CHANGED`/`SPLIT?`/`GONE`: re-read the code at the new head and update the
     "Verified starting point" prose; if the change invalidates the ticket's design,
     set the ticket `status: blocked` with `blocked_by: [REFRESH-<ticket>-<sha>]` and
     notify its feature owner.
   - Add a line at the end of "Verified starting point":
     `Refreshed against <sha> on <date> (MP-R1-C11-T2).` Do **not** change `base_sha`
     unless every citation in the ticket was re-verified at the new sha.
3. Update migration-plan.md §4: mark the merged row `moved (<sha>)` and fill the
   "Target" path with the real one.
4. Contract rows: if a contract changed status/date since the last refresh, list the
   tickets that cite it in the refresh report for the owner; do not edit contracts.
5. RC-19/RC-20 hook check (only when the diff touches the four files named above):
   `git -C <repo> grep -n <E1-C1 hook symbols> <sha> -- <files>` — the symbol list
   comes from the MP-E1-C1 ticket(s); empty result → report.
6. Commit the report under `refresh/<sha>.md` and the ticket edits in one research
   commit (coordinator commits).

### Procedure B — at ticket start (RC-23)

1. Identify the files the ticket will modify (its "Implementation steps" proposed file
   changes, plus cited files it edits).
2. For each file, count lines at the current `main` head (U0 counting rule: LF bytes,
   +1 for an unterminated last line). If ≤ 500 and the ticket's change keeps it ≤ 500:
   no size owner for that file.
3. Otherwise look the path up in the **current** U8 ledger (the newest ledger U0 has
   published; at research time that is the `465aca643` file above). Record
   `size_owner: <package> (<path>, <lines> lines at <sha>, ledger <ledger sha>)`.
   Not in the ledger → `UNASSIGNED`: ask U0 before editing; the ticket waits.
4. If the transitional size gate is installed on `main`, the ticket must not grow the
   file; write the no-growth constraint into the ticket's "Compatibility and rollout".
5. The C11-T1 tool's "Size owners" section does steps 2–3 automatically; the human
   does step 1 and 4.

## Implementation steps

1. Add the two procedures to the research pack's ticket README (coordinator's
   `tickets/README` for MP-R1 and the pack README) as the runbook, linking this ticket.
2. Run Procedure A once for `45a290e3..<current main>` as soon as C11-T1 exists, even
   before any MP-R1 move, to absorb drift since research.
3. Run Procedure B for every ticket as it becomes `ready`.

## Non-happy paths

- **Two moves merge close together:** run one refresh over the combined range; the tool
  is range-based.
- **Refresh lags:** an implementer who finds a stale citation runs Procedure A
  themselves for their ticket only and records it; the Executor folds it in.
- **Ledger refreshed by U0 with different package names:** use the new names; the
  mismatch report makes the change visible.
- **A move reverted:** the next range diff shows the reverse renames; apply them.
- **Research branch conflicts with concurrent ticket edits:** serialize refreshes
  (one writer), per the coordinator's commit ownership.

## Compatibility and rollout

Research-branch documentation process only. No `main` change.

## Verification

- After the first run, spot-check three refreshed tickets: every `path:line` citation
  resolves at the new sha (`git -C <repo> show <sha>:<path> | sed -n '<range>p'` shows
  the cited code).
- Re-run the tool for the same range after edits: the edited tickets report `OK`.
- Procedure B check: pick one ticket that touches an oversized file (for example
  MP-R1-C6-T3 on `src/lib/aiur.ex`, U8 `APP_BOOT`) and confirm the recorded size owner
  equals the ledger row at run time.
- No automated test beyond C11-T1's tool tests (this is a procedure).

## Completion and handoff

- [ ] Runbook text in the MP-R1 ticket README and pack README.
- [ ] First refresh run committed (`refresh/<sha>.md`).
- [ ] RC-23 step applied to every ticket that became `ready` since.
- [ ] Docs: n/a — research process.
- **Dependents:** MP-R1-C11-T3; every later-wave ticket (via Procedure B);
  MP-R1-C10-T1 (`features[].shipped_in` flips are part of Procedure A when a feature
  ships).
