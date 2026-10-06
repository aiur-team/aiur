---
ticket_id: MP-N2-C1-T04
feature_id: MP-N2
chunk_id: MP-N2-C1
bucket: 3-mobile-watch
title: Append-only machine journal with no secret fields
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T02]
prior_units: []
prior_boundaries: [K]
prior_features: []
prior_findings: []
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C1-T04 — Machine journal

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C1.
- **User value:** the operator can see when each device paired, re-linked, was revoked, and when
  unpair-all or a claim lockout happened, without any secret ever reaching disk in clear.
- **Deliverable:** `Aiur.Machine.Journal.append(event, fields)` (PROPOSED) writing one JSON object
  per line to `<machine dir>/journal.ndjson` (0600), and `Journal.tail(n)` for `aiur mobile status`.
  Events: `paired, relinked, revoked, unpair_all, claim_lockout, machine_key_created, mobile_enabled,
  mobile_disabled`.
- **Non-goals:** rotation beyond a size cap; alert emission for lockouts (MP-N2-C5-T02 calls the alert ledger).

## Dependencies and blockers

DESIGN-N2 (gate), MP-N2-C1-T02 (store lock: appends run inside the same lock hold as the mutation
they describe). Concurrent with T03. Dependents: MP-N2-C3-T03 (status tail), C5, C7.

## Verified starting point (base `45a290e3`)

- Contract §5 (`journal.ndjson`: paired, relinked, revoked, unpair_all, claim_lockout; no secrets).
- An append-only journal pattern with locking exists in `Aiur.AlertLedger` (`src/lib/aiur/alert_ledger.ex:237`
  uses `Fs.atomic_write(..., fsync: true, mode: 0o600)` for rewrites; `:354-368` lock). The machine
  journal does not reuse the alert ledger because the ledger is project-scoped.

## Chosen design

- **Allow-list, not deny-list:** `append/2` accepts only these field keys:
  `at, event, device_id, parent_device_id, platform, label, by_device_id, by ("cli"|"gateway"),
  count, reason`. Any other key raises `ArgumentError` in test and is dropped with a warning in
  prod. So a token, secret, proof or key can only reach the journal through a code change that
  also edits the allow-list (reviewable).
- Append with `File.open(path, [:append, :binary])` + `:file.datasync/1`, under the store lock.
- Size cap 1 MiB: when exceeded, rename to `journal.1.ndjson` (one generation kept).

## Implementation steps

1. `src/lib/aiur/machine/journal.ex` (PROPOSED). 2. Tests. About 80 production lines.

## Non-happy paths

Unwritable journal → the mutation still succeeds and returns `{:ok, journal: :failed}`; the CLI
prints a warning (the journal is evidence, not authority). Corrupt line → `tail/1` skips it and counts it.

## Compatibility and rollout

New file only after `aiur mobile enable`.

## Verification

`src/test/aiur/machine/journal_test.exs`:

1. `"append writes one json line with only allow-listed keys"`.
2. `"a non-allow-listed key raises in test"` — `append(:paired, token: "x")`. *Fails without:* the allow-list.
3. `"no secret text appears in the journal after a full pair, refresh, revoke cycle"` — drives
   Store + Journal with known token and secret values and greps the file (acceptance 9).
4. `"rotation at 1 MiB keeps one generation"`.
5. `"tail skips a corrupt line and reports it"`.

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/journal_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 2 recorded.
- [ ] Dependents: MP-N2-C3-T03, MP-N2-C5-T02, MP-N2-C7-T01/T02.
