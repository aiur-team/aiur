# Per-instance aiur identity (#431)

_2026-06-22 · requirements for the #431 fix · feeds ce-plan_

## Problem

aiur derives its runtime identity per **user**, not per **instance**:

- node name: `aiur-${USER}@127.0.0.1` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:54`)
- tmux session: `aiur-${USER}-default` (`...:307`)
- tmux socket: `aiur-${USER}` (`...:308`)

So a second aiur for the same user collides with the first. The startup reaper
`kill_beams_matching -name $AIUR_RELEASE_NODE` (`...:372`, `...:818`) kills **any**
beam holding that node name. A sandboxed inner aiur (an agent running `aiurdev`
inside its workspace to repro #431/#432) can't see the outer's tmux session, so it
reaps the **live outer run**. This killed a live `--bg` session on 2026-06-22
(agent #431's inner `aiur-kevin-default` launch reaped the outer beam at the exact
death timestamp).

## Decision

Mix a stable **per-instance key**, derived from the launch directory (the repo /
`.aiur/config` root), into the node name, tmux session, and socket — consistently,
so launch and the control commands derive the same identity.

## Why this cut

- **Coexistence fixes the disaster.** The inner aiur an agent launches runs in its
  workspace dir (e.g. `~/code/aiur-workspaces/aiur/431`) — a different root than the
  outer's repo — so it derives a different identity and the two run side by side
  instead of reaping each other. This also makes #431/#432 agent-dogfoolable.
- **Orphan reclamation preserved (original #431 ask).** A relaunch from the same
  repo derives the same key → still reaps *its own* dead orphan; it just won't reap
  a *different* live instance. The reaper's `has-session` guard (`...:371`) stays.
- **Control resolution.** `status` / `pause` / `stop` derive the same key from the
  same launch dir → target the right node.

## Scope

**In:** identity derivation (engine + `scripts/aiurdev`), the startup reaper,
control-command (`status`/`pause`/`stop`) node resolution.
**Out:** a separate "refuse-to-start-if-a-live-instance-exists" guard (the identity
fix makes it unnecessary); RPC transport changes.

## Success criteria

1. Two aiur instances launched from different roots (e.g. the main repo + an agent
   workspace dir) **coexist** — neither reaps the other's beam, session, or socket.
2. `status` / `pause` / `stop` run from a given root target **that root's** instance.
3. A relaunch from the same root still **reclaims its own dead orphan** (the #431
   "duplicate session not reclaimed" case still works).
4. The #431 repro (an agent launching inner aiur) **no longer kills** the outer run.

## Open questions for ce-plan

- Exact key source: git root vs the resolved `.aiur/config` directory vs `$PWD`.
  (Must be stable across launch + control invocations from the same project.)
- Hashing/encoding to satisfy the Erlang node-name charset and keep names short.
- How `aiur status` (etc.) resolves identity when run **outside** any aiur project.
- Backward compatibility: existing single-instance users should see no behavior
  change for the common case; orphans from the old fixed name may need a one-time
  reclaim path.
