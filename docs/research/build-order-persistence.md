# Planning draft — persistent build orders

Status: **PLANNING — do not file tickets from this yet** (operator, 2026-08-01).
Prematurely filed as #1448 and withdrawn; this draft is the live version.
Refs #1363, #1444, #1445.

## Problem

Two invisibility failures in the 2026-07 run, same shape:

- The active pack lived at `docs/build-orders/.../build-order.json` on a
  research branch. The daemon discovers packs from `.aiur/build_orders/`
  of its own checkout — the run's own build order never rendered on the
  dashboard.
- The research docs lived on the same research branch. Agents work in
  workspaces cloned from the base branch — tickets cited
  `docs/research/*` files the implementing agents did not have.

Both artifacts were parked where their consumers never look.

## Design (current draft)

### Storage — consolidate per-repo state under `~/.aiur/repo/<owner>/<repo>/`
(operator decision, 2026-08-01)

The repo node stops being the clone itself and becomes the parent of all
per-repo state:

```
~/.aiur/repo/<owner>/<repo>/
  latest/                # the warm base clone (pre-warm target) moves here
  builds/
    <slug>/
      build-order.json   # canonical pack; what discovery reads
      status.json        # daemon-written: per-member state, progress %, active|completed
```

- One node per repo holds everything; an org rename is a single `mv`
  carrying clone and builds together — kills the orphaned-state class
  (the stale `.aiur-base-built` on the dead `its-everdred/` path is what
  masked #1404 for ~8 sessions).
- Build state lives OUTSIDE the git working tree, ending the sidecar
  leak class (`.aiur-base-built` was committed into two PRs this week).
- The existing in-tree sidecars (`.aiur-base-built`, `.aiur-hex`,
  `.aiur-mix`, `.aiur-npm-cache`) should migrate to siblings of
  `latest/` in a follow-up so the working tree is purely the repo.
- Requires a `RepoBase.base_path` change (`<node>` -> `<node>/latest`)
  plus a one-time migration: move existing clones down into `latest/`,
  import the two known packs into `builds/`, delete the orphaned
  pre-rename `its-everdred/aiur` node.
- Repo-local `.aiur/build_orders/` remains a shadowing dev override;
  `/aiur-build` writes to the global store by default.
- Discovery glob: `~/.aiur/repo/*/*/builds/*/build-order.json` (or via
  the configured tracker repo directly).
- Multi-instance safety: a daemon writes `status.json` only for packs
  whose `repository` matches its configured tracker repo.

### Listing — one list, current highlighted (operator decision)

All build orders for the repo in a single list; most entries will be past
runs. Active pack highlighted and pinned to top; completed sorted by
completion date. **No separate archive section, no `_archive/` dir** —
status lives in the pack/`status.json`.

### Planning docs — split by consumer, branch-agnostic (operator decision)

| Artifact | Consumer | Home |
|---|---|---|
| Pack | daemon/dashboard | global store |
| Ticket contracts | agents via tracker | GitHub issues |
| Research/planning docs | agents in workspaces, reviewers, future Executors | **the target repo's base branch** |

Planning ends with a **planning PR** landing the research docs on the
repo's base branch *before* the first implementation ticket dispatches,
so every agent workspace contains them.

**No assumption that any particular branch exists.** aiur runs against
many repos. The planning PR targets the repo's configured
`tracker.base_branch`; when unset, the remote's default branch
(`refs/remotes/origin/HEAD`). Never a hardcoded `develop`/`main`. The
pack references doc paths relative to the repo root, valid on whatever
the base branch is.

Pre-work drafts may live anywhere (scratch branch, workpad); planning is
not complete until the docs are on the base branch and the pack renders
on the Build Order page (`#1444`'s verification rung).

### Planning docs — resolved (operator, 2026-08-01): docs are larvae

Pre-planning docs are a temporary staging space between planning and
ticket creation. Duplication is solved by TRANSFER OF AUTHORITY, not
synchronization: exactly one authoritative home per member at any moment
— the doc before its ticket exists, the ticket after.

```
builds/<slug>/
  build-order.json      # members: {id, title, deps, ticket: null|#N, doc: "tickets/AS-101.md"}
  tickets/AS-101.md     # researched draft ticket body — IS the future issue body
```

- The research spike writes one doc per future ticket; the deep research
  IS the ticket draft, no separate artifact.
- Ticket creation = promotion: doc content becomes the issue body
  verbatim, the pack records the number, the doc is frozen (marked
  promoted, never edited again).
- Dashboard straddle for phased creation falls out for free: member with
  `ticket: #N` renders live tracker state; `ticket: null` renders the
  doc. One list, mixed created/uncreated members.
- Mid-run changes to future tickets: agents edit the doc if uncreated,
  the ticket if created.
- User repo docs (planning branches etc.): aiur never reads them.
  Any copy a developer checks in is inert decoration — nothing consumes
  it, so drift is harmless. Their version control, their business.
- THE RULE (goes in the /aiur-build skill): after promotion, edits go to
  the ticket, never the doc. That sentence is the entire
  anti-duplication mechanism.
- No planning PR, no workspace materialization: agents go off the ticket
  itself, which carries the full researched contract.

### Decisions from 2026-08-01 Q&A

- `status.json`: written on state change (tracker transitions), not
  periodic.
- `aiur init`: the per-repo node already exists via the pre-warm
  question; init just verifies/uses the new `latest/` path (#1443's
  surface only needs the path check).
- Sidecars: `.aiur-hex`/`.aiur-mix`/npm cache move beside `latest/` in
  the same ticket (pure caches, staleness harmless).
  `.aiur-base-built` is load-bearing where it sits — in-tree it is
  self-invalidating on re-clone; naively moving it reintroduces the
  #1404 stale-marker class. It either stays in-tree with a comment
  saying why, or is upgraded to a SHA-keyed record (clone HEAD +
  base-build inputs) — never naively moved. [pending final call]

## Open questions before ticketing

- `.aiur-base-built`: keep in-tree (documented) or upgrade to SHA-keyed
  record? (see Sidecars above)
- `status.json` schema (fields; folds in the persistence half of #1445;
  the GitHub-hydration half of #1445 is its data feed).
- Migration of the two existing packs (July dashboard run, current
  analytics-streamdeck) into `builds/`, and the clone move into
  `latest/` — one-shot script or lazy per-repo on first touch?
- Promotion mechanics: does /aiur-build promote (create issue from doc)
  one phase at a time on operator command, and what marks a doc
  promoted (frontmatter flag vs move to `tickets/promoted/`)?
- The completed July pack and current pack use different schemas
  (canonical vs legacy display shape) — does the new discovery read
  both, or do we migrate both to one schema (#1445's reader work)?
