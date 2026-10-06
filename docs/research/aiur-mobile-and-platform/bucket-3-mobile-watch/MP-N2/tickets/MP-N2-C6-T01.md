---
ticket_id: MP-N2-C6-T01
feature_id: MP-N2
chunk_id: MP-N2-C6
bucket: 3-mobile-watch
title: "Instance `AiurWeb.DeviceAuth`: accept device bearer tokens on `:dashboard_auth` routes; advert `mobile_device_auth` flag"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T03, MP-N2-C5-T03, MP-N2-C2-T01, MP-R3-C1-T01, MP-N2-C10-T01]
prior_units: [U6]
prior_boundaries: [WEB]
prior_features: [MP-R3, MP-R1]
prior_findings: [security M3 (transport check), m8 (device:<id>)]
size_owner: "WEB — router.ex is in the U8 ledger (MP-N2-C6 named there); look up the owner at the implementation SHA"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C6-T01 — Device bearer on instance routes

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C6 "Instance device authentication".
- **User value:** a paired phone reads any instance on the machine (capabilities, state, Commands)
  with its own short-lived token, without ever holding the shared dashboard password; revoking the
  phone cuts it off on the next request without restarting any instance.
- **Deliverable:** `AiurWeb.DeviceAuth` (PROPOSED `src/lib/aiur_web/device_auth.ex`) used inside
  `AiurWeb.Router.dashboard_basic_auth/2`: a request carrying `Authorization: Bearer aiurd_…` is
  authenticated against the machine store; otherwise today's Basic-Auth path runs unchanged. The
  instance advert's `mobile_device_auth` flag (MP-N2-C2-T01) is set from the same predicate.
- **Non-goals:** WebView sessions (C6-T02), JSON write rules (C6-T03), the supervisor bearer
  (`/api/v1/decisions`, unchanged).

## Dependencies and blockers

DESIGN-N2 (gate; no UI); MP-N2-C1-T03 (`Machine.Store.verify_token/1`, mtime cache, constant-time
compare); MP-N2-C5-T03 (token format `aiurd_`); MP-N2-C2-T01 (advert writer); MP-R3-C1-T01 (route
auth census, which must list the device pipeline as an allowed authenticator — CONTRACT-REQUESTS
item 2); MP-N2-C10-T01 (Phase D: `HttpServer.bound_address/1` for the M3 transport check). Concurrent with C6-T02/T03 after the predicate below exists.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur_web/router.ex:9-15`: `:dashboard_auth` and `:dashboard_auth_required` both call
  `dashboard_basic_auth/2` (`:201-211`), which calls `FinancialDataAccess.authenticate_request/2`.
- `src/lib/aiur_web/financial_data_access.ex:50-84`: Basic Auth via `Plug.BasicAuth`, then stages a
  session marker in `conn.private[:aiur_financial_data_session_marker]` (`:20,:82`);
  `Proof.configuration/2` (`financial_data_access/proof.ex:11-52`) returns
  `:authentication_not_configured` (→ 503) when no Basic-Auth pair exists.
- `src/lib/aiur_web/supervisor_auth.ex:54-82`: bearer header parsing (single header, `Bearer`
  scheme, case-insensitive) and digest compare — the pattern reused here.
- Routes protected by `:dashboard_auth`: static assets (`router.ex:111-131`), LiveViews
  (`:133-149`), writes (`:153-178`), reads `/api/v1/state`, `/api/v1/:issue_identifier`
  (`:186-199`).

## Chosen design

```elixir
def dashboard_basic_auth(conn, opts) do
  case AiurWeb.DeviceAuth.classify(conn) do
    :no_bearer -> existing_basic_auth(conn, opts)            # unchanged path
    {:bearer, token} -> AiurWeb.DeviceAuth.authenticate(conn, token)
  end
end
```

- `classify/1`: exactly one `authorization` header whose scheme is `Bearer` and whose token starts
  with `aiurd_` → `{:bearer, token}`. Any other bearer (e.g. a supervisor token sent to the wrong
  route) is `:no_bearer`, so Basic Auth answers as today (no behaviour change for existing callers).
- `authenticate/2`:
  - **transport check first (Phase D, security M3; pairing security sibling §S3)**, before any
    store read: accept only when (a) `conn.scheme == :https` (the HTTPS listener, MP-N2-C10-T01), or (b) `conn.remote_ip` is `{127,0,0,1}` or `::1` (only those count as loopback, MP-R3-C1-T01), or
    (c) `conn.scheme == :http`, `transport.allow_cleartext_overlay` is true
    **and** the HTTP listener's bound address (`Aiur.HttpServer.bound_address(:http)`, from
    `Bandit.PhoenixAdapter.server_info/2`, PROPOSED in MP-N2-C10-T01) is inside `transport.cleartext_overlay_cidrs`
    (default `100.64.0.0/10`, `fd7a:115c:a1e0::/48`; a wildcard bind never matches). Else
    `401 {"error":"device_auth_insecure_transport"}`. One D19 token works on every instance,
    so a token sniffed on one cleartext port must not be usable anywhere;
  - mobile disabled or no machine store → `401 {"error":"device_auth_disabled"}`;
  - store unreadable/corrupt → `401 device_auth_unavailable` (fail closed, contract §9);
  - `verify_token/1` → `{:ok, device}` sets `conn.private[:aiur_auth] = {:device, device_id}`,
    `assigns[:auth_actor] = %{kind: :device, id: "device:" <> device_id, actor_source: :device}`
    (the single attribution spelling, command contract §6, security m8: every writing
    controller reads `auth_actor` instead of hard-coding `"dashboard"`), **does not** stage a session marker
    (bearer requests are stateless); `{:error, :expired}` → `401 token_expired`;
    `{:error, :revoked}` → `401 device_revoked`.
- Authority: identical to a Basic-Auth operator on that instance (D19, contract §4.4) — the plug
  only authenticates; `:api_write` and `:require_writable` still run after it.
- Predicate `DeviceAuth.enabled?/0` = mobile enabled ∧ store readable; used for the advert flag.
- Logs carry `device_id` only.

## Implementation steps

1. `src/lib/aiur_web/device_auth.ex` (≈ 150 lines, including the M3 transport check and CIDR
   match via `:inet` address tuples). 2. Two-line branch in `router.ex`
   `dashboard_basic_auth/2`. 3. Advert flag wiring (C2-T01 calls `DeviceAuth.enabled?/0`).
4. Writing controllers that accept `:dashboard_auth` (`observability_api_controller.ex`
   message and Command actions) take the actor from `conn.assigns[:auth_actor]` when present
   (m8).

## Non-happy paths

| Case | Behaviour |
|---|---|
| Revoked while a request is in flight | Next request fails (store mtime changes → cache miss). |
| Token for another machine | Hash not in this store → `device_revoked` (no oracle). |
| Bearer and Basic both sent | Bearer path wins; Basic is ignored (documented). |
| Mobile disabled after tokens were issued | `device_auth_disabled` immediately (predicate read per request through the cached settings). |
| `dashboard_writable: false` | Reads work; writes still 403 from `:require_writable`. |
| Bearer on a LAN-bound plain-HTTP listener | `401 device_auth_insecure_transport`, store not read (M3). |
| `allow_cleartext_overlay: true` but HTTP bound to `0.0.0.0` | refused: the flag alone is never enough (M3). |
| Local reverse proxy forwarding remote traffic to loopback | accepted as loopback; the token is the boundary, and the pairing guide says so (MP-N2-C9-T01). |

## Compatibility and rollout

Without `aiurd_` bearers, every request takes the existing path: all current Basic-Auth,
Stream Deck and supervisor tests must pass unchanged (MP-N2 plan acceptance 1).

## Verification

`src/test/aiur_web/device_auth_test.exs` (temp store, `Plug.Test` conns through the router):

1. `"valid device token reads /api/v1/state without basic auth configured"`. *Fails without:* the
   router branch.
2. `"revoked device gets 401 device_revoked on the next request without restart"`. *Fails without:*
   the mtime-keyed re-read (mutation: cache forever).
3. `"expired token gets token_expired"`. *Fails without:* expiry check (mutation from MP-N2 chunks).
4. `"mobile disabled returns device_auth_disabled and basic auth still works"`.
5. `"non-aiurd bearer falls through to basic auth"` (future-regression guard; comment says so).
6. `"device token cannot POST /api/v1/:id/messages on a read-only dashboard"` → 403 `dashboard is read-only`.
7. `"logs contain device_id and never the token"`.
8. **`"device bearer on a non-loopback plain-HTTP listener is refused"`** (security M3) — conn
   with `scheme: :http`, `remote_ip {192,168,1,20}`, injected bound address
   `{192,168,1,5}` → `401 device_auth_insecure_transport`, and the injected store reader is not
   called. *Fails without:* the listener check (remove it and the request gets 200).
9. `"cleartext overlay accepted only when the bound address is in an overlay CIDR"` — bound
   `100.101.2.3` + flag true → 200; bound `0.0.0.0` + flag true → 401; bound `100.101.2.3` +
   flag false → 401. *Fails without:* the CIDR check (flag-only implementation passes the
   first and third rows and fails the second).
10. `"HTTPS listener and loopback peers accept the bearer"` — guard must not over-match.
10a. Bind-matrix extension in the MP-R3-C1-T01 suite (`src/test/aiur/http_server_credential_gate_test.exs`):
   `"device bearer refused on a LAN-bound plain HTTP listener"` for binds `0.0.0.0`, `::` and a
   private LAN address, with and without `allow_cleartext_overlay`, through a real bound
   listener. *Fails without:* the transport check.
11. `"message sent with a device bearer records device:<id>"` (m8) — POST
   `/api/v1/:issue/messages` with a bearer → the queued operator message's actor id is
   `"device:<id>"`, not `"dashboard"`. *Fails without:* the controller reading `auth_actor`.

Existing suites that must stay green: `test/aiur/http_server_credential_gate_test.exs`, every
`test/aiur_web/*router*` and Stream Deck session test.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur_web/device_auth_test.exs test/aiur_web test/aiur/http_server_credential_gate_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded.
- [ ] MP-R3-C1 census updated to list `AiurWeb.DeviceAuth` as an authenticator.
- [ ] Docs: `website/docs-app/apis/` or the pairing guide states that device tokens carry operator
      authority and that `observability.dashboard_writable` still governs writes.
- [ ] Dependents: MP-N2-C6-T02, MP-N2-C6-T03, MP-R1-C3 capability endpoint (accepts device tokens via this plug).

## Phase D additions (contract requests CR-N5-1, CR-N6-1, E5 R-2)

- Also define the router pipeline `:device_auth` for device-only scopes
  (`/api/v1/device/*`): bearer required, no Basic-Auth fallback, same errors as above.
- On success both paths set `conn.assigns.device_id` (besides `auth_actor`); routes never
  read a device id from the body. Consumers: MP-N5-C1-T03, MP-N6-C1-T01, MP-E5-C8-T01.
- Test: "`:device_auth` route rejects Basic Auth with 401" and "device_id assign equals the
  token's device" (mutation: read `device_id` from params → fails).
