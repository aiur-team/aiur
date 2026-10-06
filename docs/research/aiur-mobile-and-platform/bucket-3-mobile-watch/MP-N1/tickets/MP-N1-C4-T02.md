---
ticket_id: MP-N1-C4-T02
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: Instance WebView host with native device-session bootstrap (native POST → bootstrap_path → WebView navigation) and one silent re-bootstrap on 401
status: blocked
blocked_by: [DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C6-T02, MP-N1-C4-T01, MP-N1-C2-T05, MP-N1-C3-T02]
prior_units: [U6]
prior_boundaries: ["WEB #34"]
prior_features: [MP-N2, MP-R3]
prior_findings: [RQ-N2-5, N1-RQ5 (retired), Phase D review T-2]
size_owner: n/a (new package; no daemon file changes)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T02 — WebView host and session bootstrap

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4.
- **User value:** tapping an instance opens its existing dashboard on the phone with no
  password prompt, and it keeps working across daemon restarts (plan AC3; MP-N2 acceptance 8).
- **Deliverable:**
  - Native `AiurNative.bootstrapWebSession(instanceId): Promise<{ bootstrapUrl: string }>`:
    native code POSTs `/api/v1/device-session` with the device bearer (MP-N2-C6-T02 deliverable 1,
    contract §4.4) and receives `200 {bootstrap_path, expires_in: 30}`. It returns the absolute
    one-time URL `<dashboard.url><bootstrap_path>`. The bearer never crosses into JS; the one-time
    code does, but it is single use and expires in 30 s (AC6).
  - **The WebView navigates to that URL.** `GET /device-session/:code` validates the code, sets
    the per-instance cookie `_aiur_key_<instance_key>` in a normal top-level response and
    `302`s to `next` (MP-N2-C6-T02 deliverables 2–3). Native code never reads, harvests or
    injects a cookie (Phase D review T-2; N1-RQ5 is retired).
  - `src/shell/InstanceScreen.tsx`: `react-native-webview` loading `<dashboard.url><path>`
    by navigating to the bootstrap URL; one silent re-bootstrap + reload on HTTP 401 or the bridge
    `session-expired` message (MP-N1-C4-T04); a second failure shows the typed error state.
  - Lifecycle rule (surface-boundary §2 rule 6): on app foreground, refetch capabilities first;
    reload the WebView only if `boot_id` or session changed; otherwise let LiveView reconnect.
- **Non-goals:** navigation confinement and bridge (MP-N1-C4-T03), header (MP-N1-C4-T06),
  mic (MP-N1-C4-T05), TLS trust customisation (only needed under transport option T-B; see
  Non-happy paths).

## Dependencies and blockers

- DESIGN-N1 (surface 3 loading/session states); **RQ-TRANSPORT** and **MP-N2-C10-T01**
  (RC-15: an HTTPS instance origin; under the HTTP-degraded mode this ticket still works but
  the app must be built with the per-host cleartext exception from MP-N1-C5-T02).
- **MP-N2-C6-T02** (`POST /api/v1/device-session`), MP-N2-C6-T01 (device-auth plug).
- MP-N1-C4-T01 (route), MP-N1-C2-T05 (module), MP-N1-C3-T02 (capability store, `boot_id`).

## Verified starting point (base 45a290e3)

- Session cookie: `@session_options [store: :cookie, key: "_aiur_key", signing_salt:
  "aiur-session"]` (`src/lib/aiur_web/endpoint.ex:8-12`); the LiveView socket reads the session
  from `connect_info` (`endpoint.ex:14-17`, `longpoll: false`).
- `secret_key_base` is random per boot (`src/lib/aiur/http_server.ex:268-270`), so every
  instance restart invalidates every session (MP-N2 plan F10).
- Every LiveView page sits in `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess`
  (`router.ex:139-148`); `on_mount` assigns a locked capability (no redirect) when the session
  proof is missing (`financial_data_access.ex:98-111`); HTTP requests without proof or Basic
  Auth get 401 from `:dashboard_auth` (`router.ex:9-11,133-134`).
- External (accessed 2026-10-06):
  - `react-native-webview` props `onHttpError` (all platforms, gives `statusCode`),
    `sharedCookiesEnabled` (iOS), `thirdPartyCookiesEnabled` (Android), `onContentProcessDidTerminate`
    (iOS), `onRenderProcessGone` (Android API 26+)
    (<https://github.com/react-native-webview/react-native-webview/blob/master/docs/Reference.md>, community).
  - (Retired N1-RQ5 evidence, kept for history; this ticket no longer calls these APIs.) `WKHTTPCookieStore.setCookie(_:completionHandler:)`
    (<https://developer.apple.com/documentation/webkit/wkhttpcookiestore>); Android
    `android.webkit.CookieManager.setCookie(String, String, ValueCallback)` and `flush()`
    (<https://developer.android.com/reference/android/webkit/CookieManager>).
  - Cookies are not isolated by port (RFC 6265 §8.5, <https://www.rfc-editor.org/rfc/rfc6265#section-8.5>).

## Chosen design

- **Native bootstrap, not WebView POST.** Rejected alternative: load `device-session` inside the
  WebView with `source.headers` — it hands the bearer to the JS layer and `headers` apply only to
  the first request on iOS. Native bootstrap keeps the bearer native.
- **No native cookie handling (Phase D T-2).** The server sets the session cookie itself during
  the one-time navigation (MP-N2-C6-T02 "RQ-N2-5 resolution"). This removes the
  `WKHTTPCookieStore`/`CookieManager` dependency and the process-death question (N1-RQ5,
  **retired**). Rule kept: bootstrap before the **first load of each Instance screen in each app
  process**, so cookie persistence across process death never matters.
- **Port collision:** settled by MP-N2-C6-T02 deliverable 3 (per-instance cookie name
  `_aiur_key_<instance_key>`). Two instances on one host no longer overwrite each other's
  session; no host-level rule is needed in the app.
- **State machine** (per Instance screen): `bootstrapping → loading → loaded`;
  `loaded --401|session-expired--> rebootstrapping → loading`;
  `rebootstrapping --fail--> error(cause)`; at most one automatic re-bootstrap per
  60 s per instance (prevents loops).
- **Error causes** (typed, from `signedFetch`/bootstrap): `device_revoked`,
  `device_auth_disabled`, `dashboard_unreachable_for_devices` (registry `reachable_for_devices:
  false` + its `reason`), `transport(kind)`, `unknown(status)`.
- The one-time URL is never logged or persisted by the app (it is a bearer value for 30 s).
- **No transcript bodies on disk (Phase D security M5).** Dashboard pages carry raw agent
  transcript text. The WebView runs with `cacheEnabled={false}` and
  `cacheMode="LOAD_NO_CACHE"` (Android) and an iOS `WKWebsiteDataStore` whose disk cache is
  cleared on background and on revoke; native code never writes an entry body to disk (memory
  only). On revoke, website data for the origin is wiped (Non-happy paths).
- WebView props: `sharedCookiesEnabled={false}`, `thirdPartyCookiesEnabled={false}`,
  `incognito={false}`, `webviewDebuggingEnabled={__DEV__}`, `setSupportMultipleWindows` left
  default `true` (setting it `false` is flagged CVE-2020-6506 in the reference doc).

## Implementation steps

1. Swift: `SessionBootstrap.swift` in the Expo module: `signedFetch` POST to
   `/api/v1/device-session`, decode `{bootstrap_path, expires_in}`, validate that
   `bootstrap_path` starts with `/device-session/`, return the absolute URL.
2. Kotlin: `SessionBootstrap.kt`, the same with OkHttp. No `CookieManager` call.
3. TS `src/shell/InstanceScreen.tsx` with the state machine (`useReducer`); `bootstrapping` sets
   `source.uri` to the bootstrap URL; `onHttpError`
   (top-frame 401 → re-bootstrap), `onContentProcessDidTerminate`/`onRenderProcessGone` →
   `bootstrapping` again.
4. Foreground handler using the capability store's `boot_id` comparison.
5. Registry lookup: `dashboard.url` from the last `GET /v1/instances` (MP-N3/MP-N2 client data);
   if `reachable_for_devices` is false, render the reason screen instead of a WebView.

## Non-happy paths

- **Daemon restart while open:** LiveView reconnect fails, the page reloads, the GET returns
  401 → one re-bootstrap → reload (MP-N2 acceptance 8).
- **Revoked:** bootstrap returns `device_revoked` → machine wiped (MP-N1-C2-T03) → navigate
  Home with the revoked notice; WebView website data for that origin is cleared
  (`WKWebsiteDataStore.removeData(ofTypes:for:)` / `CookieManager.removeAllCookies`). This is a
  wipe, not a cookie injection.
- **Code expired before navigation (> 30 s, e.g. app backgrounded):** the GET returns 401 →
  counts as the one automatic re-bootstrap.
- **Read-only dashboard:** loads normally; write controls inside the page are already disabled
  by the dashboard.
- **Transport option T-B (self-signed pin):** HTTP navigations can be trusted via the
  `didReceive challenge` path, but the LiveView WebSocket cannot (Apple DTS, r. 25491679,
  <https://developer.apple.com/forums/thread/104376>, **[non-authoritative, 2018]**; MP-N1-C9-T01
  prototype row P-x decides) and `/live` has `longpoll: false`
  (`endpoint.ex:16`). If DESIGN-N2 §transport picks T-B, this ticket gains a follow-up
  dependency on a daemon ticket enabling LiveView long-poll fallback and on the T-B trust
  handler, and DV-P6 must pass on device before merge.
- **Privacy:** cookie values never logged; JS sees only `{ok, at}`.

## Compatibility and rollout

- Client-only; requires daemons with MP-N2-C6. Older daemons: bootstrap 404 → `needs_update`.
- U6 refactors `src/lib/aiur_web/`; no WebView code depends on markup (plan §10).

## Verification

- Jest `test/shell/InstanceScreen.test.tsx` (WebView and module mocked):
  - `bootstraps before first load` (bootstrap called, then `source.uri` set). Mutation: load
    first → fails.
  - `401 triggers exactly one rebootstrap then reload`; `second 401 within 60 s shows error`.
    Mutation: unlimited retries → loop counter assertion fails.
  - `navigates to bootstrap_path, never sets a cookie natively` (module mock has no cookie API;
    asserts `source.uri` equals `<dashboard.url><bootstrap_path>`). Mutation: load `dashboard.url`
    directly → fails.
  - `unreachable_for_devices shows reason, no WebView`.
  - `webview disables disk cache` (rendered props include `cacheEnabled: false` and
    `cacheMode: "LOAD_NO_CACHE"`). Mutation: drop the props → fails.
- Native: Swift `SessionBootstrapTests` with a `URLProtocol` stub returning
  `200 {bootstrap_path: "/device-session/abc?next=/"}`: asserts the returned absolute URL and that a
  `bootstrap_path` not starting with `/device-session/` is refused. Kotlin `SessionBootstrapTest`
  with OkHttp `MockWebServer`, same cases. Mutation: drop the prefix check → the
  `https://evil/` case passes through → fails.
- Integration (optional): the OCC dashboard local parity fixture run (synthetic data, no live
  agents) served over HTTPS with a test certificate, loaded in the iOS simulator and Android
  emulator.
- **Device (required):** iPhone A (iOS 17.x) and an iPhone on iOS 26.x; Android phone A
  (Android 13+, Play services). Steps: pair (MP-N2), open instance → dashboard without a
  prompt; `aiur restart` the instance → page recovers within one reload; open a second instance
  on the same host and go back → both work; revoke from the machine → app returns Home, debug
  screen shows no cookie for the origin. Rows **DV-P6** (widths 320–430 px), **DV-P9**.

## Completion and handoff

- [ ] AC3 on both platforms; DV-P6 and DV-P9 recorded with device, OS build, app SHA, daemon version.
- [ ] Confirmed on device that the cookie set by `/device-session/:code` is used by `/live` (no native cookie code).
- **Docs:** `website/docs-app/guide/mobile.md` "Opening an instance" (no password; requires
  HTTPS per the transport page MP-N2-C10 writes).
- **Dependents:** MP-N1-C4-T03/T05/T06, MP-N3-C4-T03, MP-N6 ("open full conversation").
