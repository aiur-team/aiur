---
ticket_id: MP-R3-C1-T01
feature_id: MP-R3
chunk_id: MP-R3-C1
bucket: 1-refactor
title: Authorization-independence guards — route and socket auth census, bind matrix, HTTP-only listener
status: blocked
blocked_by: [DESIGN-R3]
prior_units: [U8]
prior_boundaries: ["WEB #34", "CFG #2", "launcher #32"]
prior_features: []
prior_findings: ["nonelixir-shell-27 (closed by #2995; not reopened here)"]
size_owner: n/a (touches only test files under 500 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R3-C1-T01 — Authorization-independence guards

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R3 / C1.
- **User value:** "Turning Tailscale off, binding `0.0.0.0` or putting a tunnel in
  front never makes an endpoint public" stays true after future changes. Today it
  is true but nothing enumerates it, so a new unauthenticated route or socket would
  pass CI.
- **Deliverable:** test files only. `git diff -- src/lib` is empty.
  1. A route census: every route in `AiurWeb.Router` resolves to a pipeline list
     that contains an authenticator.
  2. A socket census: the endpoint mounts exactly the audited sockets, and each
     one rejects a connect with no proof (or, for `/live`, defers to the
     `on_mount` contract that is already tested).
  3. Four more bind-matrix cases for `Aiur.HttpServer`'s credential guard.
  4. A guard that the listener is configured for plain HTTP only. MP-N2's
     transport item (RQ-TRANSPORT, RC-15) depends on the fact that Aiur never
     terminates TLS. If someone adds TLS, this test fails and forces the transport
     docs to change with it.
- **Non-goals:** no runtime change, no new config key, no TLS, no advertised URL
  (MP-N2 owns it), no change to the existing tests.

## Dependencies and blockers

- **Blocked by:** DESIGN-R3 (the owner confirms that no user-facing change is
  intended).
- **Contracts:** none owned. The census list of authenticators is consumed by
  MP-R4 (acceptance item 2: `:github_webhook` is the only non-dashboard,
  non-supervisor authenticator) and extended later by MP-N2 (pairing pipeline).
- **May run concurrently with:** everything in MP-R3-C2, MP-R4, MP-R5 and MP-R6.
  If MP-R1-C6 (router split) lands first, point the census at the router module(s)
  that exist then; the approach does not change.

## Verified starting point (base `45a290e3`)

- **Router:** `src/lib/aiur_web/router.ex`.
  - Authenticating pipelines: `:dashboard_auth` (`:9-11`),
    `:dashboard_auth_required` (`:13-15`), `:supervisor_auth` (`:17-19`) and
    `:github_webhook` (`:24-26`).
  - Non-authenticating helper pipelines: `:browser` (`:28-35`),
    `:secure_document` (`:37-39`), `:api_write` (`:50-53`) and
    `:require_writable` (`:60-62`).
  - Every scope (`:69-199`) pipes through one of the four authenticators today.
  - Some routes are `match(:*, …)` (for example `:103-108`, `:194-198`).
- **Phoenix 1.8.9** (`src/mix.lock`). In the vendored dependency source:
  - `Phoenix.Router.routes/1` is public (`deps/phoenix/lib/phoenix/router.ex:1394`).
    It returns maps with only `:verb, :path, :plug, :plug_opts, :helper,
    :metadata` (`:549-550`). **`pipe_through` is not in `routes/1`**, which
    answers the plan's Phase C question about the metadata key.
  - `Phoenix.Router.route_info/4` is public reflection (`:1427-1438`). It returns
    `:route` (the matched path pattern) and `:pipe_through` (the documented list,
    `:1415`).
  - Default (not `group_by: :verb`) matching is in declaration order. A `:*`
    route matches any method string through `_verb` (`:727-731`), and a
    verb-specific route matches only its upper-cased verb string.
  - `Endpoint.__sockets__/0` exists but is `@doc false`
    (`deps/phoenix/lib/phoenix/endpoint.ex:692-693`). It returns
    `{path, module, opts}` tuples (`:1069`). Phoenix's own
    `Phoenix.ChannelTest` and `ConsoleFormatter` call it
    (`channel_test.ex:270`, `console_formatter.ex:26`).
- **Sockets:** `src/lib/aiur_web/endpoint.ex:14-29`.
  - `/live` uses `Phoenix.LiveView.Socket`. In LiveView 1.1.33 its `connect/3`
    returns `{:ok, socket}` for any params (`deps/phoenix_live_view/lib/phoenix_live_view/socket.ex:98-100`).
    **Rejection happens at `on_mount`**, not at connect. That answers the third
    Phase C question. The `on_mount` contract is already asserted by
    `src/test/aiur_web/financial_data_access_test.exs:112-130`.
  - `/streamdeck` uses `AiurWeb.StreamdeckSocket`. Without a valid token it
    returns `:error` (`streamdeck_socket.ex:11-25`). Tested at
    `streamdeck_channel_test.exs:123-124`.
  - `/voice` uses `AiurWeb.VoiceSocket`. Without CSRF, session and a writable
    dashboard it returns `:error` (`voice_socket.ex:21-37`). Tested at
    `voice_channel_test.exs:122-153`.
- **Bind guard:** `src/lib/aiur/http_server.ex`.
  - `start_on_port/2` (`:43-59`): `parse_host` → `guard_dashboard_credentials`
    → `configure_endpoint` → `endpoint_start_fun`.
  - `loopback?/1` matches only `{127,0,0,1}` and `{0,0,0,0,0,0,0,1}`
    (`:12-13`, `:218-220`).
  - `configure_endpoint/5` sets `http: [ip: ip, port: port]` and no `:https`
    key (`:61-82`).
  - `base_url/0` always builds `"http://…"` (`:143-156`).
  - `start_link/1` accepts `:host`, `:port`, `:dashboard_writable` and
    `:endpoint_start_fun` options (`:30-59`).
- **Existing bind tests:** `src/test/aiur/http_server_credential_gate_test.exs:35-153`
  covers `192.0.2.1` with and without credentials, plus loopback read-only and
  writable. It does **not** cover `0.0.0.0`, `::` or `127.0.0.2`.

## Chosen design

### 1. Route census — PROPOSED `src/test/aiur_web/route_auth_census_test.exs`

```elixir
@authenticators [:dashboard_auth, :dashboard_auth_required, :supervisor_auth, :github_webhook]

for each route <- Phoenix.Router.routes(AiurWeb.Router):
  method = if route.verb == :*, do: "AIURCENSUS", else: route.verb |> to_string() |> String.upcase()
  info   = Phoenix.Router.route_info(AiurWeb.Router, method, route.path, "localhost")
  assert info.route == route.path          # the route is reachable as declared
  assert Enum.any?(info.pipe_through, &(&1 in @authenticators))
```

- Passing the declared pattern as the request path works: a `:param` segment
  matches the literal text `":param"` and a `*glob` matches the rest.
- The made-up method `AIURCENSUS` reaches only `match(:*, …)` routes, so each
  catch-all is checked against its own scope's pipeline, not against an earlier
  verb-specific route.
- The failure message lists every offending `{verb, path, pipe_through}`, not
  just the first.
- Shadowing: the path analysis at the base SHA finds no route whose own pattern
  is first matched by a different route. If the implementer finds one,
  `info.route != route.path` is a real routing bug. File it, and list that path
  in a `@known_shadowed` module attribute with the issue number. Do not drop the
  assertion.
- `routes/1` and `route_info/4` are public Phoenix reflection, so this test does
  not depend on `@doc false` internals.

### 2. Socket census (same file)

```elixir
@audited_sockets %{
  "/live"       => :on_mount,     # rejection at on_mount; see financial_data_access_test.exs:112
  "/streamdeck" => AiurWeb.StreamdeckSocket,
  "/voice"      => AiurWeb.VoiceSocket
}
assert AiurWeb.Endpoint.__sockets__() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Map.keys(@audited_sockets) |> Enum.sort()
assert :error = AiurWeb.StreamdeckSocket.connect(%{}, socket(AiurWeb.StreamdeckSocket, nil, %{}), %{})
assert :error = AiurWeb.VoiceSocket.connect(%{}, socket(AiurWeb.VoiceSocket, nil, %{}), %{})
```

- `__sockets__/0` is `@doc false`. The test comments that, and names Phoenix's
  own callers as the reason it is acceptable. If a Phoenix upgrade removes it,
  the test fails loudly. That is the wanted outcome, and the fix is to read
  `endpoint.ex` instead.
- `/live` is mapped to `:on_mount` rather than to a connect check, because its
  connect accepts everything by design. The comment points to the existing
  on-mount test, which must stay.

### 3. Bind matrix — extend `src/test/aiur/http_server_credential_gate_test.exs`

New `describe "non-loopback addresses without credentials"` with four cases.
Each passes `endpoint_start_fun: fn -> {:ok, self()} end`, so a mutated guard
can never bind a real interface during the test.

| Test name | Host | `dashboard_writable` | Expected |
| --- | --- | --- | --- |
| "the IPv4 wildcard needs credentials" | `"0.0.0.0"` | false | `:ignore` |
| "the IPv6 wildcard needs credentials" | `"::"` | false | `:ignore` |
| "only 127.0.0.1 counts as IPv4 loopback" | `"127.0.0.2"` | false | `:ignore` |
| "a writable wildcard bind needs credentials" | `"0.0.0.0"` | true | `:ignore`, and the log names `observability.dashboard_writable` |

**Dropped from the plan:** "a hostname resolving to a non-loopback address".
`parse_host/1` (`:245-257`) turns a name into an IP before the guard runs, so
the literal-IP cases cover the guard decision. A non-loopback hostname fixture
would need DNS or OS resolver configuration (`:inet.getaddr` uses the native
resolver), which makes a unit test environment-dependent.

### 4. HTTP-only listener guard (same file)

Test "the listener is configured for plain HTTP only (MP-N2 transport depends on
this)":

- Set credentials.
- Start with `host: "127.0.0.1", port: 0, endpoint_start_fun: fn -> {:ok, self()} end`.
- Assert that `Application.get_env(:aiur, AiurWeb.Endpoint)` has `:http` with
  `ip: {127,0,0,1}` and has **no** `:https` key.

Label it in a comment as a future-regression guard. Its purpose is to make a TLS
change visible to the RQ-TRANSPORT owner (MP-N2) and to
`optional-optimizations.md` § Transport (MP-R3-C2-T01).

### Invariants asserted

- Reachability (bind, tunnel, tailnet) never changes authorization: every HTTP
  route has an authenticator, and every socket needs proof.
- Only `127.0.0.1` and `::1` count as loopback.

## Implementation steps

1. Add `src/test/aiur_web/route_auth_census_test.exs` (PROPOSED,
   `use ExUnit.Case, async: true`; it reads only compiled route data and calls
   `connect/3` directly). Import `Phoenix.ChannelTest` for `socket/3`, as
   `streamdeck_channel_test.exs` does.
2. Extend `src/test/aiur/http_server_credential_gate_test.exs` with the four
   bind cases and the HTTP-only case. The existing setup already restores the
   env vars and the endpoint config.
3. Add a moduledoc comment to the census naming its consumers (MP-R4, and MP-N2
   when it adds the pairing pipeline to `@authenticators`).

## Non-happy paths

- **A new optional component registers routes (MP-R1-C6).** The census iterates
  the router(s), so a registered route without an authenticator fails CI. When
  routes move into several routers, the census iterates each one.
- **Pairing pipeline (MP-N2).** It must be added to `@authenticators` in the N2
  PR, with a review note. A pairing route is not dashboard Basic Auth (D19).
- **The supervisor `match(:*)` catch-alls** (`router.ex:103-108`) are checked
  through the `AIURCENSUS` method. That is exactly the case that would leak if
  a scope lost `:supervisor_auth`.

## Compatibility and rollout

n/a — test-only. No config, migration or flag. Rollback means reverting the test
files.

## Verification

Commands, run from a worktree. Use a temporary `HOME` and no GitHub tokens:
`mix test` boots the app and can overwrite `~/.aiur/github-budget/agent-token`.

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur_web/route_auth_census_test.exs test/aiur/http_server_credential_gate_test.exs
```

Expected: all pass on the base. Every test here is a **future-regression guard**:
it passes on `main` and says so in a comment. It does not count as coverage for a
production change.

Mutation checks, one per test. Revert each before the next; `git status
--porcelain` must show only that hunk.

| Test | Temporary production mutation | Expected |
| --- | --- | --- |
| route census | `router.ex:92`: `pipe_through(:supervisor_auth)` → `pipe_through([])` | Fails and lists `GET /api/v1/decisions` and `/:decision_id`. |
| route census (catch-alls) | `router.ex:101` → `pipe_through([])` | Fails on the six `*` routes `:103-108`. |
| socket census | add `socket("/probe", Phoenix.LiveView.Socket)` to `endpoint.ex` | Fails on set inequality. |
| bind cases 1–4 | `http_server.ex:220`: `defp loopback?(_), do: false` → `true` | All four fail (result `{:ok, pid}`, not `:ignore`). |
| HTTP-only guard | `http_server.ex:64`: add `https: [port: 0]` to `endpoint_opts` | Fails. |

Record the exact commands and outcomes in the PR body (AGENTS.md § Tests must
fail without the production change they guard).

Manual or device tests: none. No user-visible surface changes.

## Completion and handoff

- [ ] Both test files are green on the implementation head; the five mutations
  above each go red.
- [ ] `git diff --stat -- src/lib` is empty.
- [ ] Docs: none required (test-only; AGENTS.md "Docs ship with the change").
  MP-R3-C2-T01 carries the docs.
- **Dependents:** MP-R4-C1-T01 cites this census. MP-N2 (pairing pipeline,
  transport) extends `@authenticators` and reads the HTTP-only guard.
