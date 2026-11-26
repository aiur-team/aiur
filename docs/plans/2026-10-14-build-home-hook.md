# Build home hook foundation

Implement #3137 against the adopted MP-E8-C9-T01 contract. The server shell,
protocol and URL state already exist. No board drawing or stylesheet changes.

## Implementation units

1. Shared modules under `src/priv/static/build-home/`: stable `S`, `ctx`, `fx`,
   reset callbacks, disposable resources, monotonic payload clock, DOM helpers
   and the design icon table. Preserve the downstream module contract.
2. Adopt the existing hosts in `shell.js`; port scrollbar geometry, interaction,
   outside clicks, Escape, polling and resize. Dispose every resource on unmount.
3. Apply snapshots/diffs/pages atomically in `store.js`. Hook mount/reconnect
   requests snapshots; sequence guards reject stale replies after disconnect or
   destroy. Restore hook-owned data attributes after every server patch.
4. Bridge URL state through LiveView only; resend current state after reconnect
   and apply canonical server state without echo.

## Validation

Extend `src/browser/tests/build-home-shell.browser.spec.mjs` for B1–B19:
loading and unavailable, invalid payloads, clock, diffs/gaps, reconnect and late
replies, URL canonicalization, remount cleanup, missing hosts, reduced motion,
scrollbar geometry and pointer cancellation. Add
`src/test/aiur_web/build/home_assets_scan_test.exs` for clock/resource guards,
including planted violations. Enable loading/off parity gates and register the
future scrolled cells and motion sequences with explicit C9-T03 fixmes.

Run scoped browser/ExUnit checks, compile, format, lint and structural gates.
Use isolated worktrees for mutation evidence. Record actual blockers and results
in the PR body. Manual `--test` launches are prohibited in this agent workspace.

## Risks and decisions

ES modules survive navigation: reset shared state on each mount, preserve `fx`
registrations, and prevent old promises from mutating a later mount. Protocol
uses `resyncing` while the hook contract uses `inFlight`; adapt at the call seam.
Preserve sources/capacity alongside protocol intake results. No design imports
are required: the canonical fixture is already on disk.
