---
ticket_id: MP-N2-C1-T02
feature_id: MP-N2
chunk_id: MP-N2-C1
bucket: 3-mobile-watch
title: Device rows, pairing secrets and token hashes with atomic writes and a single-writer store lock (resolves RQ-N2-6)
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T01]
prior_units: []
prior_boundaries: [K]
prior_features: []
prior_findings: [RC-42 / security B1 (journal every row), RQ-N2-6]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C1-T02 — Store records and the store lock

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C1.
- **User value:** device authorizations survive restarts and are never half-written, and two
  writers (the gateway and a CLI run while the gateway is down) can never interleave and lose a
  revocation.
- **Deliverable:** in `Aiur.Machine.Store` (PROPOSED):
  - `devices/0`, `put_device/1`, `delete_device/1` (cascades to children with that
    `parent_device_id`), `delete_all_devices/0`.
  - `put_pairing_secret/2` (stores sha256 only, expiry, `used: false`, keeps at most 3 by dropping
    the oldest), `consume_pairing_secret/2`.
  - `add_token_hash/3`, `prune_expired_tokens/1`.
  - `with_lock/2` — the single-writer lock (RQ-N2-6) every mutating call runs under.
  - `known_instances` persistence for MP-N2-C2-T04 (`known_instances.json`, see contract request).
- **Non-goals:** token verification and its cache (T03), the journal (T04), HTTP endpoints (C5, C7).

## Dependencies and blockers

- DESIGN-N2 (MP-REQ2 gate; no UI in this ticket). MP-N2-C1-T01 (paths, dir checks).
- Concurrent with: MP-N2-C2-*, MP-N2-C3-T01.
- Dependents: T03, T04, MP-N2-C2-T04, MP-N2-C4-T01, MP-N2-C5-*, MP-N2-C7-*.

## Verified starting point (base `45a290e3`)

- Launcher lock algorithm: `acquire_aiur_launch_lock` (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:1522-1563`)
  uses `mkdir` as the atomic test-and-set, an `owner` file with the holder pid, `kill -0` to detect
  a dead holder, an ownerless-stale age (120 s) and a separate `.recovery` mkdir mutex so only one
  contender reclaims a dead lock. `release_aiur_launch_lock` (`:1574-1583`) removes only its own lock.
- Atomic file write: `Aiur.Fs.atomic_write/3` (`src/lib/aiur/fs.ex:18-34`), temp + optional fsync + rename.
- Constant-time compare precedent: `SupervisorAuth.token_matches?/2` hashes both sides with
  sha256 then `Plug.Crypto.secure_compare/2` (`src/lib/aiur_web/supervisor_auth.ex:78-82`).
- Contract §5 file set (`devices.json`, `pairing.json`), §3 secret rules (single use, 10-minute
  expiry, at most 3 outstanding), §4.5 cascade.

## Chosen design

**RQ-N2-6 resolution: a `mkdir` lock with pid ownership, same algorithm as the launcher.**

- Lock path: `<machine dir>/store.lock/` with `owner` containing `"<os_pid> <role>"`
  (`role ∈ gateway|cli`). `with_lock(fun, timeout_ms \\ 5_000)`:
  1. `File.mkdir(lock)`; on `:ok` write `owner`, run `fun`, then remove `owner` and `rmdir` in an
     `after` block (only if `owner` still names this pid).
  2. On `{:error, :eexist}` read `owner`; if the pid is alive (`System.cmd("kill", ["-0", pid])`
     exit 0) wait 50 ms and retry until the timeout; if dead, or ownerless and older than 120 s,
     reclaim under `store.lock.recovery/` exactly as the launcher does.
  3. Timeout → `{:error, :store_locked, holder}`.
- **The gateway holds the lock for its lifetime** (`hold_lock/0` returns `{:ok, ref}`; released in
  `terminate/2`). So while the gateway runs, a CLI mutation gets `:store_locked` with role `gateway`
  and must send the change to the gateway (MP-N2-C3-T02 routes CLI writes over distribution to the
  gateway node). While the gateway is down, the CLI takes the lock for the single write. This makes
  "two gateways" impossible as well (contract §9).
- Why not `:global` or a BEAM lock: the CLI and the gateway are different OS processes with no
  shared node by default; a filesystem lock works with zero nodes running. Why not `flock(2)`:
  not available from Erlang without a port program or NIF.
- **Records.** JSON via `Jason`. Every mutation is read-modify-write of one file under the lock,
  then `Aiur.Fs.atomic_write(path, json, fsync: true, mode: 0o600)`. `delete_all_devices/0`
  rewrites `pairing.json` (secrets cleared) first and `devices.json` (empty) second, within one
  lock hold. A crash between the two leaves devices present but no outstanding secrets, which is
  safe; re-running unpair-all completes it.
- **Token hashes** live in the device row: `token_hashes: [%{hash, expires_at}]`; at most 4 per
  device (a refresh that overlaps expiry), oldest dropped; expired ones pruned on every write.
- **Row shape** (contract §5): `device_id, label, platform, auth_public_key, parent_device_id,
  paired_at, last_seen_at, push_registration, token_hashes`. `last_seen_at` updates are batched by
  T03 (not every request) to avoid write amplification.
- Readers (instances, MP-N2-C6) never take the lock: rename gives them a whole file.
- **Journal every row (Phase D, RC-42, security B1):** `put_device/1` and the relink path
  call an optional `journal:` callback **inside the same lock hold, before** the
  `devices.json` rename. MP-N2-C1-T04 (which depends on this ticket) passes
  `Journal.append(:paired | :relinked, …)` there and owns the test; this ticket only adds
  the callback slot and its ordering test (13).

## Implementation steps

1. `src/lib/aiur/machine/store_lock.ex` (PROPOSED): `with_lock/2`, `hold_lock/0`, reclaim logic,
   injectable `alive?/1` and clock for tests.
2. `src/lib/aiur/machine/store.ex`: record functions above.
3. Tests. About 260 production lines.

## Non-happy paths

| Case | Result |
|---|---|
| Gateway running, CLI tries `revoke` directly | `{:error, :store_locked, "gateway"}`; CLI routes via gateway (C3-T02). |
| Holder SIGKILLed | Next contender sees a dead pid and reclaims under the recovery mutex. |
| Pid reuse (holder died, pid reused by an unrelated process) | Lock looks held; the caller times out with a message naming `store.lock` and the pid. Accepted; same limit as the launcher lock. |
| `devices.json` corrupt | Every mutation and read returns `{:error, :store_corrupt}`; nothing is overwritten (fail closed, contract §9). |
| Disk full during write | `atomic_write` cleans the temp and returns the error; the old file stays. |
| A fourth pairing secret | The oldest is dropped (contract §3). |
| Reused secret | `consume_pairing_secret/2` returns `:pair_secret_used`; expired → `:pair_secret_expired`; unknown → `:pair_secret_unknown` (secret compared by sha256 with `:crypto.hash_equals/2`). |

## Compatibility and rollout

Library only. Files appear only after `aiur mobile enable`. Rollback: none needed.

## Verification

`src/test/aiur/machine/store_records_test.exs` and `store_lock_test.exs` (temp state dir as in T01):

1. `"put then delete a device cascades to its child watch"`. *Fails without:* the cascade.
2. `"delete_all_devices clears devices and outstanding secrets"`.
3. `"only sha256 of a pairing secret is written"` — reads `pairing.json` raw and refutes the secret's
   base64url text. *Fails without:* hashing (mutation: store the secret → fails).
4. `"a fourth secret drops the oldest"`; 5. `"used, expired and unknown secrets return their own errors"`
   (each distinct atom; mutation: collapse two into one atom → a test fails).
6. `"files are 0600 after every write"`.
7. `"lock: second contender waits, then succeeds after release"` (two Tasks).
8. `"lock: dead holder is reclaimed"` (owner file with a pid the injected `alive?/1` reports dead).
   *Fails without:* the reclaim branch.
9. `"lock: live holder causes :store_locked after timeout with the holder role"`.
10. `"corrupt devices.json is never overwritten"` — mutation attempt returns `:store_corrupt` and the
    file bytes are unchanged. *Fails without:* the fail-closed decode.
11. `"token hashes keep at most 4 and prune expired"`.
13. `"journal callback runs before the devices.json rename, inside the lock"` — a callback that
    raises leaves `devices.json` unchanged. *Fails without:* the ordering (call it after the
    rename and the row is written).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/store_records_test.exs test/aiur/machine/store_lock_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation results for 1, 3, 5, 8, 10 in the PR body.
- [ ] Contract request recorded by the parent: add `known_instances.json` and `store.lock/` to contract §5.
- [ ] Dependents: T03, T04, MP-N2-C4-T01 (`hold_lock/0`), MP-N2-C3-T02 (CLI write routing).
