---
ticket_id: MP-R1-C3-T3
feature_id: MP-R1
chunk_id: MP-R1-C3
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: GET /api/v1/capabilities, typed capability_unavailable error encoder, and the Capabilities concepts page
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C3-T1]
prior_units: []
prior_boundaries: ["WEB #34"]
prior_features: [MP-N1, MP-N3, MP-R6]
prior_findings: []
size_owner: "src/lib/aiur_web/router.ex (361 lines) — add ≤ 3 lines"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C3-T3 — HTTP endpoint, error encoder, concepts page

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12 enabling), MP-R1, C3. Contract §2.1,
  §2.5, §3. DESIGN-R1 S2 (endpoint) and S5 (docs wording).
- **User value:** remote clients (dashboard JS, Stream Deck sidecar, later phone/watch)
  read one authenticated JSON document to decide what to show, including while the
  orchestrator is down.
- **Deliverable:**
  1. Route `get("/api/v1/capabilities", CapabilitiesController, :show)` and
     `match(:*, "/api/v1/capabilities", …, :method_not_allowed)` in the
     `:dashboard_auth` scope, **above** `get("/api/v1/:issue_identifier", …)`.
  2. PROPOSED `src/lib/aiur_web/controllers/capabilities_controller.ex`: `json(conn,
     Aiur.Capabilities.report([]))` with `cache-control: no-store`.
  3. PROPOSED `src/lib/aiur_web/capability_error.ex`: `render(conn, entry_with_id)` →
     409 (503 for `not_running`) with the contract §2.5 body. Exported for MP-E2, MP-E4,
     MP-N2, MP-N6; **no existing endpoint switches to it here**.
  4. Docs: new `website/docs-app/concepts/capabilities.md` (what the report is, every v1
     ID and reason, `boot_id`/`revision`/freshness rules, the machine identity file and
     how to reset it, privacy statement) and its sidebar entry in
     `website/docs-app/.vitepress/config.ts` Concepts group (`:146-152`).
- **Non-goals:** paired-device auth (MP-N2), CORS for native clients (MP-N1/RQ-TRANSPORT),
  changing `/api/v1/state`.

## Dependencies and blockers

- **DESIGN-R1 S2** (endpoint exists) and **S5** (page wording). C3-T1.
- **Concurrent:** T2, T4, T7. Coordinate with **MP-R1-C6-T1** (router split): whichever
  merges second moves these three lines into the owning route module; C6-T1 already
  lists C3-T3 as a predecessor.
- **Dependents:** MP-R6 sidecar adoption, MP-N1/N3 clients, MP-E2/E4 (error encoder).

## Verified starting point (`45a290e3`)

- Auth scope: `scope "/", AiurWeb do pipe_through(:dashboard_auth)` with
  `get("/api/v1/state", …)` at `router.ex:186-189` and the catch-all
  `get("/api/v1/:issue_identifier", …)` at `router.ex:193`, then `match(:*, "/*path",
  …, :not_found)` at `:198`.
- `:dashboard_auth` calls `AiurWeb.FinancialDataAccess.authenticate_request/2`
  (`router.ex:201-210`): with credentials configured it requires Basic auth; without
  them it returns 401 (`financial_data_access.ex:49-63`).
- Route tests: `src/test/aiur/extensions_test.exs` exercises `/api/v1/state`
  (`:584`, `:970` for 405), `src/test/aiur_web/router_auth_test.exs` covers auth.
- Docs: Concepts sidebar `config.ts:146-152`; no capabilities page exists.

## Chosen design

- The controller does no work beyond `Aiur.Capabilities.report/1` (ETS read); it never
  touches the orchestrator, so it answers while the orchestrator is down (acceptance 4).
- JSON keys are strings exactly as contract §2.2; atoms converted at the controller
  boundary by a `to_wire/1` function in `Aiur.Capabilities` (shared with T4's `--json`).
- `CapabilityError.render/2` signature:
  `@spec render(Plug.Conn.t(), %{id: String.t(), state: atom(), reason: atom(), depends_on: [String.t()] | nil}) :: Plug.Conn.t()`;
  it adds `revision` and `boot_id` from the current report.

## Implementation steps

1. Router: three lines in the existing scope, above line 193; keep order comments.
2. Controller + `to_wire/1`.
3. Error encoder + unit test.
4. Concepts page (≤ 150 lines) + sidebar entry; link it from `concepts/operating-aiur.md`
   in one sentence.
5. Manifest: controller to `web-shell`, encoder to `web-shell`.

## Non-happy paths

- Orchestrator down → 200 with `orchestration: unavailable/not_running`.
- Registry table missing → controller still answers 200 (T1 synchronous fallback,
  `freshness: "stale"`).
- Auth not configured → same 401 as `/api/v1/state`; not a capability decision.
- POST → 405 via the explicit `match`, not the `:issue_identifier` handler.
- Response never includes paths, ports, tokens (scan test).

## Compatibility and rollout

New route only. `GET /api/v1/capabilities` previously reached the `:issue_identifier`
handler and returned that handler's not-found shape; no client depended on it (no
caller in `src/`, `packages/` at base: `git grep -n 'api/v1/capabilities' 45a290e3` is
empty). Rollback: revert.

## Verification

PROPOSED `src/test/aiur_web/controllers/capabilities_controller_test.exs`:

| Test | Expected |
|---|---|
| `capabilities is not shadowed by the issue route` | 200 and `contract == "aiur.capabilities"` (acceptance 7) |
| `post is 405` | 405 |
| `requires dashboard auth when configured` | 401 without credentials |
| `answers while orchestrator is unavailable` | stub report with orchestration unavailable → 200, body carries it |
| `payload has no secret-shaped values` | serialise body; assert no value matches `~r/(ghp_|github_pat_|sk-|\/home\/|:\d{4,5}\b)/` and no key named `token`, `password`, `path` |
| `cache-control no-store` | header set |

`src/test/aiur_web/capability_error_test.exs`: `degraded dependency → 409 body with
depends_on`; `not_running → 503`.

Docs check: `npm run build` in `website/docs-app` (the `website` workflow runs typecheck,
assert and build, `website.yml:40-46`).

Command: `$TESTCMD test/aiur_web/controllers/capabilities_controller_test.exs test/aiur_web/capability_error_test.exs`.

Mutation check: place the route below `:issue_identifier` → first test fails; drop the
`match(:*)` line → second fails; map `not_running` to 409 → encoder test fails.

Manual: `scripts/aiurdev --test` (wrapper-tmux recipe, AGENTS.md), then
`curl -u "$AIUR_DASHBOARD_USERNAME:$AIUR_DASHBOARD_PASSWORD" http://127.0.0.1:<port>/api/v1/capabilities`
from the Executor shell; stop the orchestrator is not possible from outside, so the
"orchestrator down" path is covered by the automated test only.

## Completion and handoff

- [ ] DESIGN-R1 S2 and S5 approved (page wording).
- [ ] Route, controller, encoder, page and sidebar entry merged together (docs ship with
      the change, AGENTS.md).
- **Dependents:** MP-E2/E4/N2/N6 adopt the encoder; MP-R6, MP-N1, MP-N3 consume the route.
