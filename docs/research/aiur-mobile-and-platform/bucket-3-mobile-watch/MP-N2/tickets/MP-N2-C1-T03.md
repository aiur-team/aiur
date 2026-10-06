---
ticket_id: MP-N2-C1-T03
feature_id: MP-N2
chunk_id: MP-N2-C1
bucket: 3-mobile-watch
title: verify_token/1 with an mtime-keyed cache, constant-time hash compare, expiry and revocation
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T02]
prior_units: []
prior_boundaries: [K, WEB]
prior_features: []
prior_findings: []
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
  `reason ∈ {:token_malformed, :token_unknown, :token_expired, :device_revoked, :device_auth_disabled, :store_corrupt}`.
  Used by the gateway plug (MP-N2-C4-T03) and the instance plug (MP-N2-C6-T01).
- **Non-goals:** minting tokens (MP-N2-C5-T03), HTTP plugs (C4-T03, C6-T01).

## Dependencies and blockers

DESIGN-N2 (gate), MP-N2-C1-T02 (token hash storage). Concurrent with C1-T04. Dependents:
MP-N2-C4-T03, MP-N2-C6-T01, MP-N2-C5-T03.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur_web/supervisor_auth.ex:61-82`: bearer parsing (`parse_bearer/1`), sha256 of both
  sides, `Plug.Crypto.secure_compare/2`. The supervisor token is one configured value; device tokens
  are many, so the lookup must be by hash, not by comparing against each.
- Contract §2 (token: opaque 256-bit, store holds sha256 only, TTL 15 min), §4.4 (instances read the
  store, cache by file mtime; disabled → `device_auth_disabled`), §9 (corrupt → fail closed).

## Chosen design

- Token format: `"aiurdt1." <> base64url(32 random bytes)`; anything else → `:token_malformed`
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
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/token_verifier_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation results for 2, 3, 6 in the PR body.
- [ ] Dependents: MP-N2-C4-T03, MP-N2-C6-T01.
