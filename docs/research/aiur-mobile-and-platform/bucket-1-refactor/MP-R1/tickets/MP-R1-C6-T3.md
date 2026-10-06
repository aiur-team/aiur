---
ticket_id: MP-R1-C6-T3
feature_id: MP-R1
chunk_id: MP-R1-C6
bucket: 1-refactor
title: Internal run shape with the HTTP listener and JSON API but without dashboard pages
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C6-T1, MP-R1-C3-T1]
prior_units: [U6, U0]
prior_boundaries: ["WEB #34", "CLI #31"]
prior_features: []
prior_findings: []
size_owner: APP_BOOT
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C6-T3 — Internal "API without pages" run shape

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C6. Migration step S11. Plan finding 2 and
  KD5 ([plan.md §1, §4](../plan.md)).
- **User value:** none visible yet. It is the precondition for a lean run that a phone or
  Stream Deck can reach without the LiveView pages (capability matrix: `--no-dashboard`
  removes the whole listener, `aiur.ex:467-469`). It also makes "dashboard pages" a separate
  fact in the capability report.
- **Deliverable:** `Aiur.Application.child_specs/1` and `Aiur.HttpServer` accept a separate
  `dashboard_pages?` input (default `true`). When it is `false`, the listener, JSON API,
  Decision API, webhook receiver, Remote Control hook, Stream Deck and voice sockets run, but
  every dashboard page, static dashboard asset and LiveView mount answers like an unknown
  path. No operator flag sets it (DESIGN-R1 S4 default "internal only"); tests and later
  MP-R1-C6-T4 do.
- **Non-goals:** no CLI flag, no config key, no launcher change (T4). `--no-dashboard` keeps
  its meaning (no listener at all). `observability.dashboard_enabled` stays a reserved no-op
  (`configuration.md:663`). No change to which children start: `ControlCenterCache` and
  `FinancialData.Supervisor` still follow the listener, because `aiur units` uses
  `PayloadLoader`, which uses the cache when present (`units_cli.ex:119`,
  `payload_loader.ex:197-203`).

## Dependencies and blockers

> **Size owner (RC-23).** `size_owner` comes from the U8 ledger pinned at `465aca643`, while this pack is at `45a290e3`. Re-resolve it at ticket start against the then-current U8 ledger (the MP-R1-C11-T2 sweep step). RC-19/RC-20: this ticket touches none of `issue_sync.ex`, `dispatch_policy.ex`, `github/labels.ex` or `github/issues.ex`; if a rebase brings one into scope, preserve the MP-E1-C1 hooks.

- **DESIGN-R1 S4** — the plan default is "internal only until a client needs it", which this
  ticket implements. If Kevin rejects S4 entirely, close this ticket and T4 unimplemented.
  DESIGN-R1 §1 also applies.
- **MP-R1-C6-T1** — the page gate is added to `AiurWeb.Routes.DashboardPages` (PROPOSED in
  T1).
- **MP-R1-C3-T1** (registry, C1–C5 researcher) — the run-shape field is reported through
  the capability registry. If C3-T1 has not landed, ship without the report and leave a
  C3-T2 follow-up note. See the contract request below.
- **Prior unit U0/APP_BOOT** owns `src/lib/aiur.ex` (U8 package `APP_BOOT`, 600 lines at
  release, 609 at `45a290e3`). The U8 rule is no growth of an oversized file: this ticket
  must leave `aiur.ex` at ≤ 609 lines (see the steps). **U6** owns `src/lib/aiur_web/`.
- **May run concurrently with:** C7/C8 tickets that do not touch `aiur.ex` or `router.ex`.
  It conflicts with any APP_BOOT U8 split of `aiur.ex`; serialize with it.
- **Related, not in scope:** #3010 (`dashboard_writable` default), RC-15 / RQ-TRANSPORT
  (HTTPS; MP-N2 and MP-R3).

## Verified starting point

Base `45a290e3`.

- `src/lib/aiur.ex` (609 lines):
  - `start/2` reads `no_dashboard? = Application.get_env(:aiur, :no_dashboard, false)` (67)
    and validates Remote Control compatibility (70, `validate_dashboard_compatibility/2` at
    202-225). It passes `dashboard?: not no_dashboard?` to `child_specs/1` (78-83).
  - `child_specs/1` (244-486): `dashboard? = Keyword.fetch!(opts, :dashboard?)` (247);
    `{Aiur.OpenTicketSource, poll_on_start: …dashboard?}` (436); and
    `if(dashboard?, do: AiurWeb.ControlCenterCache)`, `…FinancialData.Supervisor`,
    `…Aiur.HttpServer` (467-469).
- `src/lib/aiur/http_server.ex` (271 lines): `start_link/1` (31-41); `configure_endpoint/5`
  (61-82) writes `dashboard_writable`, `dashboard_auth_required` and others into the
  endpoint config.
- `src/lib/aiur_web/endpoint.ex`: `plug(:authenticate_static_asset)` (31) before three
  `Plug.Static` plugs (33-58); `authenticate_static_asset/2` (84-88) authenticates only
  `StaticAssets.served_path?/1` paths.
- `src/lib/aiur_web/router.ex`: static-asset scope (111-131) and page scope (133-149) with
  `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess`; catch-all
  `match(:*, "/*path", ObservabilityApiController, :not_found)` (198).
- `ObservabilityApiController.not_found/2` returns 404
  `{"error":{"code":"not_found","message":"Route not found"}}`
  (`observability_api_controller.ex:148-157`).
- `AiurWeb.FinancialDataAccess.on_mount/4` (`financial_data_access.ex:98`).
- Tests: `src/test/aiur/application_test.exs` (835 lines; U8 `APP_BOOT`) "child_specs/1
  run-shape gating" (91-220), including "foreground no-dashboard run keeps terminal UI
  without an HTTP listener" (215); `router_auth_test.exs` sets endpoint config through
  `Aiur.TestSupport.start_owned_endpoint!/0` and `Phoenix.Config.put/3` (12-35);
  `http_server_credential_gate_test.exs` (154 lines).
- Capability contract `run_shape` today has a single `dashboard` boolean
  (`contracts/identity-and-capabilities.md:132`).

## Chosen design

**Run-shape inputs** (internal keyword options; no new Application env key in this ticket):

| Input | Default | Meaning |
|---|---|---|
| `dashboard?` (existing) | required | HTTP listener and its supporting children start. Unchanged semantics. |
| `dashboard_pages?` (new) | `true` | LiveView pages, legacy page redirects and dashboard static assets are served. Ignored when `dashboard?` is false. |

Combinations: `{true, true}` today's default; `{false, _}` today's `--no-dashboard`;
`{true, false}` new "API without pages".

**Flow of the value:** `child_specs(opts)` reads `Keyword.get(opts, :dashboard_pages?, true)`
and starts `{Aiur.HttpServer, dashboard_pages?: value}` instead of bare `Aiur.HttpServer`.
`HttpServer.configure_endpoint/5` writes `dashboard_pages: value` into the endpoint config.

**Gates (fail toward today's behaviour, unlike the writable gate):**

1. Router: a new pipeline `:dashboard_pages` with function plug `require_dashboard_pages/2`
   in `AiurWeb.Router`. It passes when `AiurWeb.Endpoint.config(:dashboard_pages) != false`.
   Otherwise it calls `AiurWeb.ObservabilityApiController.not_found(conn, %{})` and halts.
   Reusing the controller keeps the bytes identical to the catch-all.
   `AiurWeb.Routes.DashboardPages.static_assets/0` pipes through
   `[:dashboard_auth, :dashboard_pages]`, and `pages/0` through
   `[:dashboard_auth, :dashboard_pages, :browser]`. Auth runs first, so an unauthenticated
   request gets the same 401 that the catch-all gives it today. Pages-off reveals nothing
   more than an unknown path.
2. Endpoint static assets: `authenticate_static_asset/2` keeps authenticating first; if the
   connection is not halted and pages are off, it answers with the same 404 JSON and halts
   before `Plug.Static`.
3. LiveView websocket: `live_session :dashboard, on_mount: [AiurWeb.DashboardPagesGate, AiurWeb.FinancialDataAccess]`
   (gate PROPOSED, `src/lib/aiur_web/dashboard_pages_gate.ex`). When pages are off it
   returns `{:halt, socket}`. This closes a websocket mount that does not go through the HTTP
   pipeline.

**Unchanged on purpose:** `/api/v1/*` (state, events, issue, Decision API, refresh, writes,
pane, `claude-hook`, `streamdeck/token`, `streamdeck/grid`), the webhook receiver, the
`/streamdeck` and `/voice` sockets, and `OpenTicketSource` polling (still keyed to `dashboard?`).

**Invariant:** with `dashboard_pages?` true or absent, every request has today's response.
Only `{true, false}` changes responses, and only for page and asset paths.

**Capability report:** the registry (C3-T1) reports `run_shape.dashboard_pages`. See
CONTRACT-REQUESTS (parent file): `run_shape` adds `http_listener` and `dashboard_pages`;
`dashboard` stays as an alias of `http_listener` for v1 compatibility.

## Implementation steps

1. Tests first (see Verification); confirm that the new tests fail on the base.
2. `src/lib/aiur/application/web_children.ex` (PROPOSED, ~25 lines):
   `children(dashboard?, dashboard_pages?)` returns `[]` or
   `[AiurWeb.ControlCenterCache, AiurWeb.FinancialData.Supervisor, {Aiur.HttpServer, dashboard_pages?: dashboard_pages?}]`.
   In `aiur.ex`, replace lines 467-469 with one call and read the new option once. The net
   line delta on `aiur.ex` must be ≤ 0.
3. `http_server.ex`: add `dashboard_pages: Keyword.get(opts, :dashboard_pages?, true)` to
   `endpoint_opts` (62-74).
4. `router.ex`: add the `:dashboard_pages` pipeline and `require_dashboard_pages/2`. In
   `routes/dashboard_pages.ex`, add the pipeline to both scopes and the gate to `on_mount`.
5. `endpoint.ex`: extend `authenticate_static_asset/2`.
6. Regenerate T1's `@expected` route table: only `pipe_through` changes for the static and
   page rows. Explain this in the PR body.
7. Register `run_shape.dashboard_pages` in the C3 registry, if present.

Size: about +60 production lines across five files; `aiur.ex` does not grow.

## Non-happy paths

- **Missing config key** (tests, a hand-started endpoint): treated as pages on, which is
  today's behaviour. This is deliberately the opposite of the writable gate (which fails
  closed), because pages-on is the unchanged state and not a privilege escalation.
- **Remote Control:** unaffected. The hook is an API route, and
  `validate_dashboard_compatibility/2` still keys on `no_dashboard?` only.
- **Unauthenticated probe in pages-off:** 401, the same as an unknown path. An
  authenticated probe gets the 404 JSON. There is no oracle that distinguishes "pages off"
  from "no such page".
- **Open LiveView tab when the shape changes:** the shape is fixed per boot. A restart
  reconnects, the mount halts, and the browser shows LiveView's failed-join state. That is
  acceptable for an internal shape; T4 decides operator copy.
- **Concurrent requests, idempotency, retries:** n/a (stateless gate).
- **Privacy:** the report exposes only the boolean.

## Compatibility and rollout

- No config key, no flag, no on-disk change. Default `true` everywhere, so no deployed run
  changes. Rollback is a revert.
- The capability contract change is additive (new fields; `dashboard` kept).
- Docs: none in this ticket (no operator surface). The capability concepts page (C3-T3)
  gains the field when the contract request is accepted.

## Verification

From a worktree, with `HOME` isolated and GitHub tokens unset:

```bash
env -C <worktree>/src mise exec -- mix test test/aiur/application_test.exs \
  test/aiur_web/dashboard_pages_gate_test.exs test/aiur_web/router_auth_test.exs \
  test/aiur_web/router_table_test.exs test/aiur/http_server_credential_gate_test.exs \
  test/aiur_web/financial_data_access_test.exs
```

| Test | Expected | Must fail without |
|---|---|---|
| `application_test.exs` "API-without-pages run passes dashboard_pages?: false to HttpServer" (new) | `{Aiur.HttpServer, opts}` is in `child_specs(interactive_cli?: false, headless?: true, dashboard?: true, dashboard_pages?: false)` with `opts[:dashboard_pages?] == false` | the `web_children.ex` hunk |
| `application_test.exs` existing run-shape tests, incl. 215 | Green. `modules/1` (128-134) maps `{mod, _}` to `mod`, so `Aiur.HttpServer` still matches `@dashboard` | — (regression guard) |
| `dashboard_pages_gate_test.exs` "pages off: GET / returns the catch-all 404 JSON" (new, `Plug.Test` against `AiurWeb.Router` with `Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_pages, false)` and valid credentials) | 404, body equals `ObservabilityApiController.not_found` output | router pipeline hunk |
| same file "pages off: /api/v1/state still answers" | 200 or the existing unavailable shape, never 404 `not_found` | — (guards against over-gating) |
| same file "pages off: unauthenticated GET /commands gets the same 401 as an unknown path" | Status and `www-authenticate` equal to `GET /no-such-path` | auth ordering |
| same file "pages off: /dashboard.css static asset is 404 after auth" | 404 JSON | endpoint hunk |
| same file "pages off: LiveView on_mount halts" (call `AiurWeb.DashboardPagesGate.on_mount/4` directly) | `{:halt, _}` | gate module |
| same file "pages config absent: GET / renders the dashboard" | 200 HTML | default-true branch. Replace `!= false` with `== true` and confirm that this test fails |
| `http_server_credential_gate_test.exs` "dashboard_pages? is written to endpoint config" (new) | `Application.get_env(:aiur, AiurWeb.Endpoint)[:dashboard_pages] == false` after start with the option | `http_server.ex` hunk |

**Mutation check.** For each new test above, revert its named hunk in a clean worktree
(`git status --porcelain` shows only that revert), run the single test, and confirm it fails.
Restore it and confirm it passes. Record the commands in the PR body.

**Manual (AGENTS.md).** Foreground `scripts/aiurdev --test` (default shape) and confirm that
the dashboard and a TUI chat-pane message are unchanged. The pages-off shape has no operator
entry point until T4. Prove it with the tests above and say so in the PR body; this is not a
user-visible change.

## Completion and handoff

- [ ] Default shape responses unchanged (route table and existing suites green).
- [ ] Pages-off: pages, assets and LiveView mounts are refused like unknown paths; all API
  routes and sockets still work.
- [ ] `aiur.ex` line count ≤ 609 (U8 APP_BOOT no-growth rule).
- [ ] Mutation checks recorded.
- **Docs:** none (internal).
- **Dependents:** MP-R1-C6-T4 (operator flag), MP-R1-C3-T2 (capability callback for
  `run_shape.dashboard_pages`), MP-N1/N3 (meta-dashboard can show "API only" once the
  contract carries the field).
