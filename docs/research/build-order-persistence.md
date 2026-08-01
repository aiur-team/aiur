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

### Storage — global per-repo store

```
~/.aiur/build_orders/<owner>/<repo>/<slug>/
  build-order.json     # canonical pack; what discovery reads
  status.json          # daemon-written: per-member state, progress %, active|completed
```

- `~/.aiur/` is already the operator-state home (`logs/`, `repo/`,
  `build-gate/`). Not `~/.config/aiur` (splits state roots); not inside
  `~/.aiur/repo/<owner>/<repo>/` (the warm clone is rebuilt/re-cloned —
  state inside it gets wiped).
- Owner/repo nesting mirrors `repo/` and workspaces; an org rename is one
  `mv`; same-slug packs in different repos cannot collide.
- Repo-local `.aiur/build_orders/` remains as a shadowing dev override;
  `/aiur-build` writes to the global store by default.
- Discovery: `AIUR_BG_STATE_DIR` default moves to `~/.aiur` (or the glob
  gains the root) so zero env setup is needed.
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

## Open questions before ticketing

- `status.json` write cadence and schema (folds in the persistence half
  of #1445; the GitHub-hydration half of #1445 is its data feed).
- Migration of the two existing packs (July dashboard run, current
  analytics-streamdeck) into the store.
- Whether a consumer repo with no docs dir wants the planning PR to
  create one, and where (`docs/` vs configurable).
- Whether `aiur init` (#1443's surface) should scaffold the global store.
