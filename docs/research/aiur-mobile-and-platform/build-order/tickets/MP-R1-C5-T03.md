---
ticket_id: MP-R1-C5-T03
feature_id: MP-R1
chunk_id: MP-R1-C5
bucket: 1-refactor
title: Signal port - Aiur.Signal alert and refresh with a registered sink; Alerts becomes the sink; core stops calling AiurWeb.ObservabilityPubSub
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T02]
prior_units: [U3]
prior_boundaries: ["#11 signal (new)", "EXE #26 (Alerts)", "WEB #34 (ObservabilityPubSub)", "ORC #12", "PRJ #28"]
prior_features: [MP-R2, MP-E1, MP-E2]
prior_findings: []
size_owner: "src/lib/aiur/alerts.ex: U8 EVENTS 'Alerts' (746 lines; split) — must not grow"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C5-T03 — Signal port

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C5. Step S1 (prior §7 step 1, boundary
  #11). Path-map row PR-07.
- **User value:** none visible — every alert keeps its files, broadcasts, sound and
  order. It gives every component one low-layer call to say "this happened", which is
  what lets alerts be routed later (MP-E2 escalation, MP-N4 push) without each emitter
  depending on `Aiur.Alerts` (fan-in 60 files / 17 prior boundaries at base).
- **Deliverable (PROPOSED `src/lib/aiur/signal.ex`, component `signal`, L1):**

  ```elixir
  @spec alert(String.t(), keyword()) :: :ok | {:error, term()}                 # ≡ Alerts.emit_system/2
  @spec agent_alert(String.t(), String.t(), keyword()) :: :ok | {:error, term()} # ≡ Alerts.emit_custom/3
  @spec refresh() :: :ok | {:error, term()}                                     # ≡ ObservabilityPubSub.broadcast_update/0
  @spec subscribe_refresh() :: :ok | {:error, term()}                           # ≡ ObservabilityPubSub.subscribe/0
  ```

  - `alert/2` and `agent_alert/3` call the **alert sink** synchronously in the caller's
    process: `Application.fetch_env!(:aiur, :signal)[:alert_sink]` → `sink.emit_system/2`
    or `sink.emit_custom/3`. `src/config/config.exs` sets
    `config :aiur, :signal, alert_sink: Aiur.Alerts` (composition root).
  - `refresh/0` and `subscribe_refresh/0` are implemented **in** `Aiur.Signal` with the
    exact topic `"observability:dashboard"`, message `{:observability_updated, id}` and
    `Process.whereis(Aiur.PubSub)` guard of `AiurWeb.ObservabilityPubSub`
    (`observability_pubsub.ex:6-25`); the web module's functions become `defdelegate`s.
  - Core callers switched in this ticket (the core→web edges): `alerts.ex:197`,
    `orchestrator/snapshot_store.ex:123,147,255`, `recent_merge_store.ex:383`,
    `current_run_projections.ex:163` (`&AiurWeb.ObservabilityPubSub.subscribe/0` →
    `&Aiur.Signal.subscribe_refresh/0`). After it, no module outside `aiur_web/`
    references `AiurWeb.ObservabilityPubSub`.
- **Non-goals:** migrating the 160 alert call sites (C5-T05, C5-T06); lifecycle telemetry
  (C5-T04); changing what an alert writes (prior §6 "every alert writes up to four files
  and three broadcasts"); bus routing of alerts (MP-R2/MP-E2).

## Dependencies and blockers

- DESIGN-R1 §1 (no alert text, sound or ledger change); C1-T02.
- **Settled by RC-24 (X-22).** This ticket owns the `AiurWeb.ObservabilityPubSub` move
  out of the web layer, because the prior survey assigns "a 'dashboard should refresh'
  hint" to the signal port (#11; events contract §2 R-6). MP-R1-C8-T04 dropped its item 1
  and depends on this ticket.
- **Live bug #3009** (`CurrentRunProjections` matches a bare `:observability_updated`
  atom while the broadcast sends `{:observability_updated, id}`): not fixed here; the
  message shape stays the tuple, so the bug is neither fixed nor masked.
- **Concurrent:** C5-T01, C5-T02. **Dependents:** C5-T04, C5-T05, C5-T06, MP-R2-C2-T08 (its
  Alerts callers wait for this port, MP-R2 chunks "Signal port ──► C2-T08"), MP-E1
  (attention function switches to `Signal.alert`, component-map §4 row), C2-T01
  (identity attention).

## Verified starting point (`45a290e3`)

- `Aiur.Alerts.emit_system/2` → `do_emit(name, opts[:message], [event_source: :system | opts])`;
  `emit_custom/3` → `event_source: :agent` (`alerts.ex:103-119`). `do_emit` skips a repeat
  `.resolved` via `AlertFeed.duplicate_resolution?/1` (`:121-142`).
- Side-effect order inside `emit_alert/3` (`alerts.ex:144-200`):
  1. `publish_to_exchange` (always, even without a definition);
  2. `AgentEventLog.write/3` (workspace log);
  3. `write_alert_ledger_entry/3` (`AlertLedger.append`);
  4. `maybe_write_central_alert_feed_entry/4` (central `alerts.ndjson`);
  5. `maybe_play_sound/3`;
  6. `broadcast_agent_alert/5` (`AgentPubSub`);
  7. `ObservabilityPubSub.broadcast_update/0`.
  This is the order the "behaviour proof" research item asks to preserve; because the
  port calls the sink synchronously in the caller's process, the order is unchanged by
  construction.
- `AiurWeb.ObservabilityPubSub` (27 lines) is referenced from core at the five sites above
  (walker: 5 files, prior boundaries EXE, ORC, PRJ, PRL, WEB).

## Chosen design

- **Synchronous delegation, no process.** A GenServer or bus hop would reorder side
  effects relative to the caller's next action and add a failure mode; the port is a
  function call.
- **Missing sink** (`:signal` env absent, e.g. a script that loads code without app
  config): `alert/2` logs `Logger.error("signal: no alert sink registered; dropped <topic>")`
  and returns `{:error, :signal_sink_unregistered}`. It never raises (emitters today do not
  expect a raise from `Alerts`, which rescues internally).
- **Layering:** `Aiur.Signal` references `Phoenix.PubSub`, `Logger`, `Application` only.

## Implementation steps

1. Characterization test on unchanged code: emit a system alert with a temp workspace,
   ledger dir and central feed; record the order of observable effects via injected
   seams (Exchange subscriber, `AgentPubSub` subscriber, `ObservabilityPubSub`
   subscriber, file mtimes) — assert ordering Exchange event before agent-pubsub message
   before observability message, and ledger + central feed lines present.
2. `signal.ex`; config line.
3. `AiurWeb.ObservabilityPubSub` delegates; switch the five core sites.
4. Re-run step 1 through `Aiur.Signal.alert/2`: identical observations.
5. Manifest: `signal` component (`src/lib/aiur/signal.ex`), facade `Aiur.Signal`.

## Non-happy paths

- Sink raises → propagates exactly as a direct `Alerts` call would (no new rescue).
- PubSub down → `refresh/0` returns `:ok` (same as today's guard).
- Tests that call `Aiur.Alerts` directly keep working (Alerts is unchanged).

## Compatibility and rollout

No behaviour change. Rollback: revert.

## Verification

PROPOSED `src/test/aiur/signal_test.exs`:

| Test | Expected |
|---|---|
| `alert delegates to the configured sink with system source` | fake sink receives `emit_system(topic, opts)` once |
| `agent_alert delegates with message` | `emit_custom(topic, msg, opts)` |
| `missing sink returns signal_sink_unregistered and logs` | `{:error, :signal_sink_unregistered}`; `capture_log` contains topic |
| `refresh broadcasts the same message shape as ObservabilityPubSub` | subscriber via `AiurWeb.ObservabilityPubSub.subscribe/0` receives `{:observability_updated, _}` from `Signal.refresh/0` |
| `alert through the port preserves side-effect order` | the step-1 characterization assertions, run through `Signal.alert/2` with the real `Aiur.Alerts` sink and temp dirs |

Plus a source guard (regression, named as such): `rg -n 'AiurWeb.ObservabilityPubSub' src/lib --glob '!src/lib/aiur_web/**'`
returns nothing — implemented as an ExUnit test reading files, or enforced by C1-T03 once
`AiurWeb.*` is `dashboard-ui`/`web-shell` (L4) and the callers are L2/L3.

Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test test/aiur/signal_test.exs test/aiur/alerts_test.exs test/aiur/current_run_projections_test.exs`.

Mutation check: make `refresh/0` broadcast on a different topic → test 4 fails; return
`:ok` when the sink is missing → test 3 fails (unknown-path rule: absence must be
visible).

Manual (AGENTS.md "Manual testing"): foreground `scripts/aiurdev --test`, trigger any
alert path that fires in the sandbox (for example pausing an agent from the TUI), and
confirm the dashboard refreshes and the alert appears in `aiur alerts` exactly as on
`main`.

## Completion and handoff

- [ ] Port merged; five core sites switched; no core reference to
      `AiurWeb.ObservabilityPubSub` remains.
- [ ] Docs: none (no operator-visible change).
- **Dependents:** C5-T04, C5-T05, C5-T06, MP-R2-C2-T08, MP-E1 attention call, C2-T01.
