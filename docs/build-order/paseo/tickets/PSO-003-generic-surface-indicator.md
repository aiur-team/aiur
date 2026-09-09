# PSO-003 — Generic surface indicator (📱) for any backend that reports a surface

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Threads one new field from the session map through the orchestrator state, status report, TUI border, dashboard row, and JSON API without touching the Remote Control path.

**Risk:** medium

**Phase hint:** 1

**Depends on:** none

**Serializes with:** PSO-015 — both edit the orchestrator status report and running-entry plumbing

**External gates:** none

**Requirements:** R12

**Decisions:** DEC-012, DEC-015

**Design evidence:** 00-design.md sections 5, 8, 9; 01-spike-report.md section 11

**Researched at:** 8199f5373

**Suggested labels:** `complexity:3`, `model:claude`, `phase:1`, `build-lane:paseo-core`; never `agent:todo`

## Outcome

Any running agent whose session carries `surface: %{kind, label, url}` shows a 📱 with the label in the TUI pane border and the dashboard Units row, exposes `surface` in `aiur status --json`, and never logs the URL. Remote Control keeps its own `remote_control` field and rendering unchanged. The Paseo sidecar (PSO-011) fills the field; this ticket makes core render it.

## Context and evidence

Today the phone icon is Remote-Control-only and threaded by hand:

- Session: `Aiur.AgentRunner.SessionLifecycle.session_runtime_info/1` (`src/lib/aiur/agent_runner/session_lifecycle.ex:63-72`) reports `session_url` only for `runtime_report: :repl_pane`; `:headless_wrapper` reports pids only.
- Orchestrator: `Aiur.Orchestrator.State.handle_repl_session_runtime/3` (`src/lib/aiur/orchestrator/state.ex:409-424`) copies `info[:session_url]` into the running entry as `:repl_rc_session_url`.
- Summary: `Aiur.Orchestrator.RemoteControlMode.remote_control_summary/1` (`src/lib/aiur/orchestrator/remote_control_mode.ex:319-330`) returns `%{status: :on, session_url}` only when the issue carries the RC label and a URL was harvested.
- Status report: `running_summary/5` in `src/lib/aiur/orchestrator/status_report.ex:927-940` sets `remote_control:` on `AgentEvents.agent_summary/4`.
- TUI: `Aiur.AgentList.RcPaneBorders.border_text/1` (`src/lib/aiur/agent_list/rc_pane_borders.ex:49`) renders `" 📱 <url> "` into the tmux pane border.
- Dashboard: `AiurWeb.OperatorControlCenter.UnitsTable.remote_control_url/1` (`src/lib/aiur_web/components/operator_control_center/units_table.ex:132-134, 229-231`) renders a link from `row.remote_control_url` or `row.live_conversation.remote_control_url`; `UnitsPresentation.remote_control_available?/1` (`units_presentation.ex:185-186`) gates the control.

The RC URL is a capability token; `rc_pane_borders.ex` moduledoc states it is never logged and never rendered in the agent list. The Paseo deep link is not a secret, but DEC-012 keeps one rule for both.

## Scope

- Session contract: adapters may set `session.surface = %{kind: String.t(), label: String.t(), url: String.t()}` and `session.session_url`. PSO-001 stores `thread.surface` from `thread/start`; this ticket adds nothing to adapters.
- `session_runtime_info/1`: the `:headless_wrapper` branch adds `surface: Map.get(session, :surface)`; the `:repl_pane` branch is unchanged.
- `Aiur.Orchestrator.State.handle_repl_session_runtime/3`: add `|> maybe_put_runtime_value(:surface, info[:surface])`. Rename nothing.
- New `Aiur.Orchestrator.SurfaceSummary.summary/1` (or a function in `status_report.ex` if the module would be under 40 lines): returns `%{kind, label, url}` when the running entry has `:surface` with a binary `url`, else `nil`.
- `Aiur.AgentEvents.agent_summary/4` type and constructor gain `surface: map() | nil` (`src/lib/aiur/agent_events.ex:57-70`); `running_summary/5` sets it. Idle and retrying summaries carry `nil`.
- TUI: `RcPaneBorders.border_text/1` gains a clause for `%{surface: %{label: label, url: url}}` rendering `" 📱 <label> <url> "` with the same `#` doubling; RC clause stays first so an RC session keeps its text. Rename the module only if credo complains; the doc says "remote-control URLs", update the moduledoc sentence to "remote surfaces".
- Dashboard: `UnitsTable` renders the 📱 with `title={label}` and `href={url}` when `row.surface` is present, beside the existing RC link; `UnitsPresentation` maps `summary.surface` onto the row. Use the same component the RC link uses.
- JSON: `aiur status --json` and `GET /api/v1/state` include `surface` on running agents through the existing summary projection (find the projection that serializes `remote_control` and add `surface` next to it).
- Logging: the URL never appears in log lines. Where the running entry is inspected for logs, ensure `surface` is redacted by adding `surface.url` to the redaction set used for `repl_rc_session_url` (`Aiur.SecretRedactor.redact_urls/1` covers `https://claude.ai/code/session_` patterns; add the `paseo://` scheme to the URL patterns).

## Non-goals

- Changing `remote_control_summary/1` or RC promotion.
- Making the sidecar send `surface` (PSO-011).
- The `p` key mid-run move (PSO-015).
- Stream Deck rendering.

## Existing owner and reuse target

Extend `session_lifecycle.ex`, `orchestrator/state.ex`, `status_report.ex`, `agent_events.ex`, `agent_list/rc_pane_borders.ex`, `aiur_web/components/operator_control_center/units_table.ex`, `units_presentation.ex`; reuse `AgentEvents.agent_summary/4` and the RC link component.

## Contract and invariants

- `surface` is `nil` for every backend that does not set it; no existing summary changes shape except the new key.
- A session with both RC and `surface` renders the RC text in the border (RC clause first) and both links on the dashboard.
- `surface.url` is never written to `logs/agent.ndjson`, the event feed, or Logger.

### Requirements

- PSO-003-R1. `AgentEvents.agent_summary/4` carries `surface` and the status report fills it for running agents.
- PSO-003-R2. The TUI pane border shows `📱 <label>` for a session with `surface`.
- PSO-003-R3. The dashboard Units row shows a 📱 link with the label as its title.
- PSO-003-R4. `aiur status --json` exposes `surface` per running agent.
- PSO-003-R5. Remote Control rendering and tests are unchanged.
- PSO-003-R6. The URL is not logged.

## Refreshable implementation notes

- Follow the RC threading path exactly; every file listed in Context is one edit. Grep `repl_rc_session_url` and `remote_control:` to find every site.
- The summary type lives in `agent_events.ex`; the `Map.take`/`put` pipeline footgun noted in `docs/brainstorms/2026-06-02-remote-control-toggle-requirements.md` (Decision 6) applies to `Aiur.AgentList.App.render/1`: thread `surface` through the same `Map.take` list RC uses, or the border never sees it.
- `Aiur.SecretRedactor.redact_urls/1` (`src/lib/aiur/secret_redactor.ex:57`) is the single place to add the `paseo://` pattern.

### Key technical decisions

- KTD-1. A separate `surface` field rather than reusing `remote_control`. RC has semantics (handoff, label-driven, entitlement) that Paseo does not; conflating them would make `remote_control_forced?/1` gates fire for Paseo agents.
- KTD-2. Backend-agnostic. The field is a plain map any adapter can set, so a future sidecar (or the REPL) can report a surface with no core change.
- KTD-3. One redaction rule for both URL kinds, even though the Paseo link is not a secret, to keep the logging invariant simple.

## Acceptance and verification

### Agent gate

- `src/test/aiur/orchestrator/status_report_test.exs`: running entry with `surface` yields `summary.surface == %{kind, label, url}`; without it, `nil`; an RC entry still yields `remote_control` as today.
- `src/test/aiur/agent_list/rc_pane_borders_test.exs`: new clause renders `" 📱 Paseo paseo://h/s/agent/a "`; RC summary unchanged; both present renders RC text.
- `src/test/aiur_web/live/dashboard_live_test.exs` (or the units table component test): a row with `surface` renders an anchor with `href` equal to the URL and `title` equal to the label.
- `src/test/aiur/agent_runner/session_lifecycle_test.exs`: `session_runtime_info/1` includes `surface` for `:headless_wrapper`.
- `src/test/aiur/orchestrator/state_test.exs`: `handle_repl_session_runtime/3` stores `surface`.
- A redaction test: `SecretRedactor.redact("see paseo://h/srv_x/agent/abc")` masks the URL.
- `make all` green.

### At-merge gate

- CI green on the exact head; browser harness for the Units page green.

### Human/manual evidence

- With PSO-011 landed: `scripts/aiurdev --test --force --allow-remote` on a `model:paseo-claude` issue shows `📱 Paseo` in the pane border and the link on `/units`. Before PSO-011, an `Aiur.Orchestrator` `:surface` injected in a test proves the render.

## Failure, security, migration, and accessibility cases

- The dashboard anchor carries `rel="noopener"` and opens in a new tab; the `paseo://` scheme is handled by the desktop app when installed and falls through otherwise.
- The icon has `aria-label="Open in <label>"`.
- No migration; summaries gain a nullable key.

## Surfaces

- Reads: session map `surface`.
- Writes: orchestrator running entry, agent summary, TUI border, Units row, JSON projections, redaction patterns.
- Contracts: `AgentEvents.agent_summary/0` gains `surface`.

## Sibling boundaries and open gates

PSO-001 stores the field on the session; PSO-011 makes the sidecar send it. PSO-015 reuses the field for the mid-run move and is blocked by this ticket.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the approved planning commit linked in this issue's preamble):

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
