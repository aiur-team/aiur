---
ticket_id: MP-N2-C2-T01
feature_id: MP-N2
chunk_id: MP-N2-C2
bucket: 3-mobile-watch
title: Instance advertisement writer (<slug>.advert.json, 30 s refresh, device URL from the transport listener)
status: blocked
blocked_by: [DESIGN-N2, RQ-TRANSPORT, MP-N2-C3-T01, MP-N2-C10-T01, MP-R1-C2-T02, MP-R1-C3-T02]
prior_units: []
prior_boundaries: [WEB, CLI]
prior_features: [MP-R1, MP-N3]
prior_findings: [RC-02, RC-15]
size_owner: "aiur.ex child list (U8 ledger owner of src/lib/aiur.ex; look up at the implementation SHA)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C2-T01 — Instance advertisement writer

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C2 "Instance advertisement and registry reader".
- **User value:** the gateway learns, from each running instance, its `instance_id`, repository and
  the URL a phone can open — information the launcher record does not carry (no URL, no port, no
  repository; `aiur-engine.sh:1586-1612`).
- **Deliverable:** `Aiur.Machine.AdvertWriter` (PROPOSED, a `use Aiur.PeriodicWorker` GenServer in
  every instance daemon) that writes `<instances dir>/<node-slug>.advert.json` (0600) every 30 s
  while `mobile.enabled` is true, using `Aiur.Fs.atomic_write/3`.
- **Non-goals:** removal on stop (T02), parsing records (T03), state machine (T04), the summary RPC
  (MP-N3-C1; the advert only says whether `summary_rpc: "v1"` exists).

## Dependencies and blockers

- DESIGN-N2 gate; RQ-TRANSPORT and **MP-N2-C10-T01** (`Aiur.HttpServer.device_url/0` and the
  transport mode); MP-N2-C3-T01 (settings: `mobile.enabled`, `transport.*`).
- MP-R1-C2-T02 (daemon composes `instance_id` from the launcher's `AIUR_INSTANCE_KEY`) and
  MP-R1-C3-T02 (the `repository` section provider; MP-R1-C2 has no T03, and C2-T02 leaves the repository section to C3-T02). Until those exist this ticket cannot use one source of identity.
- Concurrent with: MP-N2-C1-*, MP-N2-C2-T03/T04.
- Dependents: T02, T04, MP-N2-C4-T04, MP-N3-C2.

## Verified starting point (base `45a290e3`)

- Launcher record path and slug: `aiur_instances_dir` = `$AIUR_BG_STATE_DIR/instances`
  (`aiur-engine.sh:1510-1512`), `aiur_state_slug` = `AIUR_RELEASE_NODE` with non `[A-Za-z0-9._-]`
  replaced by `_` (`:1506-1508`), record `<slug>.instance` (`:1514-1516`). The engine exports
  `AIUR_RELEASE_NODE` and `AIUR_INSTANCE_KEY` before booting the BEAM (`:294-298`); the daemon already
  reads `AIUR_INSTANCE_KEY` (`src/lib/aiur/config/paths.ex:332`).
- Child list: `Aiur.DaemonHeartbeatWriter` at `src/lib/aiur.ex:452`; `Aiur.HttpServer` at `:469`,
  only when `dashboard?`. `--no-dashboard` sets `:no_dashboard` (`src/lib/aiur/cli.ex:563-569`).
- `Aiur.HttpServer.base_url/0` (`src/lib/aiur/http_server.ex:141-156`) returns the loopback/bind URL
  or nil; `display_host/1` maps `0.0.0.0` to `127.0.0.1` (`:264`). `bound_port/1` at `:129-139`.
- Periodic worker skeleton with crash-isolated ticks: `src/lib/aiur/periodic_worker.ex:1-30`.
- Heartbeat cadence is 5 minutes (`src/lib/aiur/daemon_heartbeat_writer.ex:19`), too slow for the
  contract's 90 s liveness rule, so the advert has its own 30 s cadence.
- Contract §6.1 (advert shape), §6.3 (registry reasons), §8.1 (transport rules).

## Chosen design

Advert shape (contract §6.1 plus the additions requested to the contract owner, marked ★):

```json
{ "contract": "aiur.advert/v1",                    // ★ explicit version string
  "instance_id": "<machine_id>/<instance_key>",    // ★ RC-02
  "instance_key": "3f9a1c0b2e", "node": "aiur-kevin-3f9a1c0b2e@127.0.0.1",
  "repository": {"kind": "github", "owner": "…", "name": "…"},
  "project_root_basename": "aiur", "pid": "12345",
  "started_at": "…", "heartbeat_at": "…",
  "dashboard": { "bound": true, "base_url": "http://127.0.0.1:41234", "bind_host": "127.0.0.1",
                 "port": 41234, "loopback_only": true,
                 "device_url": "https://host.tailnet.ts.net:45555",   // ★ from device_url/0
                 "transport": "https" },                               // ★ https | http_overlay | none
  "mobile_device_auth": false, "summary_rpc": null }
```

- `device_url` = `Aiur.HttpServer.device_url/0` when non-nil (`transport: "https"`); else, when
  `transport.allow_cleartext_overlay` is true and the HTTP bind is non-loopback, the HTTP URL built
  from the **real bind host** (not `display_host`) and port (`transport: "http_overlay"`); else nil
  (`transport: "none"`). The gateway turns `none` into `reachable_for_devices: false,
  reason: tls_unavailable` (contract §6.3).
- `bind_host`: the configured `server.host` as bound, recorded raw.
- `mobile_device_auth`: false until MP-N2-C6-T04 sets it; `summary_rpc`: `"v1"` once
  `function_exported?(Aiur.InstanceSummary, :v1, 0)` (MP-N3-C1).
- **Never** contains the full project path, credentials, ports of other services, or Command text.
- Started unconditionally after `Aiur.HttpServer` in the child list (it must also run with
  `--no-dashboard`, writing `bound: false`). Each tick re-reads `mobile.enabled` through the settings
  loader's mtime cache; when false it writes nothing (and removes a stale own advert).
- Writes only its own `<slug>.advert.json`; never touches `.instance` files (contract §6.1).

## Implementation steps

1. `src/lib/aiur/machine/advert_writer.ex` (PROPOSED), `build/1` pure (takes a map of probes) and
   the worker that calls it.
2. `src/lib/aiur.ex`: add the child after `if(dashboard?, do: Aiur.HttpServer)` (`:469`).
3. Tests. About 160 production lines.

## Non-happy paths

| Case | Result |
|---|---|
| `--no-dashboard` | `bound: false, base_url: null, device_url: null, transport: "none"`. |
| Port conflict disabled the dashboard (`http_server.ex:204-211`) | Same as not bound. |
| Write fails (disk full, permissions) | Logged once per distinct error; the next tick retries; the gateway will see the advert age and report `stale`. |
| `AIUR_INSTANCE_KEY` empty (degraded identity, identity contract §1.2) | No advert written; one warning (the instance is not discoverable by design). |
| Mobile disabled at runtime | The next tick deletes this instance's own advert. |

## Compatibility and rollout

Nothing is written unless `mobile.enabled` is true. The file lives next to `.instance` records;
the launcher's record reader globs only `"$dir"/*.instance` (`aiur-engine.sh:2222`, inside `resolve_control_identity_from_records`), so it ignores adverts.

## Verification

`src/test/aiur/machine/advert_writer_test.exs` (temp `AIUR_BG_STATE_DIR`; probes injected):

1. `"https device url is advertised with transport https"`. *Fails without:* the `device_url/0` branch.
2. `"overlay mode advertises the real bind host, not display_host"` — `server.host` bound to
   `100.64.1.2`, overlay allowed, no TLS → `device_url == "http://100.64.1.2:<port>"`.
   *Fails without:* using the raw bind host (mutation: build the URL from `base_url/0`, which can
   yield `127.0.0.1` for an all-interfaces bind → the companion case with `0.0.0.0` plus
   `transport.tls.advertise_host: null` must yield `device_url: null`, not `127.0.0.1`).
3. `"no tls and no overlay advertises device_url null and transport none"`.
4. `"no-dashboard writes bound false"`.
5. `"advert never contains the project root path"` (fixture root `/tmp/x/secret-name/aiur` → only `aiur`).
6. `"mobile disabled writes nothing and removes an own stale advert"`.
7. `"file mode is 0600"`.
8. In `src/test/aiur/application_test.exs` (existing `child_specs/1` tests):
   `"advert writer is present with and without dashboard"`. *Fails without:* the unconditional child entry.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/advert_writer_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation results for 1, 2, 5 in the PR body.
- [ ] Contract request (parent): advert additions ★ in contract §6.1.
- [ ] Docs: none user-facing (described in the pairing guide, MP-N2-C9-T01).
