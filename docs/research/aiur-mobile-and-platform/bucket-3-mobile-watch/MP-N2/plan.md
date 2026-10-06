---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-N2
base_main_sha: 45a290e3
date: 2026-10-06
bucket: 3 (mobile and watch)
owner_gate: DESIGN-N2
owned_contracts: [contracts/pairing-and-instance-registry.md]
chunks_file: chunks.md
---

# MP-N2 — Machine-level pairing and instance discovery: Plan

## Goal capsule

- **Outcome:** a phone (later a watch) pairs **once per machine** by scanning a
  QR code, then finds every aiur instance on that machine, as instances start,
  stop, crash and move, without pairing again. Pairing gives full access to every
  instance on that machine (D19). Each device can be revoked, and any paired
  device can unpair everything.
- **Not in scope:** the meta-dashboard screen (MP-N3), push transport (MP-N4),
  the app framework (MP-N1), watch UI (MP-N7), making an instance reachable from
  the network (MP-R3), multi-repository instances (brief §3).
- **Blockers:** DESIGN-N2 (owner), RQ-N2-1 transport (shared with N1/R3), MP-R1
  component boundary for a lean "gateway" boot.

## 1. Repository findings (extends baseline §N2)

All references are at `45a290e3`. `engine` = `packaging/npm/aiur-cli/libexec/aiur-engine.sh`.

**Instance identity and records**

- F1. The instance key is the first 10 hex chars of sha256(realpath(project root)),
  `aiur_instance_key` (engine:269-278). The project root is the nearest directory
  holding `.aiur/config` below `$HOME`, otherwise the cwd (engine:221-241). So a
  global-config run is keyed by the directory it was launched from (engine:217-220).
- F2. The node is `aiur-$USER[-KEY]@127.0.0.1` (engine:294). The distribution is
  loopback-only, and every instance of a user shares one cookie file
  `~/.config/aiur/cookie` (engine:280-286, ownership and size checks engine:321-347).
- F3. `write_aiur_instance_record` (engine:1586-1612) writes
  `~/.config/aiur/instances/<node-slug>.instance` with mode 0600 and fields
  NODE, INSTANCE_KEY, SESSION, SOCKET, AGENT_TMPFILE, SURFACE_MODE,
  WORKSPACE_ROOT_FILE, PROJECT_ROOT, PROJECT_ROOT_SOURCE, WRITTEN_AT. It has
  **no dashboard URL, port or repository**.
- F4. **Correction to the baseline** ("never garbage-collected"): the record is
  deleted on a clean session exit (`session_cleanup`, engine:2104) and by
  `aiur stop` (engine:3619). Records survive only when the launcher dies without
  cleanup (a crash, or a kill of the wrapper). The owner's 8 stale records are
  crash leftovers, so "record present + node down" is a meaningful `crashed` signal.
- F5. Records are read by **shell `source`** (`load_aiur_instance_record`,
  engine:2174-2191, `source "$file"` at engine:2187). Any new writer of these files
  would create a code-execution surface. MP-N2 therefore adds a separate JSON
  advertisement file and never writes `.instance` files.
- F6. The only reader is `resolve_control_identity_from_records` (engine:2206-2260).
  It adopts a record only for a cwd-keyed caller whose own node is down, and checks
  each record's node in epmd (`probe_node_liveness`, engine:2136-2149;
  `probe_named_node_liveness`, engine:2166). There is no list command, though
  `warn_other_aiur_daemons` (engine:3511-3530) already scans `pgrep` and `ss` for
  sibling daemons and their ports.
- F7. Control RPC is `"$release_bin" rpc <expr>` over distribution with a watchdog
  timeout (`run_release_rpc_with_timeout`, engine:2333-2387). `aiur status` is
  `Aiur.AgentControlCLI.status()` (engine:2612-2615). This is the existing local
  control plane a machine-level reader can reuse.

**Dashboard URL, binding and auth**

- F8. `server.port` defaults to 0 and `server.host` to `127.0.0.1`
  (`src/lib/aiur/config/schema/server.ex:12-13`). A fresh random port is picked
  each boot. `Aiur.HttpServer.base_url/0` returns a URL only when Bandit really
  bound (`http_server.ex:141-156`), and `display_host/1` maps `0.0.0.0` to
  `127.0.0.1` (`http_server.ex:264`), so the URL it returns is not phone-usable for
  an all-interfaces bind. The launcher prints it via `probe_dashboard_status`
  (engine:1936-1953) but does not persist it.
- F9. Bind guard: a non-loopback bind without `AIUR_DASHBOARD_USERNAME/PASSWORD`
  refuses to start, and a loopback bind without them starts but refuses every
  request (`guard_dashboard_credentials`, `http_server.ex:167-202`). A port conflict
  disables only that instance's dashboard (`http_server.ex:204-211`).
- F10. Dashboard auth is one shared Basic-Auth pair. A successful request stages a
  session proof (`FinancialDataAccess.authenticate_request`,
  `financial_data_access.ex:50-84`); LiveView re-checks it on mount (`:98-111`). The
  session `secret_key_base` is random per boot (`http_server.ex:268-270`), so every
  restart invalidates every browser session.
- F11. The router protects reads with `:dashboard_auth` and writes with
  `:api_write` (same origin plus `X-Aiur-Request: 1`) and `:require_writable`
  (`router.ex:41-62,151-199`). The supervisor bearer (`supervisor_auth.ex:28-82`) is a
  separate identity, compares sha256 digests in constant time, and re-reads its
  env var per request. That is a usable pattern for a device-token plug.

**Global machine configuration**

- F12. `~/.aiur/config` is **not** a layered machine config. It is the fallback
  workflow config used only when `./.aiur/config` is absent
  (`Aiur.Workflow.resolve_config_path/1`, `src/lib/aiur/workflow.ex:84-93`). A
  repo-local run never reads it.
- F13. A machine-level sibling-file precedent exists: `~/.aiur/alerts` ("Sounds are
  machine-level", `src/lib/aiur/init/alerts.ex:19-20`; path
  `Aiur.Init.Scaffold.global_alerts_path/0`, `init/scaffold.ex:32-33`).
  `aiur init` already asks repo versus global (`init/questions.ex:15-44`).
- F14. Config keys are machine-checked against the docs by
  `scripts/check-config-docs.py` (AGENTS.md "Docs ship with the change"). That
  checker covers `.aiur/config` keys; a new `~/.aiur/machine` file needs its own
  docs entry and, ideally, a checker extension (MP-N2-C3).

**Boot shape**

- F15. `Aiur.Application` (`src/lib/aiur.ex:31-118`) starts about 90 children under
  `:rest_for_one`, including `Aiur.Orchestrator` (`aiur.ex:442`). `child_specs/1`
  varies headless, dashboard and recording (`aiur.ex:244-260`), but has no shape
  without the orchestrator. A gateway that "does not need the orchestration stack"
  (brief N2) needs a new lean boot path. That is MP-R1's call (assumption A1).

**Not found** (searched in baseline §6 plus this pass): pairing, QR, device
tokens, mDNS, a machine id, an `instances` list command, an advertised URL
setting, or any HTTP surface that lists sibling instances.

## 2. Proposed boundaries

| Component (proposed) | Responsibility | Public interface | Required deps | Optional deps | Prior refs |
| --- | --- | --- | --- | --- | --- |
| `aiur_machine` store library | machine identity, machine key, device rows, pairing secrets, token hashes, journal (contract §5) | `Machine.Store.{identity, devices, put_device, revoke, unpair_all, verify_token}` | `aiur_kernel` (paths, JSON) | — | Prior-boundaries: `K`, `CFG` |
| Instance advertiser (inside the instance daemon) | write and refresh `<slug>.advert.json`; expose `Aiur.InstanceSummary.v1/0` (MP-N3) | the file shape (contract §6.1); one RPC function | `WEB` (`HttpServer.base_url`) | dashboard (absent means `bound: false`) | `WEB`, `CLI` |
| Device-auth plug (inside the instance web layer) | accept gateway-minted tokens; `/api/v1/device-session` | `AiurWeb.DeviceAuth` plug | `aiur_machine` store (read-only) | — | `WEB` #34 |
| **Machine gateway** (new process, one per user per machine) | pairing endpoints, token minting, device management, instance registry, summary fan-out | HTTP API `aiur.machine/v1` (contract §4, §6.3) | store library; `release_bin rpc` or a distribution client | instances (zero instances is a valid state) | `launcher` #32 (stays until the control surface is a versioned protocol) |
| `aiur mobile …` CLI (launcher engine) | enable, disable, status, qr, devices, revoke, unpair-all, gateway start/stop | CLI | gateway or store library | — | `CLI` #31, launcher |

Required versus optional: pairing and discovery need **only** the store, the
gateway and the CLI. They work with zero instances running, with instances
started with `--no-dashboard` (the summary still flows over RPC; only "Open
dashboard" is unavailable), and without build orders, voice, the Stream Deck or
Tailscale.

## 3. Alternatives and recommendation

**A. Where does machine-level pairing and discovery live?**

| Option | Pros | Cons |
| --- | --- | --- |
| A1. Each instance serves pairing and lists its siblings | No new process | Nothing to pair with when no instance runs; random ports (F8); N copies of the device registry, or an election between them; couples pairing to the orchestrator (against the brief) |
| **A2. A lightweight per-user gateway (recommended)** | One stable endpoint per machine; runs with zero instances; single writer of the device store; matches "machine-level" | A new process with a lifecycle; needs a lean boot (A1 assumption) |
| A3. A cloud registry or relay | Works across NAT | Violates "Cloudflare/personal infrastructure not mandatory"; leaks instance metadata |
| A4. mDNS or Bonjour discovery | Zero configuration on a LAN | Does not work across a tailnet or for remote use; still needs authorization; adds a new dependency |

Recommend **A2**. The gateway runs from the same release, in a new lean boot
shape (web endpoint and store, no orchestrator, no tracker, no agents), as a
distinct node `aiur-$USER-machine@127.0.0.1`. Reusing the release avoids a second
runtime (the Stream Deck sidecar is TypeScript, but it needs hardware SDKs; the
gateway does not). Lifecycle: `aiur mobile gateway start|stop|status`. When
mobile is enabled, every instance launch starts the gateway if it is not running,
best effort and non-fatal. Optional user units (systemd user unit or launchd
agent) are documented, not installed automatically.

**B. How does the gateway read instance data?**

| Option | Verdict |
| --- | --- |
| **B1. Control RPC to each instance node (recommended)** | Reuses the existing plane (F7), works with `--no-dashboard`, needs no loopback HTTP credential. Version skew yields `undef`, which is reported as `unsupported`. |
| B2. Loopback HTTP to each dashboard with an internal token | Fails for `--no-dashboard` and port-conflicted instances (F9); adds a credential. |
| B3. Instances push summaries into files | Easy to read, but stale-by-design, and it writes sensitive counts to disk every few seconds. |

**C. Device credential.**

| Option | Verdict |
| --- | --- |
| C1. A long-lived bearer per device | Simplest, but cannot be hardware-bound; a leak lasts forever. |
| **C2. A hardware-bound P-256 key plus 15-minute opaque tokens (recommended)** | The key never leaves the Secure Enclave or Keystore (contract §2 sources); a token leak is time-bounded; revocation is immediate because instances read the store. |
| C3. Sign every request (RFC 9421 HTTP message signatures) | Strongest replay protection, but a WebView cannot sign its own subresource and LiveView socket requests, so a session bootstrap is still needed. Revisit if RQ-N2-1 forces cleartext transport. |

**D. Where is the machine setting?** Recommend `~/.aiur/machine`, not a section
of `~/.aiur/config`, because of F12 (creating `~/.aiur/config` changes what every
unconfigured directory does). Owner question OQ-N2-1.

**E. How does the phone open an instance dashboard?** Recommend that it **opens
the instance URL directly** with a device-session bootstrap (contract §4.4). The
rejected alternative is a gateway reverse proxy under `/i/<key>/`: the dashboard
uses root-absolute paths (`/dashboard.css`, `/vendor/...`, `router.ex:114-130`) and
LiveView sockets, so a path-prefix proxy needs dashboard changes. A per-instance
port proxy remains a fallback if RQ-N2-2 shows that per-instance reachability is
too costly to configure. Consequence: the instance needs a phone-reachable bind and
a stable port (`server.port` pinned). The gateway reports when an instance is
loopback-only rather than hiding it.

## 4. Contracts

**Owned:** `contracts/pairing-and-instance-registry.md` (identity of machine and
device, credentials, QR payload, protocol, store, registry, summary envelope
shared with MP-N3, machine settings).

**Consumed (stated assumptions):**

- A1 (MP-R1, identity-and-capabilities): `instance_key` is unchanged; MP-R1 allows an
  `aiur_machine` component and a lean boot without `Aiur.Orchestrator`; a capability
  list is available per instance with states `available|disabled|unavailable|unsupported`.
  If MP-R1 lands after MP-N2, MP-N2-C4 adds the lean boot itself behind the boundary R1 names.
- A2 (MP-R3, reachability): the gateway reuses the explicit-host rule (no
  auto-detection, loopback default) and the "no non-loopback bind without a
  credential" guard. MP-R3 decides the operator wording and any HTTPS helper.
- A3 (MP-N1): the app can store a P-256 key in the Secure Enclave or Keystore, scan QR
  codes, and inject a cookie or Authorization header into its WebView for the
  device-session bootstrap. N1 decides ATS and cleartext policy (RQ-N2-1).
- A4 (MP-N4): the push registration is an opaque blob sent at claim time or later via
  `PUT /v1/devices/<id>/push`; N4 provides `deregister(device_id)`.
- A5 (MP-N7): a watch is either a child device or acts through its phone; both fit
  `parent_device_id`.
- A6 (MP-R2): not needed in v1. Registry and summary are pulled. A later event
  stream may replace polling without changing the contract's data shapes.

## 5. Non-happy paths

- **Capability absence:** no gateway, so the app says "Mobile is not enabled on this
  machine" with the CLI command. Zero instances gives an empty, non-error list. An
  instance with `--no-dashboard` shows its summary with a "Dashboard off" reason.
- **Stale data:** registry states are evidence-based (contract §6.3); a missing heartbeat
  is `stale`, never `live`. The gateway signs `observed_at`.
- **Restart recovery:** the gateway is stateless apart from the store; tokens survive a
  gateway restart (hashes on disk). An instance restart invalidates its browser session
  (F10); the app re-runs the device-session exchange.
- **Crash leftovers:** a record with a dead node is `crashed`. The gateway does not delete
  records (launcher-owned); `aiur mobile status` lists them with the age.
- **Duplicates:** a QR scanned twice relinks rather than adding a device; two instances of
  one repo are shown separately (contract §1); two gateways are prevented by the store lock.
- **Multiple devices:** independent rows; revoking one leaves the others alone;
  unpair-all includes the caller.
- **Multiple machines:** each paired independently; the device keeps one auth key per
  machine (no cross-machine linkability through a shared public key).
- **URL changes:** the device refreshes endpoints on every successful call; if all fail,
  a re-scan relinks.
- **Conflicting management actions:** a store write is atomic; revoke of an
  already-revoked device returns `404 device_unknown` and is treated as success by the client.
- **Privacy and security:** bearer over cleartext only on an encrypted overlay
  (contract §6.2); claim brute force lockout; QR signed by `machine_key`; a device never
  gets existing secrets; the gateway logs `device_id`, never tokens. A Basic-Auth holder
  can display the QR and so can pair a device: an equal-authority path, stated in DESIGN-N2.
- **Lost phone, no other device, away from the machine:** cannot unpair remotely without
  some authenticated channel. This is accepted as a limit (OQ-N2-4); tokens still expire,
  but the device key can mint new ones.

## 6. Acceptance criteria

1. With mobile disabled, no gateway runs, no machine store exists, instances reject
   bearer device tokens with `device_auth_disabled`, and every existing Basic-Auth and
   supervisor test passes unchanged.
2. `aiur mobile enable` creates `identity.json` (0600, owned by `$USER`) and the machine
   settings file without creating `~/.aiur/config`; `aiur` in an unconfigured directory
   behaves exactly as before.
3. A QR older than `secret_ttl_seconds`, or one already used, is refused with the matching
   error code; a correct claim creates exactly one device row.
4. With two instances running (one with `--no-dashboard`) and one crashed record, `GET
   /v1/instances` returns `live`, `live` with `dashboard.reachable_for_devices=false`, and
   `crashed`.
5. After `DELETE /v1/devices/<id>`, the next request from that device to the gateway and to
   any instance returns 401 `device_revoked`, without restarting any instance.
6. `unpair-all` from device B ends device A's and B's access in one store write, and its
   response reports control revocation and push deregistration separately.
7. Changing `gateway.endpoints` is seen by a paired device on its next successful call;
   a device whose endpoints all fail relinks by re-scanning without a second device row.
8. Over an instance restart, the WebView regains a session without user action.
9. No secret appears in `journal.ndjson`, gateway logs or `aiur mobile status` output (test
   greps for the token and secret values).

## 7. UX and UI → `owner-design-tasks/DESIGN-N2.md`

Surfaces: CLI enable and status, the `aiur init` optional step, the settings page with the QR,
the app first-run and scan flow, the device list, revoke, unpair-all, and the error states.
Implementation of every user-facing chunk is blocked until DESIGN-N2 is approved.

## 8. Decomposition

See [chunks.md](chunks.md): MP-N2-C1 store, MP-N2-C2 advertisement and registry reader, MP-N2-C3
settings and CLI, MP-N2-C4 gateway process, MP-N2-C5 pairing protocol, MP-N2-C6 instance device
auth, MP-N2-C7 revocation and unpair-all, MP-N2-C8 settings-page QR surface, MP-N2-C9 docs and
validation.

## 9. Open questions

**Owner (Kevin), also in DESIGN-N2:**

- OQ-N2-1 Machine settings file `~/.aiur/machine` instead of `~/.aiur/config` (F12)? Recommended: yes.
- OQ-N2-2 Should launching any instance auto-start the gateway when mobile is enabled? Recommended: yes, best effort.
- OQ-N2-3 Idle expiry for devices (for example 90 days unused)? Recommended: none by default.
- OQ-N2-4 Is "lost the only device and away from the machine" an accepted limit?
- OQ-N2-5 Which surfaces show the QR: terminal, the gateway's local page, every instance dashboard?
- OQ-N2-6 How long a stopped instance stays listed (contract: 7 days).

**Research (Phase C):**

- RQ-N2-1 Transport: ATS exception for the tailnet CIDR versus HTTPS (`tailscale cert` or an
  operator cert); behaviour on a LAN without an overlay. Shared with N1/R3.
- RQ-N2-2 Whether per-instance reachability (pinned ports, firewall) is acceptable or a
  gateway per-instance port proxy is needed.
- RQ-N2-3 Lean boot: the minimal child set for the gateway node, and whether a separate
  release entry point is cleaner than a flag.
- RQ-N2-4 Whether distribution RPC from the gateway node (`:erpc`) or shelling to
  `release_bin rpc` is the better fit, and the timeouts per instance.
- RQ-N2-5 The WebView cookie injection API on the chosen framework (N1), and LiveView socket
  behaviour after a device-session bootstrap.
- RQ-N2-6 Store locking between the gateway and a CLI writing while the gateway is down.

## 10. Plan-refresh note

If MP-R1..R7 land first: the store library and gateway move to the package MP-R1 names for
`aiur_machine` (path `src/lib/aiur/machine/` here is a placeholder); the device-auth plug goes
into the `aiur_web` package (Prior-boundary `WEB` #34); the launcher commands stay in
`aiur-engine.sh` (boundary #32). If MP-R3 changes how hosts are resolved, the gateway takes
the same resolver. Tickets must re-check F3–F8 line numbers against the implementation SHA,
because U1 and U9 also own `aiur-engine.sh`.
