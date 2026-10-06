---
ticket_id: MP-R1-C11-T1
feature_id: MP-R1
chunk_id: MP-R1-C11
bucket: 1-refactor
title: Plan-refresh tool — path map, stale citations and size owners between two commits
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T1]
prior_units: [U0, U8]
prior_boundaries: []
prior_features: []
prior_findings: []
size_owner: n/a (new research-branch tool)   # re-resolve at ticket start against the current U8 ledger (RC-23)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C11-T1 — Plan-refresh tool

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C11 (plan refresh; brief §2 Phase D:
  "Include a plan-refresh task where the eventual refactor changes paths or contracts;
  do not make implementers rediscover that mapping").
- **User value:** after each refactor move merges, the Executor runs one command and
  gets (a) the regenerated path map (migration-plan.md §4 rows PR-01 … PR-16), (b) every
  ticket citation in the research pack that the move made stale, and (c) every
  ticket whose `size_owner` no longer matches the current U8 ledger. Later-wave
  implementers start from correct paths.
- **Deliverable:** `docs/research/aiur-mobile-and-platform/tools/plan_refresh.py`
  (PROPOSED, **research branch only**) plus a fixture test, producing a Markdown report.
- **Non-goals:** editing tickets automatically (C11-T2 is the human/Executor sweep);
  any change on `main`; contract version bumps (reported, not edited).

## Dependencies and blockers

- **DESIGN-R1** (feature gate).
- **MP-R1-C1-T1** (`components.json` with `paths` per component). Before C1-T1 exists
  the tool can still run in file mode (rename detection only), so development may start
  earlier; the component-level map needs C1-T1.
- **RC-23** (binding): the U8 ledger is pinned at `465aca643` while the pack is pinned
  at `45a290e3`; size owners are resolved at ticket start against the then-current
  ledger. This tool implements that lookup.
- **Concurrent:** everything; it reads only.

## Verified starting point

- **Where tickets live:** the research pack is on branch `research/refactor-findings`
  (worktree `.worktrees/refactor-census-ed742`), not on `main`; `45a290e3` (pack base)
  is not an ancestor of that branch (`git merge-base --is-ancestor 45a290e3 HEAD` fails),
  and research was removed from `main` by PR #2921 (component-directory.md §1). Both
  commits are in the same repository object store, so `git show <sha>:<path>` reads
  `main` commits from the research worktree.
- **Decision — tool location: research branch, not `main`.** Reasons: its only inputs
  besides git are research files (tickets, migration plan, U8 ledger); a script on
  `main` would reference paths that do not exist on `main`, need its own docs/CI under
  AGENTS.md rules, and serve no operator. Rejected: `scripts/` on `main`.
- Path map today: [migration-plan.md §4](../migration-plan.md) (16 rows, PR-01 … PR-16),
  hand-written at `45a290e3`.
- U8 ledger: `docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv`,
  header `path,release_lines,package,frozen_owner,frozen_disposition,confidence`, 357
  rows, pinned at `465aca643` (proposal.md line 3). Its generator is `build.py` in the
  same directory.
- Ticket frontmatter fields the tool reads: `ticket_id`, `base_sha`, `size_owner`,
  `blocked_by` (phase-C instructions). Citations appear as `` `path:line` `` or
  `` `path:start-end` `` in backticks, and `path` alone.

## Chosen design

```text
python3 -I docs/research/aiur-mobile-and-platform/tools/plan_refresh.py \
    --repo <aiur repo or worktree> --from 45a290e3 --to <new main sha> \
    --pack docs/research/aiur-mobile-and-platform \
    --u8-ledger <path to current assignments.csv> \
    --out docs/research/aiur-mobile-and-platform/refresh/<to-sha>.md
```

Algorithm (all reads through `git -C <repo>`; never `cd`):

1. **Component path map.** `git show <from>:components.json` and `<to>:...` (or the
   `components/*.json` layout). For each component ID, diff `paths`; emit
   `component | old globs | new globs`. Missing at `<from>` (pre-C1) → file mode only.
2. **File moves.** `git diff --name-status -M50% <from> <to> -- src packages packaging
   website scripts` → `R<score> old new`, `D old`, `A new`.
3. **Path-map rows.** For each PR-xx row in migration-plan.md §4, expand its "Today"
   glob at `<from>` (`git ls-tree -r --name-only <from>`), follow step-2 renames, and
   report the files' new locations and owning component at `<to>`. Row status:
   `moved`, `partly moved`, `unchanged`, `deleted`.
4. **Stale citations.** Scan every `*.md` in the pack for backticked repository paths
   matching `^(src|packages|packaging|website|scripts|\.github)/` with optional
   `:N` or `:N-M`. For each:
   - path deleted → `GONE`; renamed → `MOVED old → new`;
   - line range: compute `git diff -U0 <from> <to> -- <path>` hunks; any hunk
     overlapping or preceding the range → `LINES-SHIFTED` (report the new range by
     applying the hunk offsets) or `LINES-CHANGED` (hunk overlaps the range);
   - else `OK`.
   Group by ticket ID (from the file's frontmatter).
5. **Size owners (RC-23).** For each ticket, collect cited paths that are > 500 lines at
   `<to>` (count `\n` bytes + 1 for an unterminated last line, as the U0 gate does).
   Look each up in `--u8-ledger`: report `package`; compare with the ticket's
   `size_owner`. Outcomes: `MATCH`, `MISMATCH (ledger says X)`, `UNASSIGNED (>500,
   not in ledger — ask U0)`, `NO-LONGER-OVERSIZED`.
6. **Contract rows.** Report the `status`, `base_main_sha` and `date` frontmatter (the fields the contracts carry today; there is no `version` field) of
   `contracts/identity-and-capabilities.md`, `events-and-replay.md`,
   `command-request-and-resolution.md`, `conversations-transcripts-anchors.md` at the
   time of the run (migration-plan.md §4 contract rows); it does not judge them.
7. Write the report; exit 0 always unless git fails (exit 2). It is a report, not a
   gate.

Report sections: Summary counts · Component path map · PR-xx rows · Stale citations
by ticket · Size owners by ticket · Contract versions.

## Implementation steps

1. Write `plan_refresh.py` (stdlib only: `subprocess`, `csv`, `json`, `re`,
   `pathlib`, `fnmatch`). Target ≤ 400 lines; split into `plan_refresh/` modules if it
   grows (no file over 500 lines, U8 rule; prefer ≤ 200).
2. Write `tools/test_plan_refresh.py` (`unittest`) that builds a throwaway git repo in
   a temp dir with two commits (a rename, a line insertion above a cited range, a
   deletion, a file growing past 500 lines) and a mini pack with two tickets.
3. Run against `45a290e3..45a290e3` (expect all `OK`, no moves) and against the first
   merged MP-R1 move to sanity-check.
4. Add a short usage note at the top of the script (no separate README; the C11-T2
   ticket is the runbook).

## Non-happy paths

- **Manifest absent at `<from>`** (before C1-T1): component sections say "manifest
  absent at <from>"; file-level sections still run.
- **Ambiguous rename** (a file split into several): `git diff -M` reports at most one
  target; the tool also lists `A` files whose names share the old basename stem and
  marks the citation `SPLIT?` for a human.
- **Citation inside a code block that is not a path** (for example a URL fragment):
  restrict to the path regex above; false positives are listed under "unresolved".
- **Ledger missing or a different header:** exit 2 with a clear message; never
  silently report every ticket as `UNASSIGNED`.
- **Untrusted inputs:** the tool reads repository data only; run with `python3 -I`
  from outside the repo directory (environment note on interpreters).

## Compatibility and rollout

Research tooling only. No `main` change, no CI. Rollback: delete the tool.

## Verification

`python3 -I tools/test_plan_refresh.py` cases:

| Test | Setup | Expected | Fails without |
|---|---|---|---|
| `rename_marks_moved` | `git mv a.ex b.ex` | citation `a.ex:3` → `MOVED a.ex → b.ex` | step 4 rename branch |
| `insert_above_shifts_lines` | 2 lines inserted above `:10-12` | `LINES-SHIFTED :12-14` | hunk offset logic |
| `edit_inside_range_flags_changed` | edit line 11 | `LINES-CHANGED` | overlap check |
| `deleted_file_gone` | `git rm` | `GONE` | delete branch |
| `size_owner_mismatch` | file grows to 501 lines; ledger says `WEB`, ticket says `n/a` | `MISMATCH (ledger says WEB)` | step 5 |
| `size_500_is_not_oversized` | exactly 500 lines | not listed | boundary (`>` vs `>=`) |
| `unassigned_oversized` | 600-line file absent from ledger | `UNASSIGNED` | ledger miss branch |
| `bad_ledger_exits_2` | header mismatch | exit 2 | header validation |

Mutation check: apply each "fails without" mutation, confirm the test fails, restore.

## Completion and handoff

- [ ] Tool and test on the research branch; test green.
- [ ] One sample report committed under `refresh/` for `45a290e3..<first move>`.
- [ ] Docs: n/a — research tooling, not a product surface.
- **Dependents:** MP-R1-C11-T2, MP-R1-C11-T3.
