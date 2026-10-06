---
ticket_id: MP-N2-C3-T01
feature_id: MP-N2
chunk_id: MP-N2-C3
bucket: 3-mobile-watch
title: "~/.aiur/machine settings schema and loader (mobile, gateway, pairing, transport), independent of Aiur.Workflow"
status: blocked
blocked_by: [DESIGN-N2]
prior_units: []
prior_boundaries: [CFG]
prior_features: [MP-R1]
prior_findings: [RC-03, RC-15]
size_owner: n/a (new files)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C3-T01 — Machine settings loader

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C3 "Machine settings and `aiur mobile` CLI".
- **User value:** mobile setup is a machine-level setting that does not change what `aiur` does in
  any repository (RC-03), and a typo names the offending key.
- **Deliverable:** `Aiur.Machine.Settings` (PROPOSED): `path/0` (`~/.aiur/machine`),
  `load/0 :: {:ok, %Settings{}} | {:error, {:invalid, [{dotted_key, message}]}} | {:error, {:unreadable, reason}}`,
  `get/0` (mtime-cached `load/0`, safe in hot paths such as `TokenVerifier` and `AdvertWriter`),
  `write/1` (atomic, preserves unknown top-level sections), and an Ecto embedded schema tree rooted
  at `Aiur.Machine.Settings.Schema` under `src/lib/aiur/machine/settings/schema/` so MP-N2-C3-T05
  can walk it like `scripts/check-config-docs.py` walks `Aiur.Config.Schema`.
- **Non-goals:** CLI verbs (T02), docs checker (T05), relay keys (MP-N4 adds a `relay` section later).

## Dependencies and blockers

- DESIGN-N2 gate. **Q1 (store settings in `~/.aiur/machine`) is settled by RC-03** — no longer an owner question for this ticket.
- Concurrent with: everything in C1/C2. Dependents: MP-N2-C1-T03, MP-N2-C2-T01, MP-N2-C3-T02/T05,
  MP-N2-C4-T01, MP-N2-C10-T01/T02.

## Verified starting point (base `45a290e3`)

- `~/.aiur/config` is the fallback **workflow** config (`Aiur.Workflow.resolve_config_path/1`,
  `src/lib/aiur/workflow.ex:84-93`); creating it changes every unconfigured directory (RC-03).
- Machine-level sibling precedent: `Aiur.Init.Scaffold.global_alerts_path/0` = `Path.expand("~/.aiur/alerts")`
  (`src/lib/aiur/init/scaffold.ex:32-33`).
- YAML reads must go through `Aiur.Yaml.read_from_file/1` (`src/lib/aiur/yaml.ex:26-31`), which avoids
  the `:application_controller` wedge (#2474, #2548) — matters because the loader is called from
  shutdown-adjacent paths (advert removal) and from the lean gateway, where `:yamerl` may not be started.
- Config schema style to mirror: Ecto `embedded_schema` with `field/3` and `cast/3`
  (`src/lib/aiur/config/schema/server.ex:1-22`); the docs checker discovers keys by regex over
  `embeds_one`/`field` (`scripts/check-config-docs.py:86-127`).
- Contract §8, §8.1 (key list and defaults).

## Chosen design

Schema (all optional in the file; defaults shown):

| Dotted key | Type | Default | Validation |
|---|---|---|---|
| `mobile.enabled` | boolean | `false` | — |
| `gateway.host` | string | `"127.0.0.1"` | parses as IP or resolvable host |
| `gateway.port` | integer | `4710` | 1..65535 (0 forbidden: endpoints must be stable) |
| `gateway.endpoints` | list of strings | `[]` | each an absolute `http`/`https` URL without path/query |
| `pairing.secret_ttl_seconds` | integer | `600` | 60..3600 |
| `pairing.max_devices` | integer | `20` | 1..200 |
| `pairing.pin_rotation_grace_seconds` | integer | `604800` | ≥ 3600 (T-B only) |
| `transport.tls.cert_file` | path | `null` | expanded `~`; existence checked by MP-N2-C10-T01, not here |
| `transport.tls.key_file` | path | `null` | as above |
| `transport.tls.bind_host` | string | `null` | IP literal |
| `transport.tls.advertise_host` | string | `null` | DNS name, no scheme/port |
| `transport.allow_cleartext_overlay` | boolean | `false` | — |

- Missing file → `{:ok, defaults}` (mobile disabled). Empty file → defaults.
- Unknown keys inside known sections → `{:error, {:invalid, [{"gateway.hots", "unknown key"}]}}`;
  unknown **top-level** sections are preserved and ignored (forward compatibility with MP-N4 `relay`).
- Errors list every bad key with its full dotted path (acceptance from chunks.md: "validation errors name the key").
- `get/0` caches by `{mtime, size, inode}` in `:persistent_term`; a read error after a successful
  load keeps the last good value and records `last_error` (exposed in `aiur mobile status`), except
  that a missing file returns defaults (operator deleted it on purpose).
- `write/1` re-serializes with comments lost; DESIGN-N2 decides whether the CLI edits the file at all
  or prints instructions (default here: `aiur mobile enable|disable` writes `mobile.enabled` only,
  and tells the operator so). Written 0600 via `Aiur.Fs.atomic_write/3`.
- **Never** read by `Aiur.Workflow` or `Aiur.Config`; a test asserts that.

## Implementation steps

1. `src/lib/aiur/machine/settings.ex` and `settings/schema.ex` + `schema/{mobile,gateway,pairing,transport,tls}.ex` (PROPOSED).
2. YAML emitter: a small hand-written emitter for this fixed shape (no new dependency; `yaml_elixir`
   only parses). 3. Tests. About 230 production lines.

## Non-happy paths

| Case | Result |
|---|---|
| YAML syntax error | `{:error, {:unreadable, message}}`; `mobile.enabled` treated as false by callers that need a decision (fail closed). |
| `gateway.port: 0` | invalid with message "must be fixed so paired phones keep a valid endpoint". |
| `~/.aiur` missing | `write/1` creates it 0700. |
| File world-readable | Loaded (no secrets in it) but `aiur mobile status` warns. |

## Compatibility and rollout

New file; nothing reads it until other MP-N2 tickets land. `~/.aiur/config` is never created or read.

## Verification

`src/test/aiur/machine/settings_test.exs` (HOME = temp dir per test):

1. `"missing file yields defaults with mobile disabled"`.
2. `"transport section parses all five keys"`. *Fails without:* the transport schema.
3. `"unknown key in a known section is reported with its dotted path"` (`gateway.hots`). *Fails without:* the strict cast.
4. `"unknown top-level section is preserved across write"` (`relay: {x: 1}`).
5. `"gateway.port 0 is rejected"`.
6. `"get/0 returns the last good value after the file becomes invalid and reports last_error"`.
7. `"enable never creates ~/.aiur/config"` (acceptance 2) — after `write(%{mobile: %{enabled: true}})`,
   `File.exists?(Path.expand("~/.aiur/config"))` is false. Guard test (future regression); comment says so.
8. `"workflow loader does not read ~/.aiur/machine"` — source scan: `git grep`-equivalent over
   `src/lib/aiur/workflow.ex` and `config.ex` for `"machine"` path literals (future-regression guard).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/settings_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 2, 3, 6 recorded.
- [ ] Docs: the keys are documented by MP-N2-C3-T05 (checker) in the same PR or the next; this
      ticket adds the "Machine settings (`~/.aiur/machine`)" section to
      `website/docs-app/reference/configuration.md` with one line per key using the `machine:` prefix
      convention defined in T05.
