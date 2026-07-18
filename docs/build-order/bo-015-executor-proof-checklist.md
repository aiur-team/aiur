# BO-015 — Executor-Root Manual Proof Checklist

The capstone's user-visible proof **must** run from the Executor repository
root against the real CLI/TUI/dashboard. An issue-workspace agent is prohibited
from these steps (`scripts/aiurdev --test` is blocked inside agent workspaces),
so this checklist is prepared in advance for the Executor/acceptance owner to
run before root `COMPLETED` closure.

Do **not** substitute direct HTTP calls, logs, or an issue-workspace bypass for
any user-visible TUI/browser step. Sanitize all evidence (see the sanitization
section) before attaching it to the root.

## 0. Preconditions (verify, do not infer)

- [ ] Resolve and record the current configured integration branch/policy again
      (expected `develop`); record the exact head SHA under proof.
- [ ] Root #1084 records both external gates resolved and no branch/skill drift
      since (GATE-001 OCC baseline still an ancestor; GATE-002 skill revision
      still the loaded contract). Drift = explicit gate failure.
- [ ] Canonical planning validator green:
      `python3 docs/build-order/scripts/validate_publication.py` → 0/0.
- [ ] Capstone PR reviewed, current on `develop`, all required CI checks green.

## 1. Automated agent gate (re-run on the integrated candidate)

- [ ] Full repository CI green (`make ci`) — build, strict lint, Dialyzer,
      full ExUnit, browser, layout, guards.
- [ ] Browser/a11y/perf harness green on the real route:
      `cd src/browser && node scripts/run-browser-tests.mjs` covering
      `build-order-route`, `build-order-interaction`, `build-order-responsive`,
      `build-order-performance`, `dom-svg-layout-adapter`, `layout-worker`,
      `parity-composition`, `ticket-context`, and the failure/timeout evidence
      specs.
- [ ] Acceptance matrix has no missing BOREQ and no unresolved blocker
      ([`bo-015-acceptance-matrix.md`](bo-015-acceptance-matrix.md)).

## 2. Real published-root dogfood (real GitHub provider)

From the Executor root, launch the real CLI/TUI as required by `AGENTS.md`
(`scripts/aiurdev --test --force --allow-remote`), drive the real TUI via the
wrapper tmux, and inspect the authenticated dashboard route.

- [ ] Select / deep-link the real currently-published Build Order root.
- [ ] Verify all **54 member** identities, labels, native edges, and outcomes.
- [ ] Observe real Aiur activity join on a running agent.
- [ ] Open a cached ticket context; navigate dependencies.
- [ ] Follow exactly one safe destination link.
- [ ] Confirm Build Order exposes **no GitHub or Aiur mutation handler**
      (read-only).
- [ ] Open a running agent chat pane; send an Executor message via the TUI
      input; observe the expected user-visible flow.

## 3. Synthetic boundary + failure proof (BO-008 fixtures)

Fixtures: `src/test/support/browser_harness/fixtures.ex`
(`@supported_sizes [0, 1, 20, 50, 100]`; scenarios `:cycle`, `:invalid`,
`:degraded`), served by `src/test/browser/fixture_server.exs`.

- [ ] 20 / 50 / 100-member renders with recorded performance budgets.
- [ ] Cycle / self-loop, external / missing, malformed-catalog-root,
      selected structural-invalid, member-warning.
- [ ] Stale LKG, unavailable-provider, unknown-activity, and fallback modes.
- [ ] Catalog exact-bound and `+1` overflow preserves last-known-good.
- [ ] Configurable 60 / 15 / 5-second freshness and selection/reconnect
      coalescing remain visible; PubSub renders within its bound.
- [ ] Derived lane/status icons always have accessible generic fallbacks with
      no GitHub icon metadata.

## 4. Configured-repository and truthfulness proofs

- [ ] Configured-repository detail rejects other repositories **before** I/O.
- [ ] Structured history never parses raw logs.
- [ ] Base context renders bounded description / progress / latest / Logs.
- [ ] Truthful read-only GitHub / Chat / Commands destinations plus
      non-fetchable other-repo diagnostics.

## 5. Accessibility, theme, responsive, restart

- [ ] Mouse / keyboard / touch; context focus; all edge/readiness states;
      pan / zoom / fit.
- [ ] Light / dark / forced-colors / reduced-motion; 200% text zoom.
- [ ] 320 / 390 / 768 / 960 / desktop; safe areas; responsive reflow;
      non-color edge states; screen-reader summaries/focus.
- [ ] Redraw / reconnect; packaged assets; recorded 20/50/100 budgets.
- [ ] Upgrade/restart preserves existing dashboard/TUI routes; in-memory LKG /
      activity restart semantics documented; stored migrations replay/rollback
      tested.

## 6. Post-merge proof and root closure

- [ ] After the capstone merges under the then-active policy, re-resolve the
      configured integration target and rerun feature smoke + packaged-asset
      check + real-root provider reconciliation on it.
- [ ] Record the sanitized evidence link on root #1084.
- [ ] Acceptance owner closes root #1084 with state reason **`COMPLETED`** —
      only after post-merge proof succeeds. Never close on child-100% or CI
      alone.

## Sanitization (apply to every artifact)

Strip credentials, tokens, private issue content, account identifiers,
environment values, local paths/hosts, raw provider responses, transcripts, and
real user data from all evidence and any bug reports before attaching.

## Contained-finding policy

Contained acceptance defects return to their owning ticket/rework — do **not**
create momentum-preserving follow-up tickets. Only a genuine independent P0/P1
acceptance blocker may be promoted; the backlog-growth circuit breaker stays
active. Deferred/P2/P3 findings never change the denominator, ETA, or the
completion condition.
