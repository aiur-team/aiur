---
ticket_id: MP-N2-C1-T03
feature_id: MP-N2
chunk_id: MP-N2-C1
bucket: 3-mobile-watch
title: verify_token/1 with an mtime-keyed cache, constant-time hash compare, expiry and revocation
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T02, MP-N2-C1-T04]
prior_units: []
prior_boundaries: [K, WEB]
prior_features: []
prior_findings: [security M1 (watcher), B1/RC-42 (integrity), m6 (sign/2)]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C1-T03 — Token verification

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C1.
- **User value:** a revoked phone loses access on its next request to the gateway or to any
  instance, without restarting anything (MP-N2 acceptance 5).
- **Deliverable:** `Aiur.Machine.TokenVerifier` (PROPOSED):
  `verify(token) :: {:ok, %{device_id, expires_at}} | {:error, reason}` with
  `reason ∈ {:token_malformed, :token_unknown, :token_expired, :device_revoked, :device_unverified, :device_auth_disabled, :store_corrupt}` (`:device_unverified`: Phase D integrity check, below).
  Used by the gateway plug (MP-N2-C4-T03) and the instance plug (MP-N2-C6-T01).
- **Non-goals:** minting tokens (MP-N2-C5-T03), HTTP plugs (C4-T03, C6-T01).

## Dependencies and blockers

DESIGN-N2 (gate), MP-N2-C1-T02 (token hash storage), MP-N2-C1-T04 (journal `paired` entries for the RC-42 integrity check; Phase D). Dependents:
MP-N2-C4-T03, MP-N2-C6-T01, MP-N2-C5-T03.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur_web/supervisor_auth.ex:61-82`: bearer parsing (`parse_bearer/1`), sha256 of both
  sides, `Plug.Crypto.secure_compare/2`. The supervisor token is one configured value; device tokens
  are many, so the lookup must be by hash, not by comparing against each.
- Contract §2 (token: opaque 256-bit, store holds sha256 only, TTL 15 min), §4.4 (instances read the
  store, cache by file mtime; disabled → `device_auth_disabled`), §9 (corrupt → fail closed).

## Chosen design

- Token format (owned by MP-N2-C5-T03): `"aiurd_" <> base64url(32 random bytes)`; anything else → `:token_malformed`
  before any I/O.
- Lookup key: `h = :crypto.hash(:sha256, token)`. The cache maps `h → {device_id, expires_at}` and is
  rebuilt from `devices.json` when the file's `{mtime, size, inode}` differs from the cached stat
  (one `File.stat/2` per request, `time: :posix`). A map lookup on a sha256 digest leaks nothing
  useful through timing (the attacker does not control the digest); in addition the found entry's
  hash is compared with `:crypto.hash_equals/2` to keep the SupervisorAuth discipline.
- Cache holder: an ETS table owned by a small GenServer started by whichever node uses it
  (gateway tree or the instance web tree); `verify/1` reads ETS directly and only calls the server
  to rebuild. Readers never take the store lock.
- Expiry is checked against the machine clock (`System.os_time(:second)`), never a client clock (contract §9).
- `:device_revoked` when the hash belongs to no row but appears in a 15-minute
  `recently_revoked` set the store writes on delete (so a revoked phone gets a distinct error and
  stops retrying, contract §4.2); otherwise `:token_unknown`.
- `:device_auth_disabled` when `mobile.enabled` is false (MP-N2-C3-T01 settings) or the store
  directory does not exist.
- `last_seen_at`: the verifier records `device_id → now` in ETS; the gateway flushes it to the
  store at most once per minute (MP-N2-C4-T03). Instances never write.

## Implementation steps

1. `src/lib/aiur/machine/token_verifier.ex` (PROPOSED) + ETS owner.
2. `Store.delete_device/1` and `delete_all_devices/0` (T02) append to `recently_revoked` in `devices.json`.
3. Tests. About 150 production lines.

## Non-happy paths

| Case | Result |
|---|---|
| Store rewritten within the same second | inode changes on rename, so the stat key changes. |
| `devices.json` unreadable or corrupt | `:store_corrupt`; no token accepted (fail closed). |
| Mobile disabled with old tokens on disk | `:device_auth_disabled`. |
| Clock jumps backwards | Tokens may live longer by the jump; bounded by 15 min TTL; accepted. |

## Compatibility and rollout

Library only. No behaviour change until a plug uses it.

## Verification

`src/test/aiur/machine/token_verifier_test.exs` (temp state dir):

1. `"valid token verifies with its device_id"`.
2. `"expired token is :token_expired"`. *Fails without:* the expiry check (chunk mutation named in chunks.md).
3. `"after delete_device the next verify is :device_revoked without restarting the verifier"`.
   *Fails without:* the mtime/inode cache invalidation (mutation: cache forever → fails).
4. `"unknown token is :token_unknown, distinct from :device_revoked"`.
5. `"malformed token never touches the store"` (injected stat fun asserts zero calls).
6. `"corrupt devices.json rejects every token"`. *Fails without:* fail-closed decode.
7. `"mobile disabled returns :device_auth_disabled"`.
8. `"store never contains the raw token"` — grep `devices.json` for the token text. *Fails without:*
   hashing before storage (the chunks.md mutation "compare raw tokens with `==`" requires storing raw
   tokens, which this test catches).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/token_verifier_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation results for 2, 3, 6 in the PR body.
- [ ] Dependents: MP-N2-C4-T03, MP-N2-C6-T01.

## Phase D additions (contract requests)

- `device_active?(device_id) :: boolean` — same mtime-keyed cache as `verify_token/1`,
  `false` on any read error (fail closed). Consumers: MP-N2-C6-T02, MP-E5-C8-T01/T02
  (E5 R-3). Test: "unreadable store makes device_active? false" (mutation: return `true`
  on error → fails).
- `sign(purpose, bytes) :: {:ok, <<_::512>>} | {:error, reason}`, `purpose ∈ :qr |
  :registry | :push` (security m6) — Ed25519 by `machine_key` over
  `tag(purpose) <> bytes`, with `tag(:qr) = "aiur-qr-v1\0"`, `tag(:registry) =
  "aiur-registry-v1\0"` and `tag(:push)` the existing push tag from notification contract
  §4 (MP-N4-C1). There is no purpose-free `sign/1`; an unknown purpose is a
  `FunctionClauseError`. Inside the library, so instance daemons (MP-N4-C3-T03 push-relay)
  never copy the private bytes (CR-N4-2). Tests: signature verifies with
  `machine_key.pub` over the tagged bytes; "a :qr signature does not verify under the
  :registry tag" (*fails without* the tag); the key bytes never appear in the return value
  or logs.

## Phase D additions (security M1, B1/RC-42)

- **`Aiur.Machine.Store.Watcher`** (PROPOSED `src/lib/aiur/machine/store_watcher.ex`, about
  90 lines). Contract security sibling §S2. A GenServer started in **every instance BEAM**
  with device auth enabled (child of the instance web tree, after the verifier's ETS owner)
  and in the gateway tree. Every 2 s (`@poll_ms 2_000`, overridable for tests) it
  `File.stat/2`s `devices.json` (`{mtime, size, inode}`, `time: :posix`); on change it
  reloads the active-id set through the same loader as `verify/1` and
  `Phoenix.PubSub.local_broadcast(Aiur.PubSub, "devices:revoked", {:devices_revoked, ids})`
  for ids that left the set (revoked, unpair-all, or failing the integrity check below), and
  raises one `machine_store_untracked_device` needs-attention alert per flagged id
  (`Aiur.Alerts`, deduplicated by id; the gateway has no alert ledger, so only instance
  watchers raise it). On
  a read error it broadcasts every previously active id once and emits
  `machine_store_unreadable` (fail closed). It never needs a message from the writer: the
  writer is the gateway or the CLI, another BEAM, and a writer-side broadcast never reaches
  an instance.
- **`Store.integrity/0`** (RC-42, sibling §S4): `{:ok, []} | {:ok, [%{device_id, reason}]}`
  with `reason ∈ :no_paired_entry | :key_mismatch`, comparing each `devices.json` row with
  `journal.ndjson` `paired`/`relinked` entries (`auth_key_sha256`). `verify/1` and
  `device_active?/1` treat a flagged row as inactive (`:device_unverified`). The loader
  caches the journal by the same stat key, so the check adds no I/O per request.
- **Tests (each must fail without its hunk):**
  9. `"watcher broadcasts a revoke written directly to devices.json"` — the test subscribes
     to `devices:revoked`, then rewrites `devices.json` **from the test process with plain
     file operations** (temp file + rename, as the CLI would from another BEAM), sends no
     message to the watcher, and asserts `{:devices_revoked, [id]}` within 3 s (`@poll_ms`
     set to 100 in the test). *Fails without:* the watcher's stat poll (mutation: only react
     to a `:refresh` message → no broadcast).
  10. `"unreadable devices.json broadcasts every active id once"`. *Fails without:* the
     fail-closed branch.
  11. `"a devices.json row with no paired journal entry is not active"` — append a row with
     plain file writes, no journal line → `verify/1` is `{:error, :device_unverified}` and
     `device_active?/1` false. *Fails without:* the integrity check in the loader.
  12. `"a row whose auth key differs from its paired entry is not active"` (`:key_mismatch`).
  13. `"the watcher raises one machine_store_untracked_device alert per flagged id"` (alert
     sink injected; a second poll with the same row raises none). *Fails without:* the alert
     call.
