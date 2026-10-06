---
ticket_id: MP-N2-C6-T02
feature_id: MP-N2
chunk_id: MP-N2-C6
bucket: 3-mobile-watch
title: "WebView session bootstrap: one-time device-session code and a device kind of the dashboard session proof"
status: blocked
blocked_by: [DESIGN-N2, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C6-T01, MP-R1-C2-T02]
prior_units: [U6]
prior_boundaries: [WEB]
prior_features: [MP-N1]
prior_findings: []
size_owner: "WEB — financial_data_access.ex / proof.ex / router.ex; look up U8 owners at the implementation SHA"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C6-T02 — Device session for the WebView

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C6.
- **User value:** tapping an instance opens its dashboard in the app with no password prompt, and
  the LiveView stays authorized only while the device stays paired.
- **Deliverable:**
  1. `POST /api/v1/device-session` (bearer, C6-T01) → `200 {bootstrap_path: "/device-session/<code>?next=<path>", expires_in: 30}`.
  2. `GET /device-session/:code` (no auth header needed) → validates the code, stages a **device**
     session marker, `302` to `next` (same-origin path only), `Cache-Control: no-store`.
  3. A per-instance session cookie name `_aiur_key_<instance_key>` whenever device auth is enabled
     (contract §4.4, settled), for HTTP requests and for the `/live` and `/voice` socket
     `connect_info`.
  4. `Proof` gains a device marker kind; `context_from_session/3`, `identity/2` and
     `FinancialDataAccess.authorize/1` accept it while the device row is active.
- **Non-goals:** the app WebView host (MP-N1-C4-T02 calls these two endpoints); TLS (MP-N2-C10-T01).

## Dependencies and blockers

DESIGN-N2; **RQ-TRANSPORT and MP-N2-C10-T01** (RC-15: the WebView loads the dashboard; the session
cookie must ride an HTTPS origin); MP-N2-C6-T01. Dependents: MP-N1-C4-T02, MP-N3-C4 (open
dashboard), MP-N6 phone surfaces that open conversations.

## Verified starting point (base `45a290e3`)

- Session cookie `_aiur_key`, `store: :cookie`, signed (`src/lib/aiur_web/endpoint.ex:8-12`);
  `secret_key_base` random per boot (`src/lib/aiur/http_server.ex:268-270`), so sessions die on
  restart (contract §4.4 "silently repeats this exchange").
- `:browser` pipeline: `fetch_session` then `FinancialDataAccess.persist_session`
  (`router.ex:28-35`; `financial_data_access.ex:86-93`).
- The marker is bound to the **Basic-Auth configuration**: `Proof.configuration/2` derives
  `configuration_generation` from username, password and enforcement (`financial_data_access/proof.ex:18-38`);
  `context_from_session/3` and `identity/2` re-derive it on every check (`proof.ex:79-124`). With no
  Basic-Auth pair configured, no marker can be created or verified. A device session therefore
  **cannot** reuse today's marker as contract §4.4 assumed; it needs its own kind (CR-N2-4).
- Consumers of `identity/1` / `authorize/1`: `financial_data.ex:41,78,114`,
  `financial_data/cache.ex:64,92`, `cache/pending.ex:141,176`, `subscription_authority.ex:41,102`,
  `voice_socket.ex:25-26`, plus LiveView `on_mount` (`financial_data_access.ex:98-111`).

**RQ-N2-5 resolution (cookie injection).** The bootstrap uses a one-time URL the WebView navigates
to, so the server sets `_aiur_key` itself in a normal top-level response. No WebView cookie API and
no custom request headers on the initial load are needed (Android `WebView.postUrl` cannot carry
headers; per-origin cookie injection behaviour across process death was N1-RQ5). This removes both
platform dependencies.

## Chosen design

- **Code:** 32 random bytes b64url, stored in an ETS table owned by an instance process
  (`AiurWeb.DeviceSessionCodes`, PROPOSED) as `{sha256(code), device_id, next, expires_at = now+30s}`;
  single use (deleted on lookup). `next` must match `^/[^/]` and is re-validated against the router
  (unknown path → `/`).
- **Device marker:**
  `%{"version" => 1, "kind" => "device", "device_id" => id, "connection_generation" => cg,
  "proof" => HMAC(secret_key_base, {"financial-data-device-access", 1, id, cg})}`.
- **Verification:** `context_from_session/3` dispatches on `"kind"`. Device kind → verify the HMAC,
  then `Machine.Store.device_active?(id)` (mtime-cached read; revoked → `:error`). The returned
  `Context` gets `configuration_generation: "device:" <> id`, so existing callers comparing identities
  still compare equal for the same session and different across devices.
  `identity/2` repeats the active check, so a LiveView that re-authorizes (`financial_data.ex:78`)
  loses access after revocation without a reload.
- **Revocation push-down:** on store change the instance broadcasts
  `ObservabilityPubSub` `{:device_revoked, id}`; `FinancialDataAccess.Generation`-style listeners
  re-check on next event. Minimum guarantee: next authorize call fails.
- **Cookie name per instance (contract §4.4).** Cookies do not isolate by port (RFC 6265 §8.5,
  <https://www.rfc-editor.org/rfc/rfc6265#section-8.5>, accessed 2026-10-06), and every instance on
  a host shares `advertise_host`, so one WebView cookie jar would hold a single `_aiur_key` for all
  instances and each bootstrap would overwrite the previous instance's session. Today the options are
  a compile-time attribute used by `plug(Plug.Session, @session_options)` (`endpoint.ex:8-12,76`) and
  by both sockets' `connect_info` (`:15,:27`). Change: a new plug `AiurWeb.InstanceSession`
  (PROPOSED) replaces `plug(Plug.Session, …)`; it builds `Plug.Session.init/1` options at runtime
  once per boot (cached in `:persistent_term`) with `key: "_aiur_key_" <> instance_key` when
  `DeviceAuth.enabled?/0`, else `"_aiur_key"` (byte-identical to today). Both sockets use
  `connect_info: [session: {AiurWeb.InstanceSession, :options, []}]`; Phoenix supports an MFA for
  runtime session config ("`session_config` may be a MFA … to allow loading config in runtime",
  <https://phoenix.hexdocs.pm/1.8.1/Phoenix.Endpoint.html>, accessed 2026-10-06; recheck against
  the pinned phoenix 1.8.9). `instance_key` comes from MP-R1-C2-T02.
- Other cookie attributes unchanged; on HTTPS the WebView stores it per host.

## Implementation steps

1. `device_session_controller.ex` (POST + GET), routes: POST under `[:dashboard_auth]` (bearer
   only — reject Basic for this route with 403 `device_token_required`), GET under `[:browser]`.
2. `DeviceSessionCodes` ETS owner in the instance web tree.
3. `proof.ex`: device kind in `context_from_session/3` and `identity/2`; `new_device_marker/2`.
4. `financial_data_access.ex`: `stage_device_session/2` used by the GET handler.
5. `src/lib/aiur_web/instance_session.ex` and the three `endpoint.ex` call sites (`:15`, `:27`, `:76`).

About 280 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Code reused or older than 30 s | `401` page "Session link expired" (DESIGN-N2 copy); app re-bootstraps once (MP-N1-C4-T02). |
| `next` is absolute or external | Ignored; redirect to `/`. |
| Instance restart | Cookie invalid (new secret); the WebView gets the Basic-Auth challenge or 503; the app detects 401/503 and re-bootstraps once. |
| Device revoked with an open LiveView | Next authorize fails; the page shows its locked state; the app's next API call gets `device_revoked`. |
| Basic Auth also configured | Both marker kinds coexist; a browser user is unaffected. |

## Compatibility and rollout

Basic-Auth markers are byte-identical to today (`"kind"` absent = Basic). Tests for existing
sessions must pass unchanged.

## Verification

`src/test/aiur_web/device_session_test.exs`:

1. `"bearer POST returns a bootstrap path; GET sets a session and redirects to next"`. *Fails without:* the controller.
2. `"code is single use"`; 3. `"code expires after 30 s"` (injected clock).
4. `"external next is replaced by /"`. *Fails without:* the path check.
5. `"device marker mounts a LiveView without basic auth configured"` (`Phoenix.LiveViewTest` `live/2`
   with the session). *Fails without:* the device kind in `context_from_session/3`.
6. `"revoked device: authorize fails on the next check"`. *Fails without:* `device_active?` in
   `identity/2` (mutation: drop it → test fails).
7. `"basic-auth marker unchanged"` (snapshot of marker keys; future-regression guard).
8. `"POST with basic auth and no bearer is refused"`.
9. `"two instances on one host keep separate sessions"` (two endpoints with different
   `instance_key`, one cookie jar: bootstrapping B leaves A's session valid). *Fails without:* the
   per-instance key (mutation: constant `_aiur_key` → A's LiveView mount loses authority).
10. `"device auth disabled keeps the cookie name _aiur_key"` (future-regression guard).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur_web/device_session_test.exs test/aiur_web
```

Device: MP-N2-C9-T02 row P5 and MP-N1 DV-P9 (session expiry and revocation).

## Completion and handoff

- [ ] Tests pass with mutation checks.
- [ ] CR-N2-4 (contract §4.4 rewritten to the one-time-code flow and device marker) applied by the owner.
- [ ] Docs: pairing guide "Opening a dashboard on the phone".
- [ ] Dependents: MP-N1-C4-T02 told the two endpoints and the retry rule.
