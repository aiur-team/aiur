# DASH-033 — Existing-dashboard parity checklist

Traceable parity proof for the shipped Executor Control Center (OCC), keyed to
the existing-page subset of DREQ-001..034 and the resolved predecessor baseline
`origin/main@9849f32963c2a65367bce565b3f5ede3777c218f`. This capstone owns
convergence proof only — not new feature behavior.

## Integration baseline

- Authoritative integration branch: `develop` (`tracker.base_branch`).
- Integration SHA proven against: `ad80f4730b098fe7e200d8a1aee8d8bf06f28ecf`
  (`origin/develop` head at pickup) — reproduced on current main-equivalent
  code, not the prototype or a planning branch.
- All ten terminal prerequisites are merged into `develop` at this SHA:
  DASH-001 (route shell), DASH-003 (Units), DASH-005 (unit controls, #1253),
  DASH-007 (Commands), DASH-015 (provider meters, #1263), DASH-022 (run summary,
  #1255), DASH-027 (conversation drawer, #1257), DASH-028 (capacity control,
  #1258), DASH-031 (usage/cost, #1264), DASH-034 (current-run Recent, #1262).

## Proof surfaces and their honest boundaries

Three layers prove parity; each is authoritative for a different claim.

1. **Elixir LiveView/component suite** (`src/test/aiur_web/...`) — proves the
   *real* `DashboardLive`/`BuildOrderLive` compose every region on one page
   across auth/writable/degraded/empty states with synthetic fixtures. This is
   the single-page composition authority.
2. **BO-008 browser harness** (`src/browser/`, Playwright + axe-core) — proves
   the rendered visual/responsive/a11y/reconnect layer. Per-region specs prove
   each destination; the new composed spec (below) proves the walk across all
   destinations in one authenticated session.
3. **Manual operator gate** (AGENTS.md canonical CLI path) — proves the real
   daemon-driven dashboard. **This gate cannot run inside an agent issue
   workspace** (`scripts/aiurdev --test` is hard-blocked there, scripts/aiurdev
   :332-344). It is handed to the Executor/acceptance owner — see
   "Manual gate handoff" below. Nothing in this checklist claims the manual gate
   was executed by the agent.

## Composed proof (new in this capstone)

`src/browser/tests/parity-composition.browser.spec.mjs` — the composed
existing-pages proof no single prerequisite provided. In one authenticated
session it:

- walks Units (`/`) → Commands (`/decisions`) → Build Order (`/build-orders`)
  via URL-backed live navigation, then the standalone region fixtures
  `/units`, `/provider-meters`, `/ticket-context`, asserting each named region's
  landmark and accessible live-status region survives ("nothing silently
  disappears") at 390px and 1440px with no page-level overflow and a clean axe
  pass;
- proves the protected financial region locks content-free (no plan/generation
  values, no meters) while the rest of the shell stays navigable — a bounded
  region degrades without crashing navigation;
- proves the composed shell rejects unauthenticated access (401) and survives a
  LiveView disconnect/reconnect with the route intact.

Run: `cd src/browser && npm run test:parity` (wired into the aggregate
`npm test` browser CI job).

## Traceable requirement → proof map (existing-page subset)

Legend: PRE = prerequisite proof already on `develop`; COMP = composed proof.

| Req | Existing-page capability | PRE proof | COMP proof | Status |
|-----|--------------------------|-----------|------------|--------|
| DREQ-001 | Responsive URL-backed route shell (Units/Commands/Build Order/Analytics, theme, `aria-current`, safe areas) | `browser/tests/route-shell.browser.spec.mjs`; `test/aiur_web/operator_control_center/route_registry_test.exs` | parity-composition walk (390/1440, nav + no-overflow + axe) | ✅ proven |
| DREQ-003 | Units presentation, filters, unknowns, ticket-context activation | `browser/tests/units.browser.spec.mjs`; `test/aiur_web/components/operator_control_center/units_table_test.exs`, `units_filters_test.exs` | parity-composition `/units` landmark + status in session | ✅ proven |
| DREQ-005 | Capability-gated per-unit pause/resume controls (writable-only, 44px) | `test/aiur_web/live/dashboard_live_test.exs` (writable/read-only control hiding) | Elixir composition authority; browser control-hiding not modeled in fixtures (see note) | ✅ proven (Elixir) |
| DREQ-007 | Commands vocabulary/filters/cards over full Decision lifecycle + deep links | `dashboard_live_test.exs` decisions/decision routes; `test/aiur_web/controllers/decision_api_controller_test.exs` | parity-composition `/decisions` route identity + `aria-current` | ✅ proven |
| DREQ-015 | Authenticated provider-meter cards, freshness/LKG, accessible meter semantics, locked state | `browser/tests/provider_meters.browser.spec.mjs`; `test/aiur_web/components/operator_control_center/provider_meters_test.exs` | parity-composition `/provider-meters` + locked-region degrade | ⚠️ **routed back — see DF-013** |
| DREQ-022 | Accessible nonfinancial run-summary strip, truthful unavailable states | `test/aiur_web/components/operator_control_center/run_summary_test.exs`; `.../run_summary_presenter_test.exs` | Elixir composition authority (rendered on `/`) | ✅ proven |
| DREQ-027 | Read-only conversation drawer, focus trap, Escape, focus return | `test/aiur_web/operator_control_center/conversation_drawer/*`; `dashboard_live_test.exs` drawer | ticket-context/drawer landmarks; Elixir composition | ✅ proven |
| DREQ-028 | Authoritative capacity control via Slots snapshot, distinct states | `test/aiur_web/operator_control_center/capacity_presenter_test.exs`; `dashboard_live_test.exs` capacity events | Elixir composition authority | ✅ proven |
| DREQ-031 | Authenticated usage/cost summary, `*` disclosure, tier joins, locked mode | `test/aiur_web/components/operator_control_center/usage_summary_test.exs`; `.../usage_summary_presenter_test.exs` | Elixir composition authority (DREQ-021 facade) | ✅ proven |
| DREQ-034 | `Finished this run` cards from qualified current-run outcomes; RecentMerge audit + History preserved | `test/aiur_web/components/operator_control_center/current_run_outcomes_test.exs`; `dashboard_live_test.exs` recent/history | Elixir composition authority | ✅ proven |
| DREQ-021 | Enforced financial-data boundary (no protected fact to unauth connection) | `test/aiur_web/financial_data_access_test.exs`, `financial_data_test.exs` | parity-composition locked-region + 401 rejection | ✅ proven |

No acceptance item above is silently waived. The one non-green item (DREQ-015)
is explicitly routed back to its owner with evidence, not deferred silently.

### Note — auth-mode control hiding is Elixir-proven

The browser region fixtures (`UnitsLive`, `ProviderMetersLive`) render
identically regardless of read-only/writable mode; they do not model
writable-only control visibility. That distinction is proven at the Elixir
layer (`dashboard_live_test.exs` asserts `Overview.readonly_banner` and
`writable`-gated controls). The composed browser spec exercises the
authenticated session, financial-locked degradation, and 401 rejection, and
does not over-assert writable controls the fixtures do not render.

## Prerequisite finding routed back — DASH-015 provider meters

Surfaced by this capstone; **contained rework belongs to DASH-015**, not
DASH-033 (per the capstone contract, review findings default to the owning
prerequisite). Recorded as **DF-013** in `deferred-findings.md`. Two defects
plus a wiring gap, all pre-existing on `develop` (this capstone touched neither
the component nor its spec):

1. **Browser proof not wired into CI.** `provider_meters.browser.spec.mjs`
   landed with DASH-015 (#1263) but was never added to the `npm test` chain in
   `src/browser/package.json`, so it never runs in the browser CI job.
2. **Real dark-theme accessibility violation.** Running the spec shows an
   axe `color-contrast` failure: meter text at contrast 3.05:1 (`#676b74` on
   `#1e2025`) below the WCAG AA 4.5:1 threshold.
3. **Strict-mode locator bug.** `codex.locator('time')` matches two `<time>`
   elements (spec line ~42), so the reset-time assertion fails regardless of
   date.

Repro: `cd src/browser && node scripts/run-browser-tests.mjs
tests/provider_meters.browser.spec.mjs`. Because the a11y contrast failure may
qualify as an at-merge P1 dashboard-accessibility blocker, its severity/routing
is escalated to the Executor for decision rather than silently deferred. The
`test:provider-meters` chain wiring is intentionally **not** added here: wiring a
red spec would break CI, and the fix is DASH-015's to own.

## Manual gate handoff (Executor / acceptance owner)

The operator-visible gate must be run from the Executor repository root (not an
agent workspace). Per AGENTS.md "Manual testing — the only definition":

1. `scripts/aiurdev --test --force --allow-remote` from the repo root (real
   release binary + tmux + opencode panes; never `mix run`).
2. Open the printed dashboard host/port; drive Units, Commands + Decision
   lifecycle, per-unit and capacity controls (authenticated writable), the
   read-only conversation drawer, run/provider/accounting summaries, Recent
   outcomes, and Analytics.
3. Observe read-only vs authenticated-writable vs locked-financial modes; kill
   and restart the daemon (Boot.run_id changes) with the browser open to prove
   reconnect/live convergence; check 390px and desktop.
4. Cleanup: `mise exec -- ./scripts/aiurdev stop`.

Evidence must be synthetic/redacted — no secrets, account identity, raw
logs/provider payloads, workspace paths, or dashboard credentials.

## Deferred nonblockers

- DF-013 (this capstone) — DASH-015 provider-meter a11y/locator/CI-wiring; routed
  to DASH-015 for contained rework, severity escalated to Executor.
