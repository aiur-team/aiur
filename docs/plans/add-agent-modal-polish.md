# Add-agent modal polish

## Goal
The Units page Tickets table shows a "Would route to" column. That prediction belongs in the
add-agent modal's model select, not in a table column. Remove the column, drop the modal's
helper sentence, and give the modal's selects a considered, theme-correct treatment.

## Findings (already verified by reading the code)

- Column: `src/lib/aiur_web/components/operator_control_center/tickets_panel.ex`
  `th.tk-col-agent` + `td.tk-agent-cell` + private `routing_cell/1` + `routing_label/1`.
  The label is `[backend, routing.resolved_model, routing.effort] |> uniq |> join(" · ")`.
- Modal: `src/lib/aiur_web/components/operator_control_center/add_agent_modal.ex`
  - `p.modal-meta` holds the sentence to delete.
  - Four native `<select>`s: backend, model, effort, complexity.
- Selection is built in `src/lib/aiur_web/live/dashboard_live.ex` `add_agent_modal/1` and
  duplicated in `src/test/browser/fixture_server.exs` `add_agent_modal/1`.
- **The model select does NOT already default to what the column showed.** The selection
  uses `routing.model` (the *requested* model, frequently `nil` -> "Backend default"),
  while the column rendered `routing.resolved_model` (the alias-resolved / backend-default
  model that will actually run). Fix: seed the selection from `resolved_model`.
  `AgentRoutingPreview.normalize_selection/1` clamps the value to `seedable_models(backend)`,
  so a resolved model outside that vocabulary safely falls back to "Backend default" —
  which is exactly today's behaviour, so this can only make the prefill more accurate.
- CSS: `src/priv/static/dashboard.css`, the only select rule is `.add-agent-field select`
  (line ~9524). The dashboard has no other `<select>` (the run_telemetry page is a separate
  standalone document), so there is no dashboard-wide select style to fork — but the rule
  should be written as a reusable `select` base so a future select inherits it.
- No custom listbox component exists in the repo. Native `<option>` row spacing is not
  styleable in Chromium/WebKit/Firefox, so row breathing room cannot be delivered on the
  popup. Do NOT build a bespoke JS combobox. Add `padding` on `option` (Firefox honours it,
  others ignore it) and report the limit plainly.

## Steps

1. `tickets_panel.ex`: delete the `tk-col-agent` header, the `tk-agent-cell` cell, and the
   now-unused `routing_cell/1` + `routing_label/1` helpers.
2. `dashboard.css`: delete `.tickets-table th.tk-col-agent`.
3. `add_agent_modal.ex`: delete the `p.modal-meta` sentence.
4. `dashboard_live.ex` + `test/browser/fixture_server.exs`: seed `selection.model` from
   `routing.resolved_model` (falling back to `routing.model`), with a why-comment.
5. `dashboard.css`: restyle the selects.
   - Share the control geometry so height matches neighbouring inputs/buttons.
   - Custom chevron via an inline-SVG `background-image` data URI using `currentColor`
     (so it tracks the theme) with `appearance: none`.
   - hover / focus-visible / open (`:focus`) states from existing custom properties
     (`--line-strong`, `--accent`, `--accent-line`, `--surface-2`).
   - Focus ring: match the page-wide `3px solid var(--accent-line)` + `outline-offset`
     convention so contrast holds in both themes.
   - `option { padding }` plus explicit `background`/`color` so the Firefox popup and any
     browser that renders options in-page inherits the theme instead of OS chrome.
6. Tests:
   - `tickets_panel_test.exs`: assert the column is gone.
   - `dashboard_live_test.exs`: assert the model select defaults to the routed model.
   - `units.browser.spec.mjs`: assert the table has no routing column and the model select
     carries the routed value; keep axe green.

## Verification
- `cd src && mix test` on every touched test file, `mix format --check-formatted`, `mix credo --strict`.
- Browser: `npm test` in `src/browser` for `units.browser.spec.mjs`, both themes.
