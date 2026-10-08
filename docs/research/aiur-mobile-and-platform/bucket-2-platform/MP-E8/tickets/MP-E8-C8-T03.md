---
ticket_id: MP-E8-C8-T03
feature_id: MP-E8
chunk_id: MP-E8-C8
bucket: 2-platform
title: Daemon, freshness and offline signals
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T02, MP-E8-C9-T01]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-06, EC-07]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C8-T03 — Daemon, freshness and offline signals

> The home page must never show cached data as current. This ticket maps real
> daemon state into the `daemon` block and the `sources` entries of payload v1.
> It also ports the design's offline mode (`renderOffline`, `.bd-root.stale`,
> `.bd-daemon.off`) so that real signals drive it, not `S.demo`.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C8 (live state,
  usage, daemon status, ticket index).
- **User value.** When the daemon stops, wedges or the socket drops, the operator
  sees it at once. The banner tells them how old the data is ("last heartbeat
  6 min ago (14:14)"), the glows stop, and "Reconnect" works. A healthy page
  says "Daemon live" only when the server read a current snapshot.
- **Deliverables.**
  1. PROPOSED `src/lib/aiur_web/build/freshness.ex` (`AiurWeb.Build.Freshness`).
     Pure mapping functions plus one reader:
     - `daemon(read_result, now_ms) :: map()`: a `SnapshotStore.result()` →
       the v1 `daemon` block;
     - `read_daemon(opts) :: map()`: reads `Orchestrator.dashboard_snapshot/2`
       and calls `daemon/2`;
     - `source(term) :: map()`: a `ProviderHealth`, a `SnapshotStore.result()`
       or `{:disabled, reason}` → a v1 `sources` entry;
     - `push_daemon?(old, new) :: boolean()`: the diff rule for the `daemon`
       block (below).
  2. PROPOSED `src/priv/static/build-home/offline.js`, the `offline.js` row of
     C9-T01's module layout. It registers `fx.renderOffline` and
     `fx.daemonView`, sets `ctx.offline = { isLive, daemonView }` on every
     reset, and exports `fmtAge` and `fmtWhen`. It ports `renderOffline`
     (J:1065–1068) and toggles `.bd-root.stale` (J:1067).
  3. Three one-line edits in C9-T01's `build-home/hook.js`: `import
     "./offline.js"` (C9-T01 rule 2), `fx.renderOffline()` at the end of
     `disconnected` and of `reconnected`, and `ctx.resync = resync` in
     `mounted`.
  4. `build-home/icons.js` (`sv` J:32 and `I` J:33–72, verbatim) only if no
     earlier ticket has created it (the C10-T01 / C10-T04 / C11-T01 rule).
  5. Tests: ExUnit for `Freshness` and a Playwright module spec for
     `offline.js`.
- **Non-goals.**
  - The CSS. `.bd-offline`, `.bd-daemon`, `.bd-root.stale` and `.btn` come
    from `src/priv/static/build-home/home.css` (C2-T03 creates it, C2-T04 fills it). This ticket adds no CSS rule.
  - Subscribing to signals, the daemon tick and the diff stream. C8-T04's
    `AiurWeb.Build.Index` (one process per daemon) subscribes to the signal,
    runs the tick, calls `read_daemon/1` and broadcasts `set.daemon`. This
    ticket adds no `handle_info` to `BuildLive` and no per-tab timer.
  - The board's empty/unavailable markers and their S-9 copy (C9-T13). This
    ticket gives C9-T13 the `sources` entries and `fmtAge`/`fmtWhen`.
  - The status chip markup (C10-T01 `renderStatus`) and the now-band clock
    (C9-T08 `bandClock`, which owns "cached HH:MM"). They read `daemonView()`;
    they do not compute daemon state.
  - The live tail and typing indicator (C11-T05). It reads
    `ctx.offline.isLive()`.
  - Any change to `SnapshotStore` thresholds. The store decides current against
    stale; this ticket only maps its answer.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6). S-16 (Reconnect in progress or
  failed) is this ticket's sign-off item. It follows the S-16 default.
- **Predecessor: MP-E8-C3-T02.** It defines the v1 blocks this ticket fills:
  `daemon: { state: "live"|"stale"|"offline"|"unknown", heartbeat_at: ms|null,
  observed_at: ms|null }` and `sources.<name>: { state:
  "ok"|"stale"|"incomplete"|"unavailable"|"disabled", observed_at: ms|null,
  reason: str|null }` (C3-T02 "Messages (schema v1)"). It also defines the
  `{:build_changes, changes}` message with the `set.daemon` key, `now` as the
  server clock, and the client rule `reconnected()` → resync.
- **Predecessor: MP-E8-C9-T01 (added by this review; not in the README row).**
  C9-T01 fixes the module layout that names `offline.js` and gives it
  `state.js` (`ctx`, `fx`, `onReset`), `life.js` (`ctx.life`), `clock.js`
  (`nowMs()`), `dom.js` (`$`, `esc`) and `hook.js` (which already sets
  `ctx.socket` in `disconnected`/`reconnected`). C9-T01 lists C8-T03 as a
  dependent ("C8-T03 fills `offline.js` and reads `ctx.socket`"). C9-T01 does
  not depend on C8-T03, so the edge adds no cycle. The server part (deliverable
  1) does not need C9-T01 and may land first in its own PR.
- Transitively after C3-T01 (`BuildLive`, the shell with `#bd-offline` and
  `#bd-status`), C2-T03 (`build-home/`) and C2-T04 (the stylesheet).
- **Consumers:** C8-T04 (calls `read_daemon/1`, `source/1`, `push_daemon?/2`;
  already lists C8-T03 in `blocked_by`), C9-T08 (reads `socketDown`), C9-T13,
  C10-T01 (`fx.daemonView`, and `offline.js` calls `fx.renderStatus`), C11-T05
  (`ctx.offline.isLive()`).
- **Runs in parallel with** C8-T01, C8-T02 and the C9–C11 tickets that do not
  list it.

## Verified starting point (`58854d4c8`)

Read in `/home/everdred/github/everdred/aiur-worktrees/runtime/src`.

**Server: the fleet read model already decides freshness.**

- `lib/aiur/orchestrator/snapshot_store.ex`
  - `:69-73` `@type result :: {:current, map(), map()} | {:stale, map(), map()}
    | :snapshot_unpublished | :orchestrator_unavailable`. The comment at
    `:64-68` says the two degraded states "must never collapse into one
    operator-facing message".
  - `:200` `read/2`; `:213-232` `read/3` reads `:persistent_term` only
    (`cached_snapshot/1`, `:359`). It never calls the Orchestrator, so a busy
    mailbox cannot block the page.
  - `:389-398` `no_snapshot_result/1`: no cache and no pid →
    `:orchestrator_unavailable`; a pid without a publish →
    `:snapshot_unpublished`.
  - `:400-424` `metadata/5` returns `status`, `reason`
    (`:orchestrator_unavailable` for a dead pid or an old generation,
    `:snapshot_timeout`, `:snapshot_stalled`, or `nil`), `observed_at` (ISO 8601
    of the last publish, `DateTime.to_iso8601/1`), `age_ms` (monotonic),
    `age_seconds`, `freshness_window_ms`, `orchestrator_mailbox_depth`.
  - `:143-149` `publish/3` calls `ObservabilityPubSub.broadcast_update()` on
    every publish (`:147`).
  - `:62` `@stale_age_ceiling_floor_ms 120_000`; `:446-455`
    `stale_age_ceiling_ms/0`, overridable by the app env
    `:snapshot_stale_age_ceiling_ms` (used by tests).
- `lib/aiur/orchestrator.ex:691` `dashboard_snapshot(server, timeout)` →
  `SnapshotStore.read/2`.
- `lib/aiur_web/controllers/observability_api_controller.ex:159-161` private
  `orchestrator/0` (`Endpoint.config(:orchestrator) || Aiur.Orchestrator`) and
  `:166-168` private `snapshot_timeout_ms/0`
  (`PollCadence.snapshot_tolerance_ms(Endpoint.config(:snapshot_timeout_ms) ||
  15_000, class: :dispatch)`). The comment at `:163-165` explains why a fixed
  15 s is wrong. Both are `defp`, so `Freshness` copies the two one-line
  expressions (it cannot call them).
- `lib/aiur_web/presenter.ex:24-35` maps the same four results for the JSON API
  (`snapshot_unpublished`, `orchestrator_unavailable` as distinct codes) and
  `:58` keeps the freshness map on a stale snapshot. This ticket follows the
  same split.
- `lib/aiur_web/observability_pubsub.ex:9-25` `subscribe/1` and
  `broadcast_update/1` (`{:observability_updated, event_id}`).
  `lib/aiur_web/live/dashboard_live.ex:113` subscribes; `:263` handles it.
  This is "the C8-T03 signal" that C8-T04's parts table names; it exists.
- `lib/aiur/build_order/lifecycle.ex:1-62` `Aiur.BuildOrder.ProviderHealth`
  (`state` `:healthy | :stale | :unavailable | :structurally_invalid`,
  `complete?`, `observed_at` (`DateTime` or `nil`), `failure` (atom or `nil`))
  and `usable?/1` (`:47-51`: healthy, complete and a positive generation).
- `lib/aiur/daemon_heartbeat_checker.ex:1-13` is a retrospective notice at
  Executor start, not a live signal. Not reused (the dashboard runs inside the
  daemon BEAM, so it cannot read its own heartbeat file while the BEAM is down).
- Test patterns: `test/aiur/cadence_freshness_test.exs:35-50` (ceiling env
  saved and restored in `setup`), `:106-110` (`Application.put_env(…, 9_000)`),
  `:292-320` `start_orchestrator/0` (registered stub that never receives) and
  `:322-341` `publish_aged/2` (rewrites `observed_at_ms` and `observed_at`).

**Client: LiveView reports socket loss to hooks.**

- `lib/aiur_web/components/layouts.ex:272-287` creates
  `new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, …)`, calls
  `liveSocket.connect()` and sets `window.liveSocket`. No `disconnectedTimeout`
  option, so the default applies.
- `deps/phoenix_live_view` 1.1.33 (`mix.lock:32`), `assets/js/phoenix_live_view/`:
  - `view.js:330-340` `showLoader()` calls every hook's `__disconnected()`
    (`:336`); `:1289-1291` the channel error path calls `showLoader()` at once,
    then `delayedDisconnected()`; `:355-359` `triggerReconnected()` calls
    `__reconnected()` (`:357`); `:1294-1298` `delayedDisconnected()` runs
    `phx-disconnected` after `liveSocket.disconnectedTimeout`.
  - `live_socket.js:87` `disconnectedTimeout = opts.disconnectedTimeout ||
    DISCONNECTED_TIMEOUT` (`constants.js:98`, 500 ms); `:178` `getSocket()`.
  - `live_socket.js:208-217` `disconnect()` removes `serverCloseRef` (the
    failsafe reload on close code 1000, set only once in
    `bindTopLevelEvents`, `:623-635`). So `disconnect()` then `connect()` loses
    that failsafe for the rest of the page.
- `deps/phoenix` 1.8.9 `assets/js/phoenix/socket.js`:
  - `:170` heartbeat every 30 s by default.
  - `:279-290` `connect()` returns early when `this.conn && !this.disconnecting`.
  - `:546-556` `onConnClose()` after an unclean close does **not** clear
    `this.conn`; it schedules the reconnect timer. **So `liveSocket.connect()`
    after a dropped socket is a no-op** until the timer fires.
  - `:196-203` the reconnect timer runs `this.teardown(() => this.connect())`;
    `:160-166` the visibility handler does the same "reconnect immediately".
    `:498-522` `teardown()` closes and clears `conn`, then calls back.
    `:466-472` `onConnOpen()` resets the reconnect timer. `:599`
    `isConnected()`.
- **There is no `phx:disconnected` window event** in LiveView 1.1.33. The
  row's wording means the hook `disconnected()` callback. (See "Decisions".)
- Precedent: `test/browser/assets/browser_harness.js:18-23` records
  `disconnected()` / `reconnected()` on a data attribute, and
  `browser/tests/support/browser-helpers.mjs:121-126` `reconnectLiveView(page)`
  drives `liveSocket.disconnect()` then `connect()` (a clean disconnect, which
  clears `conn`). C9-T13's end-to-end spec reuses it.
- `lib/aiur_web/components/operator_control_center/dashboard_shell.ex:37-39`
  and `priv/static/dashboard.css:2108-2116`: today's shell "Offline" badge,
  hidden by `[data-phx-main].phx-connected`. It stays; C2-T02 owns the shell.
- `browser/package.json:10` the `test` chain; `:11-19` the
  `node scripts/run-browser-tests.mjs tests/<spec>` script shape.

**Design (the specification).** `design-source/assets/build.js` (J),
`build.css` (C), `Aiur Dashboard.html` (H):

| Element | Where | Must match exactly |
| --- | --- | --- |
| Banner host | J:547 `<div id="bd-offline"></div>`, second child of `#build-root` (J:546–548) | position in the shell (C3-T01 renders it) |
| Banner markup | J:1066 | `<div class="bd-offline">` + `I.warn` svg (J:52) + `<div><b>Daemon offline</b> · last heartbeat 6 min ago (14:14). Showing cached state — agent states and usage may be stale.</div>` + `<button class="btn secondary sm" type="button" id="bd-retry">Reconnect</button>`; the separators are U+00B7 and U+2014 |
| Banner styles | C:93–96 | flex, centre, gap .75rem, padding .7rem .9rem, radius 12px, 1px `--block-line` border, `--block-soft` fill, `--fg` text, .86rem; svg 18×18 in `--block-ink`, `flex: none`; `b` in `--block-ink`; button `margin-left: auto` |
| Button | H:1343–1362 | `.btn` (radius 10px, weight 600, transition 0.14s transform/box-shadow/filter), `.secondary` (`--surface-3`, `--line-strong`), `.sm` (padding .4rem .72rem, .8rem), `:disabled` (opacity .5, no pointer events) |
| Stale root | J:1067 `root.classList.toggle("stale", …)`; C:299–301, 392, 401 | glows paused and grey (`filter: grayscale(1) blur(5px); opacity: .35`), `.bd-gl` `--faint`, `.bd-now` border `--line-strong` and `--bg-2`, `.bd-now::before` `--line-strong` with no shadow, `.ag-active .bd-ag` no animation |
| Status dot | J:1139; C:159–162 | `<span class="bd-daemon[ off]"><i></i>Daemon live|Daemon offline</span>`; mono 600 .68rem in `--muted`; dot 7px with a 3px ring, `--good`/`--good-soft`, or `--block`/`--block-soft` with `--block-ink` text when `.off` (C10-T01 renders it) |
| Band time | J:665 | `"cached " + fmtT(…)` when offline, else `fmtT(NOW)` (C9-T08 renders it from `socketDown` and the daemon block) |
| Time format | J:12–17 | `fmtT` = `HH:MM` in the browser zone; `fmtWD` = `"Tue Oct 6"` |
| Reconnect | J:1068 | click → `setDemo("live")` (mock; replaced) |
| No live tail | J:1411, J:1511 | typing hidden and `startLive` off while offline (C11-T05 reads `isLive()`) |

## Chosen design

### Server: the daemon block

`Freshness.daemon(read_result, now_ms)` maps the store's answer. It never
invents a heartbeat and never returns `live` for an unknown result:

| `SnapshotStore.read/2` result | `state` | `heartbeat_at` |
| --- | --- | --- |
| `{:current, _, md}` | `"live"` | `md.observed_at` → epoch ms |
| `{:stale, _, %{reason: :orchestrator_unavailable} = md}` | `"offline"` | `md.observed_at` → ms |
| `{:stale, _, md}` (`:snapshot_timeout`, `:snapshot_stalled`) | `"stale"` | `md.observed_at` → ms |
| `:orchestrator_unavailable` | `"offline"` | `null` |
| `:snapshot_unpublished` | `"unknown"` | `null` |
| anything else, or an unparsable `observed_at` | `"unknown"` | `null` |

`observed_at` in the block is `now_ms`: the time the server read the store. It
is not the data's time (`heartbeat_at` is). `heartbeat_at` comes from the
ISO 8601 `observed_at` (`DateTime.from_iso8601/1` → `DateTime.to_unix(…,
:millisecond)`), so it is a wall-clock time like `now`.

`read_daemon(opts)` calls `Orchestrator.dashboard_snapshot(orchestrator,
timeout)` with `opts[:orchestrator]` (default `Endpoint.config(:orchestrator) ||
Aiur.Orchestrator`) and `opts[:timeout]` (default the cadence tolerance
expression copied from `observability_api_controller.ex:166-168`), then
`daemon(result, System.os_time(:millisecond))`.

### Server: the diff rule for the daemon block

Every publish broadcasts `{:observability_updated, _}`, and the block's
`observed_at` changes on every read. A plain equality diff would push the block
on every publish for a value the client does not show while live. The rule:

```elixir
def push_daemon?(%{state: s} = old, %{state: s} = new),
  do: s != "live" and old.heartbeat_at != new.heartbeat_at
def push_daemon?(_old, _new), do: true   # state changed, or no previous block
```

C8-T04's Index uses it for the `:daemon` key instead of `==`. A wedged
Orchestrator publishes nothing, so the Index also needs its own tick (C8-T04:
15 s) to see the snapshot go stale. Both reads are one `:persistent_term` read
(`read/3` never calls the Orchestrator).

### Server: source entries

`Freshness.source/1`:

| Input | Entry |
| --- | --- |
| `%ProviderHealth{state: :healthy}` and `ProviderHealth.usable?/1` | `ok`, `observed_at` → ms, `reason: null` |
| `%ProviderHealth{state: :healthy}`, not usable (`complete?: false` or no generation) | `incomplete`, `observed_at` → ms or `null`, reason `"incomplete"` |
| `%ProviderHealth{state: :stale}` | `stale`, `observed_at` → ms or `null`, reason `to_string(failure)` or `null` |
| `%ProviderHealth{state: s}` with `s` in `:unavailable, :structurally_invalid` | `unavailable`, `observed_at` → ms or `null`, reason `to_string(failure || s)` |
| `{:current, _, md}` (agents) | `ok`, `md.observed_at` → ms, `reason: null` |
| `{:stale, _, md}` | `stale`, ms, reason `to_string(md.reason)` |
| `:snapshot_unpublished` / `:orchestrator_unavailable` | `unavailable`, `null`, reason the atom as a string |
| `{:disabled, reason}` | `disabled`, `null`, `to_string(reason)` |
| anything else | `unavailable`, `null`, `"unknown"` |

The state set is exactly C3-T02's. `incomplete` is C3-T02's and C8-T04's word
for a partial read (C8-T04 "History incomplete"), so a partial store is never
`ok` and never mislabelled `stale`.

### Client: `offline.js`

`offline.js` follows C9-T01's rules: it imports `ctx`, `fx`, `onReset` from
`./state.js`, `nowMs` from `./clock.js`, `$` and `esc` from `./dom.js`, `I` from
`./icons.js`; every timer goes through `ctx.life`; module state is reset with
`onReset`. It keeps no clock of its own: `nowMs()` (C9-T01 `clock.js`) is already
the server clock advanced by `performance.now()`.

Inputs (all existing after C9-T01):

- `ctx.socket` (`"up" | "down"`), set by `hook.js` `disconnected`/`reconnected`;
- `ctx.snap.daemon`, the payload-form daemon block (C9-T01 keeps `ctx.snap`
  current across diffs; `intake` drops the block, so `ctx.D` does not have it);
- `nowMs()`.

Module state, reset on every mount:

```js
// downAt: server ms when the drop was first seen, or null; linkDown: debounced
st = { downAt: null, downSeenAt: null, linkDown: false, retry: null, ticking: false }
```

- **Link down, debounced.** `renderOffline()` sees `ctx.socket === "down"` with
  `downSeenAt === null`: it sets `downSeenAt = performance.now()`, `downAt =
  nowMs()` (may be `null` before the first snapshot) and
  `ctx.life.later("offline-link", window.liveSocket?.disconnectedTimeout ?? 500,
  fx.renderOffline)`. `linkDown` becomes true only when that much time has
  passed. `ctx.socket === "up"` clears all three. A drop shorter than
  LiveView's own `phx-disconnected` delay shows nothing.
- **Last heartbeat after a drop** is `downAt`: the server clock at the moment
  the hook heard the socket go. A dead BEAM closes the TCP connection, so the
  hook hears it at once. A silent network loss is heard at Phoenix's heartbeat
  timeout, so the age can read up to about 30 s short (decision 4).
- **Re-render.** `renderOffline()` runs on every hook link change (the two
  hook.js lines), on every applied message (C9-T01 `renderChrome`), and every
  30 s while the banner shows (`ctx.life.every(30_000, …)`, armed once per
  mount through `st.ticking`), so the age moves. When `linkDown` changes it also
  calls `fx.renderStatus()` (C10-T01).

`daemonView()` → `{ stale, dotOff, dotText, banner, socketDown }`:

| Condition (first match) | `dotText` / `dotOff` | Banner headline | Heartbeat used | `.bd-root.stale` |
| --- | --- | --- | --- | --- |
| `linkDown` | "Daemon unreachable" / true | **Daemon unreachable** | `downAt` | yes |
| `daemon.state === "offline"` | "Daemon offline" / true | **Daemon offline** | `daemon.heartbeat_at` | yes |
| `daemon.state === "stale"` | "Daemon stale" / true | **Daemon stale** | `daemon.heartbeat_at` | yes |
| `daemon.state === "live"` | "Daemon live" / false | none | — | no |
| `"unknown"`, any other value, or no daemon block | "Daemon status unknown" / true | none | — | no |

`socketDown` is `linkDown` (C9-T08 reads it; C9-T08 owns the band clock and its
"cached" copy). `banner` is the headline and detail strings, or `null`.

Banner detail, after the bold headline:

- heartbeat known: ` · last heartbeat ${age} (${when}). Showing cached state —
  agent states and usage may be stale.`
- heartbeat `null`: ` · no heartbeat recorded. Showing cached state — agent
  states and usage may be stale.`

`age` (exported as `fmtAge(ms)`): `< 60 s` → "less than 1 min ago"; `< 60 min`
→ "N min ago" (floor); `< 48 h` → "N h ago" (floor); else "N days ago" (floor).
A negative age is clamped to 0. `when` (exported as `fmtWhen(t, now)`):
`fmtT(t)` on the same local day as `now`, else `fmtWD(t) + " " + fmtT(t)`
(`fmtT`, `fmtWD` ported from J:14–17 into `offline.js` unless C9-T01's
`dom.js` or another earlier module already exports them; then import them).
The age base is `nowMs()`; if `nowMs()` is `null`, the heartbeat is treated as
unknown.

`isLive()` = `ctx.socket === "up" && !st.linkDown &&
ctx.snap?.daemon?.state === "live"`.

**Reconnect (S-16).** The banner is J:1066 with the strings computed. The
`#bd-retry` click listener is bound on the new button after each render, as
J:1068 does (an element listener; C9-T01's S2 scan allows it):

- `linkDown` → `retry = "socket"`; `const s = window.liveSocket.getSocket(); if
  (!s.isConnected()) s.teardown(() => s.connect())`. This is the sequence
  Phoenix's own reconnect timer runs (`socket.js:196-203`). A plain
  `liveSocket.connect()` is a no-op here (`socket.js:279-290`, `:546-556`), and
  `liveSocket.disconnect()` first would drop the code-1000 failsafe reload.
- not `linkDown` (server says offline or stale) → `retry = "resync"`;
  `ctx.resync()` (C9-T01's single-flight resync, exposed by the hook.js line).

While `retry` is set, the button has `disabled` and the text "Reconnecting…"
(U+2026). It clears on the next link-up render, on the next applied message, or
after 10 s (`ctx.life.later("offline-retry", 10_000, …)`), whichever comes
first. If the state is still degraded, the banner stays and the button returns
to "Reconnect". Reconnect is not a write, so it works on a read-only dashboard.

**Escaping.** Only times and fixed copy reach the banner today, but every
computed string goes through `esc`.

**Accessibility.** The `.bd-offline` element gets `role="status"`. It does not
change pixels. The headline text carries the state, so the state is never shown
by colour alone.

## Implementation steps

1. **`AiurWeb.Build.Freshness`** (PROPOSED `src/lib/aiur_web/build/freshness.ex`):
   `daemon/2`, `read_daemon/1`, `source/1`, `push_daemon?/2`, and a private
   `ms/1` (`DateTime` or ISO 8601 string → epoch ms, else `nil`). A `@spec` on
   every public function. Moduledoc with the two tables above. Alias
   `Aiur.Orchestrator`, `Aiur.BuildOrder.ProviderHealth`, `Aiur.PollCadence`,
   `AiurWeb.Endpoint`.
2. **`offline.js`** (PROPOSED `src/priv/static/build-home/offline.js`): module
   state with `onReset(() => { st = fresh(); ctx.offline = { isLive, daemonView } })`;
   `renderOffline()` writes `$("#bd-offline").innerHTML` (empty string when no
   banner), toggles `ctx.root.classList` `"stale"`, binds `#bd-retry`;
   `Object.assign(fx, { renderOffline, daemonView })`; `export { fmtAge,
   fmtWhen, daemonView, isLive, renderOffline }`.
3. **`hook.js`** (C9-T01's file): add `import "./offline.js"`; in `mounted`,
   `ctx.resync = resync`; at the end of `disconnected` and `reconnected`,
   `fx.renderOffline()`. No other change.
4. **`icons.js`**: import `I` if the file exists; else create it (deliverable 4).
5. **Tests** as listed in "Verification"; add `test:build-home-offline` to
   `browser/package.json` and to the `test` chain.

## Non-happy paths

- **Daemon BEAM stopped** (`aiurdev stop`, crash). The socket drops; the page
  cannot reach the server at all. After 500 ms: "Daemon unreachable", the time
  of the drop, stale mode. Phoenix retries on its own backoff; "Reconnect"
  retries now. When the BEAM returns, `reconnected()` → C3-T02 resync → a new
  snapshot with a fresh daemon block.
- **Orchestrator down, BEAM up** (same-name restart, crash loop). The socket
  stays up. The store keeps the last snapshot as `{:stale, …,
  :orchestrator_unavailable}` (dead pid or old generation) → "Daemon offline"
  with its real heartbeat time.
- **Orchestrator wedged after draining its mailbox.** No publishes, no
  broadcasts. C8-T04's tick reads `:snapshot_stalled` once the store's ceiling
  (at least 120 s) passes → "Daemon stale".
- **BEAM just restarted.** `:snapshot_unpublished` → "Daemon status unknown",
  dot off, no banner. The agents source is `unavailable` with reason
  `snapshot_unpublished`, so C9-T13 shows "unavailable", not an empty band.
- **Short network blip** (< 500 ms): nothing shows. The C3-T02 resync still runs
  on `reconnected()`.
- **Drop before the first snapshot.** `nowMs()` is `null`, so `downAt` is `null`:
  "no heartbeat recorded", never "0 min ago" or the epoch.
- **Laptop sleep.** `performance.now()` may pause during sleep in some browsers,
  so the age can read short until the next message. On wake the socket is
  usually dead → `disconnected()` → banner. The next `now` from the server
  resets the clock. Recorded, not fixed (no reliable cross-browser signal).
- **Reconnect fails** (S-16): the button re-enables after 10 s; the banner
  stays. Pressing it again while `retry` is set does nothing (it is disabled).
- **Reconnect when the socket is already open again** (a race with Phoenix's
  timer): `isConnected()` is true, so nothing is torn down; the next render
  clears `retry`.
- **Hostile or malformed daemon block** (wrong `state`, string times): C3-T02's
  validator rejects it on the server. On the client, an unknown `state` falls to
  the "unknown" row, never "live", and a non-number `heartbeat_at` is treated as
  `null`.
- **Unknown is never zero.** A `null` heartbeat renders "no heartbeat recorded".
  It never renders "0 min ago", "—", or the current time.
- **Two tabs.** Each tab has its own hook state; the server reads once per Index
  tick for all tabs (C8-T04).
- **Remount** (LiveView navigation away and back): `onReset` clears `st`; the
  old `ctx.life` timers are disposed by C9-T01's `destroyed`.
- **Privacy.** The daemon block carries no financial data and no host names.
  Mailbox depth and the stale reason stay on the server (`daemon/2` keeps only
  `state` and the two times).

## Compatibility and rollout

- No configuration key, CLI flag or environment variable. No user-facing docs
  change: this ships with the new page, whose docs C12 writes.
- The route stays the temporary `/build` until C12-T01. Before C8-T04 lands,
  only the fixture source feeds the page, so the server part is unused code
  with tests.
- Rollback: remove the three hook.js lines; `fx.renderOffline` and
  `fx.daemonView` fall back to C9-T01's no-op defaults (C10-T01 then shows
  "unknown", never "live"). Nothing persists.

## Pixel parity

Design elements: `#bd-offline` › `.bd-offline` (J:1066, C:93–96), `#bd-retry`
(`.btn.secondary.sm`, H:1343–1362), `.bd-root.stale` effects (C:299–301, 392,
401). `.bd-daemon` (J:1139, C:159–162) is C10-T01's cell; the band time (J:665)
is C9-T08's.

Checks through C1-T02's harness (`expectDesignParity`):

- **`offline` dataset**, every viewport/theme/palette cell:
  - `region: '#bd-offline'` must match pixel for pixel. With the fixture block
    (`heartbeat_at` 14:14) and the frozen clock (`NOW` 14:20,
    `America/Los_Angeles`), the product text is exactly "Daemon offline · last
    heartbeat 6 min ago (14:14). Showing cached state — agent states and usage
    may be stale."
  - The full viewport also covers the stale glows.
- **`live` dataset:** `#bd-offline` is empty (zero height) on both sides.
- C1-T03 `inventory` asserts that glows are `paused` for `offline` (C1-T03
  table, C:299). This ticket's class toggle is what makes it pass.

These cells stay red in report mode until the page renders real data; C9-T13
enforces them (handoff). The states the design does not draw ("unreachable",
"stale", "status unknown", "Reconnecting…") have no design pixel to match. Their
layout is the same `.bd-offline` element and the same button with only the text
changed; they are listed for Kevin in "Decisions".

## Verification

**ExUnit** (PROPOSED `src/test/aiur_web/build/freshness_test.exs`). It copies
`start_orchestrator/0` and `publish_aged/2` from
`test/aiur/cadence_freshness_test.exs:292-341`, and the ceiling save/restore
`setup` from `:35-50`. Each test passes `orchestrator:` and `timeout:` to
`read_daemon/1`.

| # | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| F1 | stub orchestrator, fresh `publish` | `state: "live"`, `heartbeat_at` within 1 s of `System.os_time(:millisecond)`, `observed_at` ≥ `heartbeat_at` | map `:current` to `"unknown"` |
| F2 | ceiling 9_000, `publish_aged(name, 10_000)` | `state: "stale"`, `heartbeat_at` ≈ now − 10 000 (±1 s) | collapse `{:stale, …}` to `"live"` |
| F3 | publish, then kill the stub pid | `state: "offline"`, `heartbeat_at` = that publish time (±1 s) | map the `:orchestrator_unavailable` reason to `"stale"` |
| F4 | name never registered, no cache | `state: "offline"`, `heartbeat_at: nil` (not `0`, not now) | `heartbeat_at: now_ms` in that clause |
| F5 | registered pid, no publish | `state: "unknown"`, `heartbeat_at: nil` | map `:snapshot_unpublished` to `"live"` |
| F6 | `daemon(:something_else, now)` and `daemon({:current, %{}, %{observed_at: "x"}}, now)` | `state: "unknown"`, `heartbeat_at: nil` | a catch-all to `"live"`; `ms/1` returning `0` on a parse error |
| F7 | `push_daemon?` live→live with a new heartbeat and a new `observed_at` | `false` | drop the `s != "live"` term |
| F8 | live→stale; stale→stale with a new heartbeat; `nil`→live | `true` each | `def push_daemon?(_, _), do: false` |
| F9 | `source/1` on `ProviderHealth.new(1, :healthy, true, observed_at: t)`, `new(1, :healthy, false, …)`, `new(:x, :healthy, true, …)`, `new(1, :stale, true, failure: :timeout, …)`, `new(1, :unavailable, false)`, `new(1, :structurally_invalid, false)` | `ok`; `incomplete "incomplete"`; `incomplete`; `stale "timeout"`; `unavailable "unavailable"`; `unavailable "structurally_invalid"`; `observed_at` = `DateTime.to_unix(t, :millisecond)` or `nil` | map healthy-incomplete to `ok`; skip `usable?/1` (third case reads `ok`) |
| F10 | `source(:boom)`, `source({:disabled, :no_queue})`, `source(:snapshot_unpublished)` | `unavailable "unknown"`; `disabled "no_queue"`; `unavailable "snapshot_unpublished"` | a catch-all to `ok` |
| F11 | F3's result passed to `daemon/2` | the map has exactly the keys `state`, `heartbeat_at`, `observed_at` | leaking `reason` or `orchestrator_mailbox_depth` into the block |

**Browser** (PROPOSED `src/browser/tests/build-home-offline.browser.spec.mjs`,
npm script `test:build-home-offline`, added to the `test` chain). A blank page
with a minimal `#build-root` › `#bd-offline` host imports the real
`/build-home/state.js`, `life.js`, `clock.js` and `offline.js`, runs
`resetState({})` and sets `ctx.life = createLife()`, `ctx.root` and
`ctx.resync` (a spy) in C9-T01's `mounted` order. `window.liveSocket` is a fake
whose `getSocket()` returns `{ isConnected, teardown(cb), connect }` spies and
`disconnectedTimeout: 500`. `page.clock.install()` and
`test.use({ timezoneId: 'America/Los_Angeles' })`. `NOW` = 1791408000000
(2026-10-07 14:20 PDT). "Link down" = `ctx.socket = "down"; fx.renderOffline()`.

| # | Steps | Expected | Fails without |
| --- | --- | --- | --- |
| B1 | `setNow(NOW)`, `ctx.snap = { daemon: live }`; link down; advance 400 ms; link up | no `.bd-offline`; root has no `stale` | the debounce |
| B2 | link down; advance 600 ms | `.bd-offline b` = "Daemon unreachable"; root `.stale`; `daemonView()` `dotText` "Daemon unreachable", `dotOff`, `socketDown` true | the link branch |
| B3 | B2, then advance 6 min | text contains "last heartbeat 6 min ago (14:20)" | the 30 s re-render (`ctx.life.every`), or `downAt` taken at each render |
| B4 | `ctx.snap.daemon = {state:"offline", heartbeat_at: NOW−360000}`; render | `#bd-offline` text is exactly "Daemon offline · last heartbeat 6 min ago (14:14). Showing cached state — agent states and usage may be stale."; `daemonView().socketDown` false | the port |
| B5 | offline with `heartbeat_at: null`; and B2 with `nowMs()` null (no `setNow`) | "no heartbeat recorded" both times; no digit before " min ago", no "—", no "14:20" | **AGENTS.md mutation:** replace the null branch with `0`, with "—" and with `nowMs()`; each must fail |
| B6 | `{state:"unknown"}`, then `{state:"bogus"}`, then no daemon block | each: `dotText` "Daemon status unknown", `dotOff`; no banner; root not stale; `isLive()` false | **mutation:** treat unknown as live |
| B7 | `{state:"stale", heartbeat_at: NOW − 3 h}` | "Daemon stale · last heartbeat 3 h ago (11:20)" | collapsing stale into "offline" copy |
| B8 | offline, heartbeat `NOW − 24 h` | "(Tue Oct 6 14:20)" | always `fmtT` |
| B9 | B2; click `#bd-retry` | `teardown` called once, then `connect` from its callback; button `disabled`, text "Reconnecting…"; a second click calls nothing | the S-16 state; calling `liveSocket.connect()` instead |
| B10 | B9, advance 10 s, still down | button enabled, "Reconnect"; banner present | the timeout |
| B11 | B9, then link up with a live block | banner gone, root not stale, `isLive()` true | clearing on link up |
| B12 | link up, server offline; click | `ctx.resync` called once; `teardown` not called | the branch |
| B13 | B2, then `ctx.life.dispose()`; `resetState({})` | no timers pending (`page.clock` runs 60 s with no render call); `daemonView().socketDown` false | the `onReset` and `ctx.life` use |
| B14 | axe on B4 | `.bd-offline[role=status]`; no violations in `#bd-offline` | the role |
| B15 | B2 | `fx.renderStatus` spy called once when `linkDown` turns true | the C10-T01 call |

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C /path/to/aiur/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/build/freshness_test.exs
env -C /path/to/aiur/src/browser npm run test:build-home-offline
```

**Mutation check (AGENTS.md).** For each row with a mutation: apply it in a
worktree, confirm `git status --porcelain` shows only that hunk, run the test,
see it fail, restore, see it pass. Put the exact commands and results in the PR
body.

**Manual (AGENTS.md "Manual testing").** Once C8-T04 and C12-T01 land, on
`scripts/aiurdev --test` in the wrapper tmux: open the home page, run
`aiurdev stop` from a fresh shell, and look at the page: "Daemon unreachable",
greyed glows. Start it again: the banner goes. This is C12-T01's run; this
ticket lists the steps.

## Completion and handoff

- [ ] `Freshness` with the mapping tables in its moduledoc; F1–F11 green.
- [ ] `offline.js` registers `fx.renderOffline`, `fx.daemonView`, sets
      `ctx.offline`, exports `fmtAge`, `fmtWhen`; B1–B15 green.
- [ ] The three hook.js lines; no other hook.js change.
- [ ] Every mutation listed above fails, with the commands in the PR body.
- [ ] No CSS added; no design string changed for the `offline` state.

**Handoffs.**

- **C8-T04:** the "C8-T03 signal" is `ObservabilityPubSub.subscribe/1`
  (`{:observability_updated, _}`). The daemon part is `Freshness.read_daemon/1`;
  diff it with `Freshness.push_daemon?/2`, not `==` (its `observed_at` changes
  on every read). Build `sources.history` with `Freshness.source/1`;
  `sources.agents` comes from C8-T01 (`NowRows.build/2` `source`), and this
  ticket's surfaces only render its age (settled 2026-10-08). Keep the 15 s tick: it is what detects a wedged
  Orchestrator.
- **C9-T01:** `offline.js` adds three lines to `hook.js` (above) and reads
  `ctx.snap.daemon`. If C9-T01 renames `ctx.snap` or `resync`, use the new names.
- **C10-T01:** render `.bd-daemon` from `fx.daemonView()` (`dotText`,
  `dotOff`); `offline.js` calls `fx.renderStatus()` when the link changes. The
  fifth field is `socketDown`, not `bandTime`.
- **C9-T08:** read `fx.daemonView().socketDown` for its `socketDown` input.
- **C9-T13:** enforce the parity cells above, and add the end-to-end spec on
  `productUrl("live")` (R-G7): `window.liveSocket.disconnect()` then
  `connect()`, with the banner visible between them; S-9 markers use `fmtAge`/`fmtWhen`.
- **C11-T05:** gate the live tail and typing on `ctx.offline.isLive()`.
- **C1-T01:** settled 2026-10-08: the `offline` daemon block's `observed_at`
  is `NOW` (server read time). No client reads it, so no pixel changes.
- **Sources:** this pack's plan §8 (EC-06, EC-07), DESIGN-E8 S-16, S-33, C3-T02
  "Messages (schema v1)", C9-T01 "Module layout", C8-T04 "Parts and their
  failure states", the code cited above.

## Decisions made without the owner

1. **"`phx:disconnected`" means the hook's `disconnected()` callback.**
   LiveView 1.1.33 dispatches no `phx:disconnected` window event; the hook
   callbacks (`view.js:336`, `:357`) are the supported signal, C9-T01's hook
   already handles them, and the repo's harness uses them.
2. **A 500 ms debounce before stale mode,** read from
   `liveSocket.disconnectedTimeout`. Without it every socket blip flashes the red
   banner. It matches when LiveView itself runs `phx-disconnected`.
3. **Three degraded headlines, not one.** The design draws only "Daemon
   offline". Socket loss ("Daemon unreachable"), a dead Orchestrator ("Daemon
   offline") and an aged snapshot ("Daemon stale") have different causes, and
   AGENTS.md forbids collapsing a cause into a specific wrong one. Same element,
   same styles, only the bold word changes. "Daemon status unknown" (dot only,
   no banner) covers the first seconds after a restart. Kevin may merge them.
   This is DESIGN-E8 sign-off item S-33.
4. **"Last heartbeat" after socket loss is the server-clock time when the hook
   heard the drop** (`nowMs()` at the first `disconnected`). The daemon block's
   `heartbeat_at` is not pushed while live, so it would read older than the
   truth. A silent network loss is heard only at Phoenix's heartbeat timeout,
   so the age can read up to about 30 s short; the copy has minute resolution.
   This replaces a socket `onMessage` listener, which C9-T01's `ctx.life` cannot
   release.
5. **No daemon diff while live unless the state changes.** The client shows no
   daemon time while live, and publishes are frequent.
6. **The server tick and subscription belong to C8-T04's Index,** not to each
   BuildLive. C8-T04 already runs one process per daemon with a 15 s tick; a
   per-tab copy would push a second, unnumbered `set.daemon` beside the Index's
   (C3-T02 `index_generation`).
7. **Reconnect uses `teardown(() => connect())` on the Phoenix socket,** not
   the row's `liveSocket.connect()`. After an unclean close `connect()` returns
   early (`socket.js:279-290`, `:546-556`), so the row's call would do nothing.
   `disconnect()` + `connect()` works but drops LiveView's code-1000 failsafe
   reload (`live_socket.js:208-217`, `:623-635`).
8. **Reconnect when the socket is up resyncs** instead of doing nothing, so the
   button is useful in the "offline" and "stale" states. The 10 s "failed"
   timeout follows S-16's default ("on failure the banner stays").
9. **Age wording beyond the design** ("less than 1 min ago", "N h ago", "N days
   ago", the weekday form for another day). The design shows only "6 min ago
   (14:14)". The `offline` fixture prints exactly that.
10. **`role="status"` on the banner.** Accessibility is never cut; it does not
    change pixels.
11. **A healthy but not usable `ProviderHealth` is `incomplete`,** the C3-T02
    state, judged by the existing `ProviderHealth.usable?/1`.
12. **Complexity 3, not the row's 2:** server mapping, the client state machine
    with the S-16 states, and two test suites over real modules.

## Review log

Adversarial review, 2026-10-08, against the sources (runtime `58854d4c8`,
design-source, README, chunks, C1-T01, C3-T02, C8-T04, C9-T01, C9-T08, C9-T13,
C10-T01, C11-T05):

1. **Removed the BuildLive `handle_info` clauses, `Freshness.subscribe/1` and
   the per-tab 10 s tick.** C8-T04 (already `blocked_by` C8-T03) owns the
   subscription and a 15 s tick in its shared Index; the per-tab path would have
   pushed `set.daemon` diffs outside the Index's `index_generation`. L1–L4
   dropped; the `push_daemon?/2` handoff moved to C8-T04.
2. **Reconnect fixed.** `liveSocket.connect()` is a no-op after an unclean
   close (`socket.js:279-290`, `:546-556`); now `teardown(() => connect())`.
   B9 asserts it. Decision 7 records the deviation from the row.
3. **Client rebuilt on C9-T01's module layout:** `fx.renderOffline` /
   `fx.daemonView`, `ctx.life` timers (S2 scan), `clock.js` `now()` instead of
   a second clock, `ctx.socket` from hook.js, `ctx.snap.daemon`,
   `ctx.offline` for C11-T05, `fx.renderStatus` for C10-T01. Added
   MP-E8-C9-T01 to `blocked_by` (C9-T01 lists C8-T03 as dependent; no cycle).
4. **Dropped `bandTime`** from `daemonView()`: C9-T08 owns the band clock and
   asked C8-T03 not to render one; `socketDown` replaces it.
5. **`sources` gains `incomplete`** (C3-T02 enum, C8-T04 "History incomplete")
   via `ProviderHealth.usable?/1`; it was mislabelled `stale`.
6. **The writer's flagged mismatches:** C8-T04 already lists C8-T03; C1-T01
   already has no `cached_at`. Removed implementation step 4 (fixture
   alignment); the remaining `observed_at` difference is a non-blocking note.
7. **Citations corrected:** controller helpers are `defp` (copied, not
   reused); `view.js:330-340` (was 329-339); `orchestrator.ex:691`;
   `no_snapshot_result/1` `:389-398`; ceiling floor `:62`; test-pattern lines
   `:35-50`, `:292-341`; added `socket.js` reconnect lines and `usable?/1`.
8. **Design table:** `.bd-daemon` text colour `--muted`; banner `align-items:
   center` and svg `flex: none`; `.bd-now::before` exact values.
9. **Tests:** browser spec pinned to `America/Los_Angeles` and `NOW`
   (B3/B8 times corrected to what the fixture produces); B5 covers `now()`
   null; B6 covers an unknown value; B13 tests reset/dispose instead of an
   `off` ref; added B15, F11 (no metadata leak) and more F9/F10 cases.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `build-home/home.css` (R-G8), `now()` -> `nowMs()` (R-G9), degraded headlines = S-33, `sources.agents` owner is C8-T01 (handoff), C9-T13 e2e handoff uses `productUrl`/`window.liveSocket` not `reconnectLiveView`/`/build?fixture=`, C1-T01 `observed_at` note marked settled.
