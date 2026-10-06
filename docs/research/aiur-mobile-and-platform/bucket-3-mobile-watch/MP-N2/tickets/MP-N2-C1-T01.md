---
ticket_id: MP-N2-C1-T01
feature_id: MP-N2
chunk_id: MP-N2-C1
bucket: 3-mobile-watch
title: Machine store layout, read-only identity binding and the Ed25519 machine key
status: blocked
blocked_by: [DESIGN-N2, MP-R1-C2-T01]
prior_units: []
prior_boundaries: [K, CFG]
prior_features: [MP-R1]
prior_findings: [RC-01, RC-02, RC-03]
size_owner: n/a (new files under src/lib/aiur/machine/)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C1-T01 — Store layout, identity binding, machine key

## Identity and outcome

- **Bucket / feature / chunk:** 3 mobile-watch / MP-N2 / MP-N2-C1 "Machine store library".
- **User value:** pairing is machine-level and durable. Every later MP-N2 piece (gateway, CLI,
  instance device auth) needs one trusted place that says which machine this is and holds the key
  that signs QR codes and registry responses.
- **Deliverable:** a pure library `Aiur.Machine.Store` (PROPOSED, `src/lib/aiur/machine/store.ex`)
  with:
  - `paths/0` → the machine state directory `${AIUR_BG_STATE_DIR:-${XDG_CONFIG_HOME:-~/.config}/aiur}/machine/`
    and its files (contract §5).
  - `identity/0 :: {:ok, %{machine_id, machine_label, created_at}} | {:error, :identity_unavailable, detail}`
    — **reads** `identity.json` written by MP-R1 (RC-01). Never writes or regenerates it.
  - `init_machine_key/0 :: {:ok, pub} | {:error, reason}` — creates `machine_key` (Ed25519 seed,
    0600), `machine_key.pub` (0644 is not needed; 0600) and `store.json` (`{"schema": 1}`) if absent;
    idempotent; refuses if they exist but are unreadable or wrongly owned.
  - `machine_key/0`, `machine_public_key/0`, `sign/1`, `verify/2` (Ed25519 over raw bytes).
  - `check_dir/1`: directory mode 0700 and owner equals the running user, files 0600.
- **Non-goals:** device rows, pairing secrets, tokens (T02, T03), the journal (T04), settings
  (MP-N2-C3-T01), creating `identity.json` (MP-R1-C2-T01), `aiur mobile reset` (MP-N2-C7 calls
  the MP-R1 reset path and deletes the key files).

## Dependencies and blockers

- **DESIGN-N2** — MP-REQ2 gate. DESIGN-N2 itself says C1 has no user-facing surface, but the
  brief §8 rule keeps the gate on every implementation ticket; the coordinator may relax it.
- **MP-R1-C2-T01** — creates `~/.config/aiur/machine/identity.json` at first daemon boot
  (RC-01; `contracts/identity-and-capabilities.md` §1.1). The exact JSON field names come from
  that ticket; this ticket must read them, not redefine them.
- **Concurrent with:** MP-N2-C2-T03, MP-N2-C2-T04, MP-N2-C3-T01.
- **Dependents:** MP-N2-C1-T02..T04, MP-N2-C3-T02 (`enable` calls `init_machine_key/0`),
  MP-N2-C4-T01, MP-N2-C5-T01 (QR signing).

## Verified starting point (base `45a290e3`)

- No machine identity, machine key or store exists (contract §1 "Not found"; `git grep -n machine_id 45a290e3 -- src/lib packaging` is empty).
- State dir convention: the launcher uses `AIUR_BG_STATE_DIR`, default `$XDG_CONFIG_HOME/aiur`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:280-286`); the BEAM side resolves the same
  directory in `Aiur.Upgrade.State.state_dir/0` (`src/lib/aiur/upgrade/state.ex:35-40`) and declares
  the variable in `src/lib/aiur/env/schema.ex:180`.
- Ownership precedent: `ensure_erlang_cookie` checks owner and size and dies otherwise
  (`aiur-engine.sh:321-347`).
- Atomic write helper: `Aiur.Fs.atomic_write/3` with `fsync:` and `mode:` options
  (`src/lib/aiur/fs.ex:18-34`).
- Crypto (Erlang/OTP 28 pinned in `mise.toml`): `:crypto.generate_key(:eddsa, :ed25519)`,
  `:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])`, `:crypto.verify/6`, and
  `:crypto.hash_equals/2` — <https://www.erlang.org/doc/apps/crypto/crypto.html> (page for OTP
  29.1.1 / crypto 5.10, accessed 2026-10-06; EdDSA has been in `crypto` since OTP 24, so OTP 28
  has the same calls — recheck at implementation).
- Tests that show the temp-path discipline: `src/test/aiur/http_server_credential_gate_test.exs`
  restores env in `on_exit`.

## Chosen design

```text
machine/
  identity.json        (MP-R1; read only here)
  store.json           {"schema": 1}
  machine_key          32-byte Ed25519 seed, raw, 0600
  machine_key.pub      32-byte public key, raw, 0600
```

- **Identity binding.** `identity/0` reads `identity.json` with `Jason.decode/1`; any of
  `:enoent`, a decode error, a missing `machine_id`, a `machine_id` that is not 26 lowercase base32
  characters, or wrong ownership returns `{:error, :identity_unavailable, detail}` where
  `detail ∈ {:missing, :corrupt, :bad_owner, :unreadable}`. Callers fail closed and print
  "start any aiur instance once" (missing) or "run the identity repair" (other). **Never
  regenerate** (that orphans every pairing; identity contract §4).
- **Key creation.** `init_machine_key/0` writes the seed first, then the public key, each with
  `Aiur.Fs.atomic_write(path, bytes, fsync: true, mode: 0o600)`. If `machine_key` exists and
  `machine_key.pub` does not, it derives the public key from the seed (crash between writes). If
  `machine_key.pub` exists without the seed, it returns `{:error, :machine_key_missing}`; a public
  key alone is never trusted.
- **Directory checks.** `check_dir/1` creates the directory with `File.mkdir_p/1` then
  `File.chmod(dir, 0o700)`; refuses (`:bad_owner`) when the directory's `File.stat/1` uid differs
  from the running user's uid. The running uid is taken from a probe file the process creates in
  `System.tmp_dir!/0` (its owner is the effective uid), which is portable and needs no shell.
- **Store version.** `store.json` schema 1; an unknown higher schema returns `{:error, :store_schema_unsupported}` (fail closed).
- **Invariants:** the seed never leaves the module (no public function returns it; `sign/1` takes
  a message); no log line contains key bytes.

## Implementation steps

1. `src/lib/aiur/machine/paths.ex` (PROPOSED): state dir resolution mirroring `upgrade/state.ex:35-40`.
2. `src/lib/aiur/machine/store.ex` (PROPOSED): `identity/0`, `check_dir/1`, `init_machine_key/0`,
   `machine_public_key/0`, `sign/1`, `verify/2`.
3. Tests and fixtures. About 170 production lines.

## Non-happy paths

| Case | Result |
|---|---|
| `identity.json` missing (R1 never booted) | `{:error, :identity_unavailable, :missing}`; no file is created. |
| `identity.json` corrupt | `:corrupt`; nothing regenerated; the CLI tells the operator to repair through MP-R1. |
| Directory owned by another user / mode 0755 | `:bad_owner` refuses; mode is tightened to 0700 only when owner matches. |
| Seed present, pub missing (crash) | pub re-derived. |
| Pub present, seed missing | `:machine_key_missing`; operator must `aiur mobile reset`. |
| Two CLI processes run `enable` at once | Serialized by the store lock (MP-N2-C1-T02); this ticket's writes are idempotent anyway. |

## Compatibility and rollout

Library only; nothing calls it until MP-N2-C3-T02. No config, no migration. Rollback: delete the
module. Plan refresh: after MP-R1 the module moves to the package R1 names for `aiur_machine`.

## Verification

`src/test/aiur/machine/store_identity_test.exs` (async: false; every test sets
`AIUR_BG_STATE_DIR` to a `System.tmp_dir!/0` subdir and restores it in `on_exit`):

1. `"reads machine_id and label from an MP-R1 identity file"` — fixture JSON → `{:ok, %{machine_id: ...}}`.
   *Fails without:* the decode path in `identity/0`.
2. `"missing identity is identity_unavailable and creates nothing"` — asserts the dir listing is
   unchanged afterwards. *Fails without:* the no-regenerate rule (an implementation that writes a
   new identity makes this fail).
3. `"corrupt identity is identity_unavailable :corrupt"`.
4. `"init_machine_key creates 0600 seed and pub and is idempotent"` — second call returns the same pub.
5. `"pub is re-derived when only the seed exists"`. *Fails without:* the recovery branch.
6. `"pub without seed is refused"`.
7. `"signature verifies with the stored public key and fails for a flipped byte"`.
8. `"directory with another owner is refused"` — simulated by injecting the stat function
   (`Store.check_dir(dir, stat_fun: ...)`), since tests cannot chown.
9. `"no public function returns the seed"` — `Store.__info__(:functions)` contains no
   `machine_key/0` returning raw seed bytes; asserts by calling every 0-arity export and
   checking no result equals the seed. Mutation: add a `seed/0` export → fails.

Command (from `src/`):

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/store_identity_test.exs
```

Mutation check: run in a worktree with only the named hunk reverted (`git status --porcelain`
shows exactly that file); report the command and result in the PR body.

## Completion and handoff

- [ ] Tests 1–9 pass; mutation checks for 1, 2, 5, 9 recorded.
- [ ] Docs: none user-facing in this ticket (the store is described in the pairing guide by MP-N2-C9-T01).
- [ ] Dependents unblocked: MP-N2-C1-T02, MP-N2-C3-T02.
