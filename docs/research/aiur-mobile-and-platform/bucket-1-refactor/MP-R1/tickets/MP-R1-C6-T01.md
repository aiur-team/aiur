---
ticket_id: MP-R1-C6-T01
feature_id: MP-R1
chunk_id: MP-R1-C6
bucket: 1-refactor
title: Split AiurWeb.Router into component-owned route modules composed in a fixed order
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T01, MP-R1-C3-T03]
prior_units: [U6]
prior_boundaries: ["WEB #34", "DEC #27", "ING #9", "SD #35"]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C6-T01 — Split `AiurWeb.Router` into component-owned route modules

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (refactor), MP-R1, chunk C6 (web-shell /
  dashboard-ui split). Migration step S11 ([migration-plan.md §2](../migration-plan.md)),
  path-map row PR-08.
- **User value:** none visible. Later features (MP-E3, E4, E5, N2, N4, N6 — path-map
  PR-08) add routes to the module of the component that owns them, instead of editing one
  361-line router that every feature touches. MP-R5 and MP-R6 can move their route
  declarations with their component.
- **Deliverable:** `AiurWeb.Router` keeps its pipelines and plug functions and becomes a
  composition list. Each block of routes moves to a route module owned by one manifest
  component. The compiled route table (`AiurWeb.Router.__routes__/0`) is identical before and
  after, except for the `line` field.
- **Non-goals:** no new route, no changed pipeline, no auth change, no runtime gate (that is
  T03), no socket change (T02). Do not fix #3010 (`dashboard_writable` defaults to `true` while
  the router comment at `router.ex:55-57` says "Disabled by default"); the comment moves
  verbatim and #3010 stays its own ticket.

## Dependencies and blockers

> **Size owner (RC-23).** `size_owner` comes from the U8 ledger pinned at `465aca643`, while this pack is at `45a290e3`. Re-resolve it at ticket start against the then-current U8 ledger (the MP-R1-C11-T02 sweep step). RC-19/RC-20: this ticket touches none of `issue_sync.ex`, `dispatch_policy.ex`, `github/labels.ex` or `github/issues.ex`; if a rebase brings one into scope, preserve the MP-E1-C1 hooks.

- **DESIGN-R1 §1** — Kevin confirms "no runtime change you see". Implementation blocked
  until approved.
- **MP-R1-C1-T01** (manifest; owned by the parallel C1–C5 researcher): the new route modules
  need component entries (`paths`) so the C1 checker assigns them. If C1-T01 has not merged,
  this ticket can still merge; C1-T01 then lists the files.
- **MP-R1-C3-T03** (capabilities route, C1–C5 researcher): it inserts
  `get("/api/v1/capabilities", …)` above `router.ex:193`. Land C3-T03 first, or rebase the
  route-table fixture of this ticket onto it. They conflict on `router.ex`; do not run them
  concurrently.
- **May run concurrently with:** MP-R1-C6-T02 (touches `endpoint.ex` only), any C7/C8
  ticket that does not edit `router.ex`.
- **Must precede:** MP-R1-C6-T03 (adds a pipeline to the page modules this ticket creates),
  MP-R5/MP-R6 socket and route moves, every later feature ticket that adds a route (PR-08).
- Prior unit: **U6** owns `src/lib/aiur_web/` (status/presenter contract). This ticket only
  moves route declarations; it does not touch U6's presenter or status read model. If a U6
  PR is open on `router.ex`, serialize behind it.

## Verified starting point

Base `45a290e3` (2026-10-06).

- `src/lib/aiur_web/router.ex` (361 lines, below the 500-line limit; not in the U8 ledger).
  - Pipelines: `:dashboard_auth` (9-11), `:dashboard_auth_required` (13-15),
    `:supervisor_auth` (17-19), `:github_webhook` (24-26), `:browser` (28-35),
    `:secure_document` (37-39), `:api_write` (50-53), `:require_writable` (60-62).
  - Route scopes, in order:
    1. 69-75 GitHub webhook `post("/api/v1/github/webhook", GithubWebhookController, :create, log: false)`
       — must stay ahead of every other scope (comment 64-68).
    2. 81-87 Decision mutations (`:supervisor_auth, :api_write, :require_writable`).
    3. 91-96 Decision reads (`:supervisor_auth`).
    4. 100-109 Decision method/shape catches — "keep these specific routes before
       `/api/v1/:issue_identifier`" (comment 77-80, 98-99).
    5. 111-131 static assets (`StaticAssetController`, `:dashboard_auth`).
    6. 133-149 browser pages: legacy `/decisions` redirects (136-137) and
       `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess` with 8 `live` routes
       (139-148).
    7. 153-164 agent-write API (`:dashboard_auth, :api_write, :require_writable`).
    8. 169-178 machine writes: pane interrupt/hide, `claude-hook` (`:dashboard_auth, :api_write`).
    9. 180-184 `post("/api/v1/streamdeck/token", …)` (`:dashboard_auth_required`).
    10. 186-199 JSON reads and the catch-alls, ending with `match(:*, "/*path", …, :not_found)` (198).
  - Function plugs `dashboard_basic_auth/2` (203-211), `verify_same_origin/2`,
    `require_dashboard_writable/2`, `require_custom_header/2` and the origin helpers
    (213-360). They stay in `AiurWeb.Router`; pipelines refer to them by atom.
- Tests that read the compiled table today:
  - `src/test/aiur_web/github_webhook_test.exs:330-350` ("wiring"): the receiver route has
    `path == GithubWebhook.path()`, `verb == :post`, `metadata.log == false`, and precedes the
    route whose `path == "/*path"`.
  - `src/test/aiur_web/financial_data_access_test.exs:112-125`: the `Phoenix.LiveView.Plug`
    routes are exactly the 8 live paths, in order.
  - `src/test/aiur_web/router_auth_test.exs` (303 lines): auth, Decision catch and origin
    behaviour (e.g. "Decision route method catches cannot fall through to generic issue
    reads", line 172).
- Phoenix `1.8.9`, LiveView `1.1.33` (`src/mix.lock`).

### Resolved research: how to compose routes from other modules

| Option | Evidence | Verdict |
|---|---|---|
| `forward "/prefix", OtherRouter` | `Phoenix.Router.forward/4`: the forwarded plug sees the path with the prefix stripped, and "you can only forward to a given Phoenix.Router once" (https://hexdocs.pm/phoenix/1.8.1/Phoenix.Router.html#forward/4, accessed 2026-10-06; repo pins 1.8.9). | **Rejected.** Our components share the `/api/v1/` prefix and interleave (webhook first, Decision catches before `/api/v1/:issue_identifier`, catch-all last). A forward makes a sub-router opaque in `AiurWeb.Router.__routes__/0`, which breaks the two existing wiring tests. |
| A route module that exports a macro returning quoted `scope … do … end` blocks, invoked inside the router body | The same mechanism as `Phoenix.LiveDashboard.Router.live_dashboard/2`, a macro that expands to routes in the caller's router (https://hexdocs.pm/phoenix_live_dashboard/Phoenix.LiveDashboard.Router.html, accessed 2026-10-06). Expanded routes are ordinary routes of `AiurWeb.Router`, so `__routes__/0`, pipelines and order are unchanged. | **Chosen.** |

## Chosen design

Each route module is a plain module with one macro:

```elixir
# PROPOSED src/lib/aiur_web/routes/decisions.ex  (component: commands)
defmodule AiurWeb.Routes.Decisions do
  @moduledoc "Supervisor Decision API routes. Expanded inside AiurWeb.Router."
  defmacro mutations do
    quote do
      scope "/" do
        pipe_through([:supervisor_auth, :api_write, :require_writable])
        post("/api/v1/decisions/:decision_id/enrich", AiurWeb.DecisionApiController, :enrich)
        # … moved verbatim from router.ex:84-86
      end
    end
  end
  defmacro reads, do: …        # router.ex:91-96
  defmacro method_catches, do: … # router.ex:100-109
end
```

Rules:

1. **Fully qualified controllers, no scope alias.** Write `scope "/" do` with
   `AiurWeb.DecisionApiController`, not `scope "/", AiurWeb do`. This avoids depending on how
   the scope alias expands inside a quote; the resulting `route.plug` atom is identical, and
   the route-table test proves it.
2. **Comments move with their routes, verbatim.** The ordering comments (64-68, 77-80,
   98-99, 151-152, 166-168) move into the module that owns the routes. The router keeps one
   short comment per expansion site that states why it sits at that position.
3. **Pipelines and function plugs stay in `AiurWeb.Router`** (web-shell). Route modules name
   pipelines by atom. They must not define pipelines.
4. **Composition order in `AiurWeb.Router` is the registration list** (PROPOSED):

   | Order | Expansion | From lines | Owner component |
   |---|---|---|---|
   | 1 | `AiurWeb.Routes.GithubWebhook.receiver()` | 69-75 | github-listeners |
   | 2 | `AiurWeb.Routes.Decisions.mutations()` | 81-87 | commands |
   | 3 | `AiurWeb.Routes.Decisions.reads()` | 91-96 | commands |
   | 4 | `AiurWeb.Routes.Decisions.method_catches()` | 100-109 | commands |
   | 5 | `AiurWeb.Routes.DashboardPages.static_assets()` | 111-131 | dashboard-ui |
   | 6 | `AiurWeb.Routes.DashboardPages.pages()` | 133-149 | dashboard-ui |
   | 7 | `AiurWeb.Routes.Api.agent_writes()` | 153-164 | web-shell |
   | 8 | `AiurWeb.Routes.Api.machine_writes()` | 169-178 | web-shell |
   | 9 | `AiurWeb.Routes.Streamdeck.session()` | 180-184 | streamdeck-server |
   | 10 | `AiurWeb.Routes.Api.reads_and_catch_all()` | 186-199 | web-shell |

   The capabilities route from C3-T03 stays inside block 10, above
   `get("/api/v1/:issue_identifier", …)`. The `/api/v1/streamdeck/grid` read (190) stays in
   block 10 too, so its order relative to `/api/v1/:issue_identifier` does not change. Moving
   it to the Stream Deck module is MP-R6's decision, after this ticket.
5. **Invariant:** the catch-all `match(:*, "/*path", …)` is the last route, and the webhook
   receiver is the first. A new test pins both, in addition to the full table.
6. **Registration seam and checker edges (RC-39, X-04; this ticket owns the seam).**
   The dependency is inverted so no L1–L3 component imports the web layer:
   - Each component owns its route module `AiurWeb.Routes.<X>` (and, per C6-T02, its
     socket module `AiurWeb.Sockets.<X>`), listed in that component's manifest `paths`.
     The capabilities route from C3-T03 becomes `AiurWeb.Routes.Capabilities`, owned by
     `identity`; until it is split out it stays in block 10 as above.
   - Route, socket and controller modules reference only Phoenix, their own component's
     controllers and channels, pipelines **by atom**, and the new L1 library component
     **`web-kit`** (`AiurWeb.Kit`: `use AiurWeb.Kit, :controller | :channel | :live_view`,
     `AiurWeb.CapabilityError`, shared plugs; no endpoint, no routes; Req kernel, config;
     `added_by: MP-R1`). Implementation step 6 moves today's `use AiurWeb, :controller` helpers into
     `AiurWeb.Kit` and leaves `AiurWeb` delegating to it, so no controller changes
     behaviour.
   - `AiurWeb.Router` and `AiurWeb.Endpoint` (web-shell, L4) compose the route and socket
     modules. Those references are **downward optional edges**, declared in web-shell's
     `optional` list. They are not allowlisted, and no L1–L3 manifest row lists
     `web-shell` in `requires` or `optional`.
   - Checker fixture (C1-T03): a route module under `commands` that references
     `AiurWeb.Router` must fail R-down; the same module using `AiurWeb.Kit` passes.

## Implementation steps

1. **Pin the table first, on the unmodified base.** Add
   `src/test/aiur_web/router_table_test.exs` (PROPOSED) with
   `@expected` = the ordered list of
   `{verb, path, plug, plug_opts, pipe_through, metadata[:log]}` for every route in
   `AiurWeb.Router.__routes__()` (fields documented on `Phoenix.Router.Route`:
   https://github.com/phoenixframework/phoenix/blob/v1.8.1/lib/phoenix/router/route.ex,
   accessed 2026-10-06). Generate the literal once from the base (`mix run --no-start -e`
   printing that projection), paste it, and confirm it is green on the base. Exclude `line`,
   `helper` and `private`.
2. Create `src/lib/aiur_web/routes/` with `github_webhook.ex`, `decisions.ex`,
   `dashboard_pages.ex`, `api.ex` and `streamdeck.ex` (all PROPOSED). Move each block verbatim
   per the table in §Chosen design, rewriting `scope "/", AiurWeb do` to `scope "/" do` with
   fully qualified modules.
3. In `router.ex`, add `require AiurWeb.Routes.{GithubWebhook, Decisions, DashboardPages, Api, Streamdeck}`
   and replace each scope with its expansion call, in the same order.
4. Run the route-table, webhook-wiring, financial-data-access and router-auth tests.
5. Update the manifest (`components.json`, C1-T01) so each new file belongs to its owner
   component. If C1 has not merged, note the five paths in the PR body for C1-T01.
6. Create `src/lib/aiur_web/kit.ex` (PROPOSED, component `web-kit`): move the bodies of the
   `AiurWeb.controller/0`, `channel/0` and `live_view/0` quote blocks into `AiurWeb.Kit`,
   and make `AiurWeb`'s `__using__/1` delegate to it, so existing modules compile
   unchanged. Point the five route modules at `AiurWeb.Kit` only. Add the manifest row
   (`layer: L1`, `kind: required`, `added_by: MP-R1`) and the C1-T03 fixture from rule 6.
   The route-table test proves the routes did not change.

Expected size: `router.ex` 361 → ~200 lines; five new modules of 20-70 lines each; net
production change under +80 lines (module boilerplate). No file over 200 lines is created.

## Non-happy paths

- **Silent reorder.** A move that places Decision catches after
  `/api/v1/:issue_identifier` would make `GET /api/v1/decisions/x/y` fall into the issue API
  under Basic Auth. The route-table test fails on it, and
  `router_auth_test.exs:172` covers the behaviour.
- **Alias drift.** If a controller atom expands to `AiurWeb.AiurWeb.X` or to a bare `X`, the
  route compiles and fails only at request time. The table test compares `plug` atoms and
  catches it at test time.
- **Lost `log: false` on the webhook.** That would write whole payloads into the debug log.
  The table includes `metadata[:log]`, and `github_webhook_test.exs:331-339` already asserts
  it.
- **Concurrency with C3-T03 or a feature adding a route.** Both edit the router. Whoever lands
  second regenerates the `@expected` table and explains the added row in the PR body.
- Security, permissions, idempotency, disconnects: n/a. No runtime path changes.

## Compatibility and rollout

- No config, CLI, flag, migration or on-disk change. Rollback is a revert of the PR.
- Compile-time only: the release artifact contains the same router functions.
- Docs: none (internal refactor; AGENTS.md "Docs ship with the change" exempts it).

## Verification

Run from a worktree, never the live checkout. The local suite boots the application and can
overwrite `~/.aiur/github-budget/agent-token`, so isolate `HOME` and unset `GITHUB_TOKEN`
and `GH_TOKEN` as the test harness requires:

```bash
env -C <worktree>/src mise exec -- mix test \
  test/aiur_web/router_table_test.exs \
  test/aiur_web/github_webhook_test.exs \
  test/aiur_web/financial_data_access_test.exs \
  test/aiur_web/router_auth_test.exs
env -C <worktree>/src mise exec -- mix compile --warnings-as-errors
```

| Test (file) | Expected |
|---|---|
| `router_table_test.exs` "compiled route table is unchanged by the split" | The ordered projection equals `@expected` |
| `router_table_test.exs` "webhook receiver is the first route and /*path is the last" | First route plug `AiurWeb.GithubWebhookController`; last path `"/*path"` |
| `router_table_test.exs` "every Decision catch precedes /api/v1/:issue_identifier" | All `DecisionApiController` indexes < the index of `{:get, "/api/v1/:issue_identifier"}` |
| `github_webhook_test.exs` "wiring" (existing, 330-350) | Green, unchanged |
| `financial_data_access_test.exs:112` (existing) | Green, unchanged |
| `router_auth_test.exs` (existing, all) | Green, unchanged |

**Mutation check.** This is a structural refactor, so the guard is the table test, not new
behaviour. Run it against the base unchanged (green). Then, in the refactored tree, swap
expansions 3 and 10 in `router.ex` and confirm that "every Decision catch precedes …" and
the table test both fail. Restore the order and confirm green. Also drop `log: false` from
the moved webhook route and confirm that the table test fails. State in the PR body that the
table test is a future-regression guard that passes on `main` by design.

**Manual (AGENTS.md "Manual testing").** Foreground `scripts/aiurdev --test` in the wrapper
tmux. Open the dashboard `/`, `/commands`, `/build-orders` and `/streamdeck`, and send one
message through the TUI chat pane. Capture pane output showing the same rendering as before
the change.

## Completion and handoff

- [ ] Route table identical except `line`; first and last route invariants pinned.
- [ ] Every new route module is ≤ 200 lines and belongs to exactly one manifest component.
- [ ] `router.ex` holds only pipelines, function plugs and the ordered expansion list.
- [ ] Mutation check and manual capture recorded in the PR body.
- **Docs:** none required (internal refactor).
- **Phase D (CR-R7-6):** this ticket owns the `aiur_web` reference to
  `Aiur.Claude.HookEvents.dispatch/2` (`POST /api/v1/:id/claude-hook`,
  `observability_api_controller.ex:9`): the route moves into a harness-registered
  route module, and the MP-R7-C3-T05 allowlist row 9 is deleted in the same PR.
- **Dependents:** MP-R1-C6-T03 (adds the page gate to `DashboardPages`); MP-R5 (voice) and
  MP-R6 (Stream Deck) route moves; the plan refresh (MP-R1-C11) regenerates path-map row
  PR-08 to name `src/lib/aiur_web/routes/*.ex` for every later feature that adds a route.
