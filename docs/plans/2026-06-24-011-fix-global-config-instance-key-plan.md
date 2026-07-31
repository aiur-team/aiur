---
status: active
type: fix
created: 2026-06-24
origin: https://github.com/aiur-team/aiur/issues/443
issue: 443
---

# fix: Per-instance identity for global-config users (#443)

## Problem

Follow-up to the #431 per-instance-identity fix (PR #439). The engine's
`aiur_project_root` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh`) walks `$PWD`
up to the first `.aiur/config`/`.aiurconfig` and hashes that root into the
instance key (node name, tmux session, socket). For users with **no repo-local
config** who rely on the global `~/.aiur/config`, the walk-up misbehaves:

- **cwd not under `$HOME`, nothing up-tree** → empty key → legacy shared node
  `aiur-$USER@127.0.0.1`. Two such projects share one identity and reap each other.
- **cwd under `$HOME`** → the walk-up stops at `~/.aiur/config` and returns `$HOME`
  → every project under `$HOME` hashes `$HOME` → cross-project collision.

Repos with a repo-local `.aiur/config` (e.g. this one) are unaffected — the
walk-up finds the repo root before reaching `$HOME`. This only hits the
global-config population. #431 explicitly deferred this ("two no-project
instances still collide; documented, not solved").

## Scope

**In:** the project-root resolution in `aiur_project_root`; in-code documentation
of the resulting control-command requirement; regression coverage. **Out:** node
name / session / socket wiring (already keyed off the resolved root — fixing the
root fixes them all), socket-discovery for control commands (the issue accepts
"document" as the resolution).

## Key Technical Decisions

- **Stop the walk-up at `$HOME`.** The global config lives at `~/.aiur/config`
  (legacy `~/.aiurconfig`); it is not a repo root. Excluding `$HOME` from the
  walk-up is what stops every project under `$HOME` from collapsing onto one key.
- **No repo-local config → key by `realpath($PWD)`.** When the walk-up finds no
  repo-local config, the BEAM serves this run via the global config (mirroring its
  discovery order in `src/lib/aiur/workflow.ex:41-51`) — or via none at all — and
  in both cases the project being served is the cwd. Keying by `realpath($PWD)`
  gives each global-config project a distinct, stable identity instead of an empty
  key or `$HOME`.
- **Repo-local repos unchanged.** The walk-up still finds the repo root first, so
  their key (and control-from-subdir behavior) is byte-identical to today.
- **Canonicalize `$PWD` and `$HOME`** before the home-boundary comparison so a
  symlinked cwd or home still resolves the boundary correctly.
- **Control-command caveat, documented.** A global-config run's key is cwd-derived
  (no repo root to converge on), so `status`/`pause`/`stop` must run from the same
  directory the run was launched from. Documented in-code where the key is derived.
  Repo-local repos keep the walk-up, so control still works from any subdir.
- **Legacy empty-key fallback retained as a defensive guard** in
  `aiur_instance_key`, but no longer reachable by the normal run path (any real
  cwd now yields a key). The one-time legacy-orphan reclaim is unchanged.

## Test Scenarios

- Two projects under a fake `$HOME` holding only a global `~/.aiur/config` get
  distinct keys, and neither equals `$HOME`'s key. _(#443 bug case 2)_
- Two no-config directories outside `$HOME` get distinct keys, and the keyed node
  is never the legacy `aiur-$USER@127.0.0.1`. _(#443 bug case 1)_
- Repo-local repo: subdir and repo root derive the same key; a sibling root
  differs. _(unchanged #431 guarantee)_
- Key stays a short, node-name-legal lowercase-hex segment.

## Risks

- **Identity must stay byte-stable across launch and control** — preserved because
  all three handles still derive from the single `aiur_project_root` chokepoint.
- **Symlinked `$HOME`/cwd** could miss the home boundary — mitigated by
  canonicalizing both before comparison; covered by tests run from temp dirs.

## Verification

`mise exec -- mix test` for `aiur_engine_test.exs` and
`aiur/regression/instance_identity_test.exs` green; `mix compile` + lint clean.
