---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
feature_id: MP-R3
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: ../../owner-design-tasks/DESIGN-R3.md
---

# MP-R3 — Optional Tailscale: confirm, guard, document

## Summary

**Tailscale is already optional, and this feature is mostly a confirmation.** No
code calls `tailscale`. The dashboard binds `127.0.0.1` by default (#2995). A
non-loopback bind without credentials disables the listener, and every HTTP
route and websocket refuses an unauthenticated request whatever the bind
address is.

MP-R3 adds no runtime behaviour. It adds:

- an **auth census guard**, so a future route or socket cannot ship without an
  authenticator;
- a **bind-matrix guard** for the host values that matter;
- **one docs correction**: Tailscale gives reachability, not authorization.

The work is two chunks and about four tickets. The stable "advertised URL" a
phone needs is **not** R3 work; MP-N2 owns it (see § Plan refresh).

Prior-units: U8 (size only; no >500-line file is split here). Prior-boundaries:
`WEB` #34, `CFG` #2, launcher #32. Prior-findings: `nonelixir-shell-27` (the
engine overwrote the dashboard host from `tailscale ip -4`). #2995 resolved it.
That finding is closed by evidence, not by this feature.

## 1. Repository findings (verified at `45a290e3`)

This extends `baseline/capability-baseline-bucket-1.md` § R3. It does not repeat it.

### 1.1 Host selection: one owner, no Tailscale branch

- The launcher's `default_dashboard_host()` returns
  `${AIUR_DEFAULT_DASHBOARD_HOST:-127.0.0.1}`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:727-729`). It is exported at
  `:842`.
- The BEAM applies the same default only when `server.host` is absent
  (`src/lib/aiur/config.ex:1360-1371`, `prepare_server_config/1`,
  `default_server_host/0`).
- `Config.server_host/0` (`config.ex:1089`) lets the `--host` override
  (`:server_host_override`) win.
- The env schema documents the variable as dev-group, default `127.0.0.1`
  (`src/lib/aiur/env/schema.ex:210`).
- Precedence is `--host` > `server.host` > `AIUR_DEFAULT_DASHBOARD_HOST` >
  `127.0.0.1`. **No step in that chain probes the network.**

### 1.2 The bind guard disables the listener; the daemon keeps running

`Aiur.HttpServer.start_on_port/2` (`src/lib/aiur/http_server.ex:44-58`) calls
`guard_dashboard_credentials/3` (`:167-202`):

| Credentials | Bind | Writable | Result |
| --- | --- | --- | --- |
| Both set | any | any | Starts. Basic Auth is required on every request. |
| Missing | loopback (`127.0.0.1`, `::1` exactly; `:218-220`) | any | Starts with a warning. Every request is refused (401 or 503). |
| Missing | non-loopback | true | `:dashboard_credentials_missing`, so the child returns `:ignore`. |
| Missing | non-loopback | false | `:ignore`, the same as above. |

Correction to the baseline wording: "refuses to start" means **the HTTP child
returns `:ignore`**. The daemon and its agents keep running without a
dashboard. That matches the docs ("the listener refuses to start",
`website/docs-app/reference/optional-optimizations.md` § Dashboard
authentication).

Two edge facts:

- `loopback?/1` matches only the exact addresses `127.0.0.1` and `::1`. Any
  other `127.0.0.0/8` address therefore counts as non-loopback and needs
  credentials. That is a fail-safe direction.
- A hostname is resolved with `:inet.getaddr` (`:245-256`), so a MagicDNS-style
  name that resolves to a `100.x` address is non-loopback.

### 1.3 Authorization does not depend on the bind address

This is the load-bearing fact for the invariant. A reverse proxy or tunnel
(R4's `cloudflared` is one) can forward public traffic to a *loopback* bind, so
bind-based reasoning alone could never prove privacy. Authorization is enforced
per request, independently:

- `AiurWeb.FinancialDataAccess.authenticate_request/2`
  (`src/lib/aiur_web/financial_data_access.ex:50-86`):
  - With credentials configured, every request must prove them, "regardless of
    the `required?` setting" (`:67-72`).
  - Without credentials, the request gets a 401 challenge or a 503 refusal
    (`Proof.configuration/2`, `financial_data_access/proof.ex:10-50`).
  - **No branch passes an unauthenticated request through.**
- Every router scope has an authenticating pipeline (`src/lib/aiur_web/router.ex`):

  | Scope | Pipeline | Lines |
  | --- | --- | --- |
  | GitHub webhook | `:github_webhook` (HMAC; unset secret means 401) | `:69-75` |
  | Decision API | `:supervisor_auth` (bearer) | `:81-109` |
  | Static assets | `:dashboard_auth` | `:111-131` |
  | LiveViews | `:dashboard_auth` plus `on_mount` proof | `:133-151` |
  | Writes | `:dashboard_auth` + `:api_write` + `:require_writable` | `:153-167` |
  | Pane and Claude-hook writes | `:dashboard_auth` + `:api_write` | `:169-178` |
  | Stream Deck token | `:dashboard_auth_required` | `:180-184` |
  | Reads and catch-all | `:dashboard_auth` | `:186-199` |

- The endpoint also authenticates static-asset paths before `Plug.Static`
  (`src/lib/aiur_web/endpoint.ex:31`, `authenticate_static_asset/2`).
- Websockets (`endpoint.ex:14-29`):
  - `/live`: LiveView. Its `on_mount` re-checks the proof. The test
    `financial_data_access_test.exs:112` "dashboard LiveView routes install the
    financial on-mount contract" covers this.
  - `/streamdeck`: needs a `Phoenix.Token` minted only behind
    `:dashboard_auth_required` (`streamdeck_socket.ex`).
  - `/voice`: needs a writable dashboard, a CSRF token and the session proof
    (`voice_socket.ex:21-35`).
- `check_origin: false` is set globally (`src/config/config.exs:17`). Each
  socket's `connect/3` demands a token that a browser does not attach
  automatically, so cross-site socket use is believed to fail. The census
  ticket asserts this rather than assuming it (R3-C1-T01).

### 1.4 Existing guards

- `src/test/aiur/http_server_credential_gate_test.exs:35-126` covers four
  cases:
  - non-loopback without credentials returns `:ignore`;
  - loopback read-only binds;
  - loopback writable binds (#2376);
  - non-loopback with credentials passes.
- `src/test/aiur_engine_test.exs:592` "dashboard defaults to loopback even
  with Tailscale and dashboard credentials" stubs a `tailscale` binary that
  prints `100.64.0.42`.
- `src/test/aiur_web/router_auth_test.exs:37-229` tests named routes, not the
  full route table. **Nothing enumerates `AiurWeb.Router.__routes__/0` and
  asserts that every route has an authenticator.** A new scope added without
  one would pass CI today.

### 1.5 URL and address ownership

- **Bind address:** `server.host` / `--host` (config). There is no separate
  "advertised" or "public" URL key; a search for `public_url`, `dashboard_url`
  and `external_url` in `src/lib` found no config key.
- **Displayed URL:** `Aiur.HttpServer.base_url/0` (`http_server.ex:143`)
  returns `http://<display_host>:<bound_port>`, or `nil` when the listener is
  unbound. `display_host/1` maps `0.0.0.0` and `::` to `127.0.0.1`
  (`:264-266`).
  - Consumers: `Claude.HookSettings` via `:dashboard_url_fun`
    (`src/lib/aiur/claude/hook_settings.ex:68`), `RemoteControlMode`
    (`orchestrator/remote_control_mode.ex:72-87`), `AgentList.RenderState`
    (`agent_list/render_state.ex:92`), and the launcher's `Dashboard:` line
    (`aiur-engine.sh:1938`).
- **Port:** `server.port` defaults to `0`, a fresh OS port every boot.
- **Instance record:** `~/.config/aiur/instances/*.instance`
  (`aiur-engine.sh:1586-1612`) stores node, session, socket and project root.
  It stores **no dashboard URL**.
- **Transport:** the endpoint serves plain HTTP only. Aiur never terminates
  TLS. Encryption off-box is the network's job (for example a tailnet).
  Browser microphone capture on a non-loopback origin needs a secure context;
  the Draft `docs/voice-mode/spec.md:392` already assumes HTTPS.
- **Session key:** `secret_key_base` is random per boot (`http_server.ex:268`),
  so sessions do not survive a restart. That is an N2 concern, not R3's.

### 1.6 Remaining Tailscale assumptions (docs only)

| Path | Status |
| --- | --- |
| `website/docs-app/reference/optional-optimizations.md:83-101` | Correct: explicit `server.host`, no auto-detection. |
| `website/docs-app/reference/configuration.md:694` | Correct. |
| `AGENTS.md:141`, `src/README.md:376` | Correct. |
| `docs/voice-mode/spec.md:6,49,104,196,392,404,458` | Draft spec. It treats Tailscale as *the* access path. Historical design doc; left alone (below). |
| `src/lib/aiur/webhooks/mode_registry.ex:429` | Alert text that names a tailnet-only dashboard as one reason a webhook cannot arrive. Accurate. |

## 2. Proposed boundary

There is no new component. Tailscale stays outside the codebase. The boundary
is written down as three separate concerns:

1. **Reachability:** who can open a TCP connection. It is set by `server.host`
   plus the operator's network (loopback, a tailnet, a LAN, a tunnel). Aiur
   never infers it.
2. **Authorization:** who may read or act. It is enforced per request by
   `FinancialDataAccess`, `SupervisorAuth`, `GithubWebhook.Auth` and the
   socket tokens. It is independent of reachability.
3. **Advertised address:** what URL another device should use. **It does not
   exist yet.** MP-N2 owns it.

The invariant is: **changing reachability (including disabling Tailscale,
binding `0.0.0.0`, or tunnelling) never changes authorization.** That is why
"disabling Tailscale" cannot make a sensitive endpoint public: Tailscale was
never the lock.

## 3. Alternatives

| Option | Verdict |
| --- | --- |
| A. Add `server.tailscale: true` (auto-detect the tailnet IP) | **Rejected.** It re-introduces what #2995 removed, adds a hidden dependency on a CLI, and makes the bind depend on host state. |
| B. Add `server.exposure: loopback\|tailnet\|lan` profiles | Rejected for R3. It is new behaviour (Bucket 2). An explicit `server.host` already expresses it. |
| C. Refuse non-loopback binds unless the address is in `100.64.0.0/10` | Rejected. It would make Tailscale mandatory for off-box use, which contradicts the brief. |
| **D. No behaviour change; guard tests plus a docs clarification** | **Recommended.** The invariant already holds. The risk is future regression, so the work is guards. |

## 4. Contracts

- **Owns:** none.
- **Consumes:**
  - The machine/instance identity contract (MP-N2 / identity owner). R3
    assumes the advertised URL, port stability and device authorization are
    defined there, **not** by reusing `server.host`. Request to reconcile:
    MP-N2 must not treat a reachable bind as authorization (D19 pairing
    stands apart from Basic Auth).
  - The capabilities contract (MP-R1). R3 states "dashboard listener: bound,
    unbound because credentials are missing, or unbound because the port is in
    use" as an observable capability. `base_url/0` returning `nil` is today's
    signal.

## 5. Non-happy paths

| Case | Behaviour (existing) | R3 action |
| --- | --- | --- |
| Tailscale not installed or down | The bind is whatever `server.host` says. A `100.x` host that no longer resolves fails `parse_host`, so there is no listener. | Doc note. |
| `server.host: 0.0.0.0`, credentials set | Listens on every interface. Basic Auth over **plain HTTP**, so the password is cleartext on an untrusted LAN. | Docs warning (R3-C2-T01). No code change. |
| Tunnel or proxy to a loopback bind | Authorization still applies per request. | Census guard (C1). |
| Credentials removed while running | The proof generation invalidates; requests are refused (`proof.ex:44-50`). | Covered by `financial_data_access_test.exs:200`. |
| Port collision | The listener returns `:ignore` with a warning; agents keep running (`http_server.ex:91-93`). | None. |
| Multiple instances | Each needs its own port. There is no discovery. | MP-N2. |

## 6. Acceptance criteria

1. A test enumerates `AiurWeb.Router.__routes__/0` and fails when any route's
   pipeline list lacks one of these authenticators: `:dashboard_auth`,
   `:dashboard_auth_required`, `:supervisor_auth` or `:github_webhook`.
   - Mutation check: add a scratch route with no pipeline. The test goes red.
   - It is labelled as a future-regression guard (it passes on `main`).
2. A test asserts that each endpoint socket (`/live`, `/streamdeck`, `/voice`)
   rejects a connect with no token or proof.
   - The list of sockets is enumerated from `AiurWeb.Endpoint.__sockets__/0`,
     so a new socket must be added to the test or it fails.
   - Phase C confirmed: it exists but is `@doc false` (`deps/phoenix/lib/phoenix/endpoint.ex:692`).
3. The bind-matrix test adds four cases. Each fails if the `loopback?` or guard
   branch is replaced with `true`.
   - `0.0.0.0` without credentials gives `:ignore`.
   - `::` without credentials gives `:ignore`.
   - `127.0.0.2` without credentials gives `:ignore`.
   - `0.0.0.0` with a writable dashboard and no credentials gives `:ignore`
     (Phase C replaced the resolved-hostname case, which needs DNS).
   - Plus an HTTP-only listener guard (RC-15): the endpoint config has `http:`
     and no `https:`.
4. `optional-optimizations.md` § Tailscale says that Tailscale provides
   reachability and transport encryption, never authorization. It also warns
   that a non-tailnet, non-loopback bind sends Basic Auth in cleartext.
5. No change to `aiur-engine.sh`, `config.ex`, `http_server.ex` or the router
   behaviour. `git diff` on `src/lib` is empty for this feature.

## 7. Chunks

### MP-R3-C1 — Authorization-independence guards

- **Outcome:** CI fails if any route or socket becomes reachable without an
  authenticator, or if the bind guard regresses.
- **Dependencies:** none. It can run before MP-R1 lands. A later move of
  `aiur_web` into a package (MP-R1) only changes paths.
- **Tickets (Phase C, see [tickets/](tickets/README.md)):**
  - MP-R3-C1-T01: one test-only PR with four parts:
    - a route census through the public `Phoenix.Router.route_info/4`;
    - a socket census;
    - the `0.0.0.0`, `::`, `127.0.0.2` and writable-wildcard bind cases;
    - an HTTP-only listener guard for RC-15.
- **Phase C answers:**
  - `routes/1` has no `pipe_through`, but `route_info/4` does.
  - `__sockets__/0` is `@doc false`; it is used with a comment.
  - `/live` accepts at connect and rejects at `on_mount`.
  - The resolved-hostname case is dropped because it needs DNS.

### MP-R3-C2 — Docs: reachability is not authorization

- **Outcome:** an operator reading the docs cannot conclude that Tailscale (or
  its absence) controls privacy.
- **Dependencies:** none.
- **Tickets (Phase C):** MP-R3-C2-T01 edits
  `optional-optimizations.md`:
  - § Tailscale "what it does not do";
  - a new § Transport, which supports RC-15 RQ-TRANSPORT and names no HTTPS
    method;
  - "refuses to start" clarified to "listener disabled, agents keep running".

  The Draft-spec banner is a conditional step, decided by DESIGN-R3 §2.2. The
  § Transport copy needs DESIGN-R3 approval: CR-R3-1 in
  `tickets/CONTRACT-REQUESTS.md`.
- **Test strategy:** `website/tests/gui-docs.spec.ts` (brand project) and the
  docs-app build keep passing. Review is the gate.

## 8. Open questions

**Owner (Kevin):**

1. Is plain-HTTP Basic Auth on a non-tailnet LAN acceptable to document as a
   warning only? The alternative is a Bucket 2 TLS or exposure-profile feature.
   The plan assumes a warning only.
2. Should historical Draft specs (`docs/voice-mode/spec.md`) get a banner, or
   stay untouched?

**Research (Phase C):** answered in § 7 (C1) and `tickets/README.md`.

**RC-15 (Phase B reconciliation):** MP-R3 supports MP-N2's RQ-TRANSPORT with the C1 HTTP-only guard and the C2 § Transport docs. MP-N2 owns the transport policy.

## 9. Plan refresh

- If MP-R1 moves `AiurWeb` into an `aiur_web` package, the C1 tests move with
  the router. The census must then run inside the web package's test suite.
- MP-N2 introduces device authorization and an advertised URL. When it lands:
  - the C1 census adds the pairing credential pipeline to the allowed
    authenticator list;
  - the § Tailscale doc gains a link to the pairing page.
- Then re-run C1 against the post-R1 head.
