---
status: active
type: fix
created: 2026-06-22
origin: docs/brainstorms/2026-06-22-per-instance-aiur-identity-requirements.md
issue: 431
---

# fix: Per-instance aiur identity (#431)

## Problem

aiur derives its runtime identity per **user**, not per **instance** — node
`aiur-${USER}@127.0.0.1` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:54`),
tmux session `aiur-${USER}-default` (`:307`), socket `aiur-${USER}` (`:308`). A
second aiur for the same user collides, and the startup reaper
`kill_beams_matching -name $AIUR_RELEASE_NODE` (`:372`, `:818`) kills any beam with
that node name. A sandboxed inner aiur (an agent running `aiurdev` in its workspace
to repro #431/#432) can't see the outer's tmux session, so it reaps the **live
outer run** — this killed a `--bg` session on 2026-06-22.

---

## Scope

**In:** instance-key derivation in the engine, applied to node name + tmux session
+ socket; the same key resolved for the control commands (`status`/`pause`/`stop`);
the legacy-orphan reclaim path. **Out:** a separate "refuse-if-live" guard (the
identity fix makes it moot), RPC transport changes (see origin).

### Deferred to Follow-Up Work
- Surfacing the resolved instance identity in `aiur status` output (nice-to-have).

---

## Key Technical Decisions

- **Instance key source = the resolved aiur project root** (the directory holding
  the active `.aiur/config`, or legacy `.aiurconfig`, found by walking up from
  `$PWD`). Both launch and the control commands already resolve this same root, so
  they derive the same key — `$PWD` alone is rejected because launch-from-subdir vs
  control-from-root would diverge. The dev shim (`scripts/aiurdev`) already exports
  `AIUR_REPO_ROOT`; reuse it as the root when set.
- **Encoding = short hash.** The root path isn't a legal Erlang node-name segment
  (slashes, length). Hash the absolute root path to a short lowercase
  alphanumeric token (e.g. first 10 chars of a `sha256`/`cksum` hex) and mix it in:
  node `aiur-${USER}-${KEY}@127.0.0.1`, session `aiur-${USER}-${KEY}-default`,
  socket `aiur-${USER}-${KEY}`.
- **No project root → legacy identity.** When no `.aiur/config` resolves (aiur run
  outside a project), `KEY` is empty and the names fall back to today's
  `aiur-${USER}` form — preserving current single-instance behavior. (Edge case:
  two no-project instances still collide; documented, not solved.)
- **Backward-compat reclaim.** Post-fix launches use the keyed name, so a
  pre-existing orphan under the **old fixed** `aiur-${USER}@127.0.0.1` would never
  be reaped and could hold port 4000 / the old name. On launch, additionally reap a
  legacy-fixed-name beam **only when no live legacy session exists** (mirrors the
  existing `has-session` guard at `:371`) — a one-time transition aid, safe because
  post-fix instances never use the legacy name.
- **The reaper itself is unchanged** — once `$AIUR_RELEASE_NODE` is instance-keyed,
  `kill_beams_matching -name $AIUR_RELEASE_NODE` (`:372`,`:818`) is automatically
  instance-scoped.

---

## Implementation Units

### U1. Derive a stable instance key in the engine

**Goal:** A single function that resolves the aiur project root and produces the
short hash `KEY` (empty when no project), available before identity is used.
**Requirements:** success criteria 1, 2 (origin).
**Dependencies:** none.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
**Approach:** Resolve root as `AIUR_REPO_ROOT` if set, else walk up from `$PWD`
for `.aiur/config` then `.aiurconfig`. Hash the absolute root to a short token.
Compute once, early (before `resolve_release`/`prepare_distribution` and before
the session/socket locals at `:307-308`), so launch and control share it. Keep the
function pure (stdout the key) for testability.
**Patterns to follow:** the existing env-export block (`:52-66`) and the config
resolution used elsewhere in the engine.
**Test scenarios:**
- Same project root (called twice) → identical key. _(happy)_
- Two different roots → different keys. _(happy)_
- Root with no `.aiur/config` anywhere up-tree → empty key. _(edge)_
- `AIUR_REPO_ROOT` set → key derived from it, ignoring `$PWD`. _(edge)_
- Key is lowercase-alphanumeric and ≤ ~12 chars (legal node-name segment). _(edge)_

### U2. Mix the key into node name, tmux session, and socket

**Goal:** All three identity handles become per-instance, consistently at launch
and for control commands.
**Requirements:** success criteria 1, 2, 4 (origin).
**Dependencies:** U1.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
**Approach:** Default `AIUR_RELEASE_NODE` to `aiur-${USER}${KEY:+-$KEY}@127.0.0.1`
(`:54`); build session `aiur-${USER}${KEY:+-$KEY}-default` and socket
`aiur-${USER}${KEY:+-$KEY}` (`:307-308`). Empty `KEY` reproduces the legacy names
exactly. Verify the value flows to: `RELEASE_NODE` export (`:116`), the launch
reaper (`:371-372`), the `_session_*` exports (`:360-363`), and the control RPC
path (`run_control_rpc`/`prepare_distribution`).
**Patterns to follow:** existing `:=`-default + `export` style.
**Test scenarios:**
- Launch from project A vs project B → node names differ (no shared name). _(happy)_
- `status`/`pause`/`stop` run from project A resolve A's node name. _(integration)_
- Empty key → names byte-identical to the pre-change `aiur-${USER}` forms. _(edge — backward compat)_

### U3. One-time legacy-orphan reclaim on launch

**Goal:** A pre-fix orphan under the old fixed name doesn't block a keyed launch.
**Requirements:** success criterion 3 + backward-compat (origin).
**Dependencies:** U2.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.
**Approach:** When `KEY` is non-empty, additionally reap `-name aiur-${USER}@127.0.0.1`
**only if** no live tmux session exists on the legacy socket `aiur-${USER}` (reuse
the `has-session` guard shape at `:371`). Skip entirely when `KEY` is empty (that
launch *is* the legacy instance). Keep it loud-free (best-effort, like the existing
reaper).
**Test scenarios:**
- Keyed launch with a dead legacy-name beam present → legacy beam reaped, new keyed
  beam starts. _(happy)_
- Keyed launch while a *live* legacy session exists → legacy beam NOT reaped. _(edge — don't kill a live legacy run)_
- Empty-key launch → no legacy-specific reclaim runs. _(edge)_

### U4. Regression coverage for coexistence + reclamation

**Goal:** Lock in the #431 fix so it can't regress.
**Requirements:** all success criteria (origin).
**Dependencies:** U1–U3.
**Files:** `src/test/aiur/regression/instance_identity_test.exs` (new), mirroring
`src/test/aiur/regression/shutdown_cleanup_test.exs`.
**Approach:** Drive the engine shell from the test (as ShutdownCleanupTest does):
assert the derived node/session/socket differ for two distinct roots and match for
the same root; assert the legacy-name reclaim fires only without a live legacy
session. Prefer asserting on the *derived identity* (cheap, deterministic) over
spinning two full BEAMs; a single end-to-end "two roots don't reap each other" case
is the high-value integration check if feasible without flakiness.
**Execution note:** characterization-first — assert current single-instance
behavior is unchanged (empty-key path) before adding the multi-instance cases.
**Test scenarios:**
- Covers success-criterion 1: two roots → distinct identities, no cross-reap.
- Covers success-criterion 2: control resolves the launching root's identity.
- Covers success-criterion 3: same-root relaunch reclaims its own dead orphan.
- Backward-compat: empty-key identity equals the legacy names exactly.

---

## Risks

- **Identity must be byte-stable across launch and control**, or `status`/`pause`/
  `stop` silently miss the node. Mitigation: single shared derivation function (U1),
  U2's integration test asserting control resolves the launch identity.
- **Hash collisions / length** breaking node-name validity. Mitigation: lowercase
  alphanumeric, bounded length, tested in U1.
- **Legacy reclaim over-reaping a live legacy run.** Mitigation: `has-session` guard
  (U3), explicit test.

## Verification

`make -C src MIX='mise exec -- mix' all` green; manual: launch aiur in the repo and
a second `aiurdev` from a workspace dir → both coexist, neither beam reaped;
`aiur status`/`pause`/`stop` from each target the right instance.
