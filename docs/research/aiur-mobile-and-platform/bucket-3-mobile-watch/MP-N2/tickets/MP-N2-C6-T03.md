---
ticket_id: MP-N2-C6-T03
feature_id: MP-N2
chunk_id: MP-N2-C6
bucket: 3-mobile-watch
title: "`:api_write` for native device calls: bearer-authenticated requests skip the Origin check but keep `X-Aiur-Request` and `:require_writable`"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C6-T01, MP-N2-C10-T01]
prior_units: [U6]
prior_boundaries: [WEB]
prior_features: [MP-E2, MP-R3]
prior_findings: []
size_owner: "WEB — router.ex (U8 ledger); look up at the implementation SHA"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C6-T03 — Write rule for device callers

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C6.
- **User value:** the phone's native screens (answer a Command, send a message) can write to an
  instance with the device token, while browser CSRF protection stays exactly as strong as today.
- **Deliverable:** `verify_same_origin/2` passes a request when `conn.private[:aiur_auth]` is
  `{:device, _}` (set only by the bearer path of C6-T01). Everything else in `:api_write` and
  `:require_writable` is unchanged.
- **Non-goals:** WebView writes (they carry the session cookie and an `https://advertise_host:port`
  Origin, which MP-N2-C10-T01 already allow-lists); MP-E2's own Command-answer API rules.

## Dependencies and blockers

DESIGN-N2; MP-N2-C6-T01 (sets the private flag); MP-N2-C10-T01 (WebView origin). Dependents:
MP-N6 native answer screen, MP-N1-C3-T02 (typed write errors), MP-E2 Command answer route if it is
mounted under `:api_write`.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur_web/router.ex:41-53`: `:api_write` = `verify_same_origin` + `require_custom_header`;
  the comment says the Origin check defends against cross-site browser requests and that "curl +
  3rd-party scripts are legitimate callers as long as they come from the Executor's machine".
- `:215-226` `verify_same_origin/2` → 403 `origin not allowed`; `:260-301` origin parsing (a request
  without Origin or Referer is rejected, `:265-269`).
- Native HTTP clients (React Native `fetch` on iOS/Android) do not send an `Origin` header on
  same-app requests, so every native write is rejected today.

**RQ-N2-5 resolution (write origin).** CSRF is an attack on **ambient** credentials (cookies, Basic
Auth cached by a browser). A bearer token in an `Authorization` header is never attached by a
browser automatically, so the Origin check adds nothing for it. Bypassing it only for requests
already authenticated by the device bearer keeps the browser path unchanged. `X-Aiur-Request: 1`
remains required for both (cheap, uniform).

## Chosen design

```elixir
defp verify_same_origin(%Plug.Conn{private: %{aiur_auth: {:device, _}}} = conn, _opts), do: conn
defp verify_same_origin(conn, _opts), do: # existing body
```

Ordering requirement: `:dashboard_auth` runs before `:api_write` in every write scope
(`router.ex:153-178` already pipe `[:dashboard_auth, :api_write, ...]`). A test asserts this order
for every route that includes `:api_write`, so a future scope cannot run `:api_write` first.

## Implementation steps

One function clause plus the order-guard test. About 10 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Browser page tries to forge `aiur_auth` | Impossible: `conn.private` is server-side; only C6-T01 sets it after a valid token. |
| Device bearer, missing `X-Aiur-Request` | 403 `missing X-Aiur-Request header` (unchanged). |
| Device bearer on a read-only dashboard | 403 `dashboard is read-only` (unchanged); the app shows `disabled` per the capability model. |

## Compatibility and rollout

No behaviour change without a device bearer.

## Verification

`src/test/aiur_web/router_device_write_test.exs`:

1. `"device bearer without Origin can POST messages when writable"`. *Fails without:* the clause.
2. `"cookie session without Origin is still rejected"` (future-regression guard for CSRF).
3. `"device bearer still needs X-Aiur-Request"`.
4. `"every route with :api_write runs :dashboard_auth first"` (reads `AiurWeb.Router.__routes__/0`
   pipeline metadata; field name verified by MP-R3-C1-T01).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur_web/router_device_write_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation check: remove the clause → test 1 fails.
- [ ] Docs: the router comment at `router.ex:41-49` updated to name device bearers.
- [ ] Dependents: MP-N6 native write paths.
