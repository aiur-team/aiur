---
ticket_id: MP-E8-C8-T02
feature_id: MP-E8
chunk_id: MP-E8-C8
bucket: 2-platform
title: Usage strip data
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-25, EC-12]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C8-T02 — Usage strip data

> **Wave 0b.** Paths are cited at `58854d4c8` under `src/`. Paths marked PROPOSED
> do not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`. This ticket draws nothing. It produces the
> `usage` block of the C3-T02 payload from the meters Aiur already has, and keeps
> it live. C10-T04 renders it.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C8 (live state,
  usage, daemon status, ticket index).
- **User value.** The usage strip above the board shows the real provider
  windows, accounts, credits and GitHub budget, with the same look as the design.
  A value Aiur does not know reaches the browser as `null` or as "not observed",
  never as `0%`. A locked dashboard session receives no usage values at all.
- **Deliverable.**
  1. PROPOSED module `AiurWeb.Build.Usage` (`src/lib/aiur_web/build/usage.ex`).
     `financial` is C3-T02's form, `{:ok, %FinancialDataAccess.Context{}} | :locked`
     (`MP-E8-C3-T02.md`, `source_opts/1`):
     - `block(financial, inputs, now)`: pure. Returns the C3-T02 `usage` block
       (`authorized`, `locked` or `unavailable`). No I/O.
     - `load(context, opts \\ [])`: reads the inputs through the existing
       sources (provider meters through the `FinancialData` facade, Claude account
       readings, GitHub quota, ElevenLabs quota, the durable dispatch ledger
       file). Each source fails alone.
     - `read(financial, opts \\ [])`: `block(financial, load(ctx, opts), now)` for
       `{:ok, ctx}`; the locked block for `:locked` with no `load/2` call.
       `opts[:reload]` (a `{FinancialData, :updated, _}` message) makes the meter
       read use `ProviderMeterSource.reload/3` instead of `load/2`.
     - `subscribe(financial)`: `ProviderMeterSource.subscribe(ctx)` for
       `{:ok, ctx}`; `:ok` and no call for `:locked`.
     C8-T04's `IndexSource.subscribe/1` and `snapshot/1` call `subscribe/1` and
     `read/2` (`MP-E8-C8-T04.md`, "DataSource callbacks").
  2. PROPOSED shared module `AiurWeb.ProviderMeterWindows`
     (`src/lib/aiur_web/provider_meter_windows.ex`): the session/weekly window
     classification moved, unchanged, out of `AiurWeb.StreamdeckProjection`, so
     the deck and the home strip classify windows with one rule.
  3. BuildLive glue (C3-T01's module): the usage watch events, the coalesced
     meter reload on `{FinancialData, :updated, _}`, the GitHub and ElevenLabs
     ticks, and a `set.usage` diff only when the block changed. The subscribe
     call itself is C8-T04's (through `Usage.subscribe/1`), so there is one
     subscription per socket.
  4. A hidden `id="usage-watch"` element with `phx-hook="UsageWatch"` on the home
     page, so provider polling continues after Units retires.
- **Non-goals.**
  - No rendering, CSS, popover or `fitResets` (C10-T04).
  - No payload schema redesign (C3-T02). This ticket adds its four optional
    `prow` fields (§4.6) to `Payload.validate/1` and the C3-T02 fixture mapper
    in its own PR (R-G1).
  - No cost accounting (`UsageAggregate`, `GroupedScopes`, the Build Order
    `UsageRuntime`). The design strip shows quota windows, not money spent.
  - No new GitHub, provider or ElevenLabs requests. Every input is a read of a
    process that already exists, plus one small local file read
    (`ModelAvailability.load/1`, the durable ledger, as Units does today).
  - No "Search" row: Aiur has no search provider meter at `58854d4c8` (§3).

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8.** The strip's content is the design's `PSETS` shape
  (J:991–1011) and `renderUsage` (J:1029–1043). Sign-off items that touch it:
  - **S-13** (logo for a model the design lacks: muse, openrouter, unknown): this
    ticket sends `logo: null` and a `mono` letter for them, as the default says.
  - **OQ-E8-8** (models counter): the count is the real provider row count. The
    button is C10-T04's.
  - The missing "Search" row and the ElevenLabs row in its slot are planner
    decisions (§10, items 1 and 2) for Kevin to confirm at sign-off (S-32).
- **Blocked by MP-E8-C3-T02.** That ticket fixes the `usage` block shape, the
  `set.usage` diff key and the locked block (`MP-E8-C3-T02.md`, "Messages
  (schema v1)"). This ticket fills the block and must pass its validator.
- **Successors.**
  - **C10-T04** (usage strip) renders this block.
  - **C8-T04** (index assembler) calls `Usage.subscribe/1` from
    `IndexSource.subscribe/1` and `Usage.read/2` from `IndexSource.snapshot/1`,
    per socket, never in the shared index (`MP-E8-C8-T04.md`, handoff note 6).
    C8-T04 lists this ticket in its `blocked_by`.
  - **C12-T01** (cutover) removes `DashboardLive`'s copy of the watch events
    when `/` stops being Units.
- **Runs concurrently with** C8-T01, C8-T03 and all of C4–C7. It touches no file
  they touch, except BuildLive (one `handle_event` clause group and one
  `handle_info` clause group, appended, plus one assign line in C3-T02's
  snapshot and `build-resync` branches).

## 3. Verified starting point (`58854d4c8`)

**Provider meters (the Models card).**
- `lib/aiur_web/operator_control_center/provider_meter_source.ex`: `load/2`
  (lines 35–42), `reload/3` (48–55) and `subscribe/1` (59) read every provider
  through `FinancialData.fetch_provider_meter/5` and `FinancialData.reload/7`.
  `fetch_one/2` (69–78) turns any error or raise into `nil` for that provider
  only. The read is `ProviderMeterProjection.redacted_snapshot/1` (line 94).
- `lib/aiur_web/operator_control_center/provider_meters_presenter.ex`:
  - `present/3` (64–78): an authorized capability gives one card per
    `CodingAgent.provider_families()` (`lib/aiur/coding_agent.ex:233`); a locked
    one gives `cards: []`.
  - `card_state/1` (181–206) maps a snapshot to `:loading` (nil snapshot, no
    observation, missing credentials), `:signed_out`, `:unknown`, `:unavailable`,
    `:healthy`, `:partial`, `:error` (stale, real failure, no windows) or
    `:stale`.
  - `known_identity?/1` (175–176): windows are shown only for `:healthy`,
    `:partial` and `:stale`.
  - A provider not observed this boot is **`:unknown`, not `:loading`**: the
    projection returns `ProviderMeterSnapshot.unknown/2`
    (`lib/aiur/provider_meter_snapshot.ex:81-94`, `failure:
    :unknown_account_generation`), which `card_state/1` line 183 maps to
    `:unknown`. The browser fixture uses it for Claude
    (`test/browser/fixture_server.exs:1924`, `ProviderMetersLive`, the fixture the
    README row names).
  - `windows/2` (289–295) returns a **list** of `window_view/2` maps sorted by
    kind; each keeps `limit_id` as a string.
  - `window_view/2` (297–330) keeps `kind`, `coverage`, `used_percent`,
    `duration_minutes`, `resets_at`, `credits`, `limit`, `remaining`.
  - `meter/2` (347–351) gives `%{kind: :exact, now: 0..100}` only for a
    `:supported` window with a number; anything else is `%{kind: :none}`.
    The moduledoc says "Zero is a real exact value, distinct from unknown".
  - `account_usage/1` (134–152) needs two or more account readings and keeps a
    per-account `percent` that may be `nil`.
- `lib/aiur_web/live/dashboard_live.ex` (the Units page) wires all of this:
  - `@provider_meters_flush_ms 250` (line 90);
  - `handle_info({FinancialData, :updated, _identity})` (288–295) and
    `:flush_provider_meters` (301–303);
  - `assign_initial_provider_meters/2` (1760–1777): load and subscribe only when
    connected and authorized;
  - `schedule_provider_meters_reload/2` (1782–1791) and `flush_provider_meters/1`
    (1793–1809): one reload per window;
  - `apply_provider_meters/1` (1811–1830): account readings are
    `UsageReadings.snapshot("claude", Accounts.configured_names())`, with
    `["default"]` when no names are configured;
  - `provider_meter_source/0` (1836–1841) and the flush timer (1843–1847) are
    injectable through `Endpoint.config/1`.
- `lib/aiur/accounts/usage_readings.ex`: `snapshot/2` (13–22) returns
  `%{name => %{reading, observed_at, freshness, reason}}`; `record/5` (33–37)
  stores `reading: nil, freshness: :unavailable` on an error.
- `lib/aiur/claude/usage_api.ex:40-45`: Claude account windows are
  `"seven_day"` (weekly), `"seven_day_opus"`, `"seven_day_sonnet"` and
  `"five_hour"` (session); each `window_reading` has `used_percent` (number or
  `nil`) and `resets_at` (lines 53–67).
- `lib/aiur_web/streamdeck_projection.ex`: the deck already picks a session and a
  weekly window per provider. `@session_window_tokens` and
  `@weekly_window_tokens` (lines 11–12); `meter_windows/2`, `eligible_window?/2`,
  `semantic_windows/1`, `unclassified_windows/1`, `window_matches?/2`,
  `fallback_window/2`, `window_duration/1` (361–421), and the `field/2` helper
  they use (line 533). All private. They take a **map** `%{limit_id => window}`
  from the raw snapshot, not the presenter's list. Tests:
  `test/aiur_web/streamdeck_projection_test.exs:13`, `:62`, `:117`, `:135`, `:153`.

**The current strip (Units), which the design replaces.**
`lib/aiur_web/components/operator_control_center/run_summary_strip.ex`:
- `@github_resources ~w(core graphql)` (line 22); `apis_card/1` (56–110) always
  shows a GitHub row and an ElevenLabs row only when configured
  (`elevenlabs_configured?/1`, 311–313).
- `keyed_cards/1`, `provider_keyed?/1`, `env_present?/1` (437–457): an
  OpenAI-compatible provider shows only when its key env var is set.
- `order_cards/1` (462–470): DeepSeek first (`@lead_provider`, line 17).
- `put_durable_observation/1` … `durable_percent_entry/1` (477–526): a card in
  state **`:unknown`** (line 477, the unobserved case above) gets its last
  durable standing from `ModelAvailability.load/0`, which is a `File.read` of
  `model-usage.json` beside the workflow file (`lib/aiur/model_availability.ex:40-50`).
  `durable_percent_entry/1` (519–526) uses an `fn` with one guarded clause, so an
  entry whose `limit` is `0` or not a number raises `FunctionClauseError`. A
  second copy of the same code is in `streamdeck_projection.ex:309-337`.
- ElevenLabs words: `elevenlabs_failure_label/1` (388–393); counts:
  `compact_number/1` (688–690, `"90.0K"`).
- `meter_windows/1` (549–562): Codex credit windows and `local-concurrency` are
  dropped (568–572).
- **Credit windows.** `lib/aiur/open_ai_compat/provider_meter_probe.ex:187-201`
  (`credit_window/5`): `credits: %{status, amount}` where `amount` is a float,
  `remaining: amount`, `used_percent` only when a baseline exists
  (`balance_used_percent/3`, 174–185). There is **no `limit` key**, so the
  original balance is not in the window.
- **Unknown-as-zero traps that must not be copied:** `meter_percent/1` returns
  `0` for an unknown window (line 699), and `elevenlabs_meter_percent/1` returns
  `0` (line 316).

**GitHub budget (the APIs card).** `lib/aiur/github/quota.ex`:
- `@primary_resources ~w(core graphql)` (47), `@low_water_percent 10.0` (54),
  `@quota_window_seconds 60 * 60` (58, both budgets are one-hour windows).
- `snapshot/1` (120–125) catches an exit and returns `@unknown_snapshot`
  (87–95, `state: :unknown`). `snapshot!/1` (134) does not catch, "when an
  unreachable meter must be reported as an error rather than presented as an
  empty measurement".
- `handle_call(:snapshot)` (251–273): `windows` keyed `"core"`/`"graphql"`, each
  with `limit`, `remaining`, `reset_at`, `observed_at` (406–429) plus `used`,
  `used_percent` (1294–1302); `backoffs: [%{resource, until, seconds_remaining}]`
  (604–610).
- `window_status/4` (480–492) and `below_floor?/2` (1320) define a hold:
  `remaining * 100 <= limit * 10.0` before `reset_at`. `dispatch_status/2`
  (508–515) applies it with `@low_water_percent` to both primary resources:
  this is the **dispatch** hold. A secondary-limit backoff is a different hold:
  `preflight` (276–289) uses `resource_status/4` (470–478) with floor `0.0`, so
  a backoff holds **requests** to that resource, not dispatch.
- `DashboardLive` polls it in memory every 15 s (`@github_quota_tick_ms`, line
  76; mount 130; `handle_info(:github_quota_tick)` 248–250; `github_quota_snapshot/0`
  2697). This is a GenServer call, not a GitHub request.

**ElevenLabs.** `lib/aiur/eleven_labs/quota.ex`: states `:unconfigured`,
`:unknown`, `:observed`, `:failed` (moduledoc 17–25); `snapshot/1` (81–85)
returns `:unconfigured` on exit; the window has `limit`, `used`, `remaining`,
`used_percent`, `reset_at` (218–235). `DashboardLive` ticks it every 60 s (line 80).

**Search.** `grep -rli "tavily|brave_search|exa_api|serpapi|search_provider|perplexity" src/lib`
finds nothing. No search provider meter exists.

**Polling only while watched.** `lib/aiur/provider_meter_refresh.ex` moduledoc
(1–23): provider usage is observed only while a surface is watched.
`watching_started/1` (65) and `watching_stopped/1` (74) register the caller pid.
The `UsageWatch` hook (`lib/aiur_web/components/layouts.ex:133-157`) pushes
`usage-watch-start`/`-stop`, and only `DashboardLive` handles them (702–710). If
the home page does not do the same, provider meters stop refreshing when Units
retires. The hook reads only `document.visibilityState` and `document.hasFocus()`,
never the element's own box, so a `hidden` element reports correctly. On Units
the hook sits on the visible `control-panel` div (`dashboard_live.ex:975-979`).
`ProviderMeterRefresh` is one named child of the application
(`lib/aiur.ex:417`); `DashboardLive` calls it with the default name and there is
no injection seam. `test/aiur_web/live/zero_fetch_page_open_test.exs:61` and
`:202` use the `usage-watch` id as the marker for `/`.

**Financial gate.** `lib/aiur_web/financial_data_access.ex`: `on_mount/4`
(98–111) assigns `:financial_data_capability`; `context/1` (115); `authorize/1`
(123–129); `locked_capability/0` (144–153, value-free).
`lib/aiur_web/operator_control_center/money.ex:18-37`: `format_amount/1` gives
two decimals from a `Decimal`.

**The design.** `PSETS` (J:991–1011): `{ name, logo, fill?, mono?, hue?,
accounts?, session: {acc, reset, win}, weekly, credits: {pct, left, tip}, none? }`.
`prow` (J:1021–1028): credits → one line; `none` → one dashed line with "not
observed" and tip `[["Limits", "not reported by provider"]]`; else a session and
a weekly line with `pct = avg(acc)`. `winTip` (J:1020) lists `[account, acc%]`
per account. The APIs card (J:1031–1036): GitHub with lines `core` and `gql`
(tip "Requests left" / "Points left", `"4,736 of 5,000"`, window `1h`) and a
"Search" row with a `credits` line (window `30d`). Header "2 APIs" is a literal
(J:1038). `.ax-ln` (C:784–785), `.ax-bar.none` (C:74), `.ax-seg i.z` (C:77).

## 4. Chosen design

### 4.1 Inputs (`load/2`)

```elixir
%{
  families:  [provider_atom],                                      # CodingAgent.provider_families(), keyed filter applied
  meters:    %{provider_atom => ProviderMeterSnapshot.t() | nil},  # ProviderMeterSource.load/2 or reload/3
  accounts:  %{name => reading},                                   # UsageReadings.snapshot("claude", names)
  durable:   %{provider_atom => %{percent, observed_at} | nil},    # ModelAvailability.load/1
  github:    {:ok, quota_snapshot} | {:error, :unavailable},       # GitHubQuota.snapshot!/1, exit caught here
  elevenlabs: elevenlabs_snapshot                                   # ElevenLabsQuota.snapshot/1
}
```

`load/2` is called only with an authorized context. `opts` takes
`meter_source:`, `github_server:`, `elevenlabs_server:`, `accounts_fun:` and
`durable_path:` (passed to `ModelAvailability.load/1`) for tests, so no test
reads the real `model-usage.json` (AGENTS.md "Reading real state"). The keyed
filter (`keyed?/1`, step 2) runs here, because it reads `System.get_env/1` and
`CodingAgent.backends/0`; `block/3` then stays pure. `github` uses `snapshot!/1` inside a `catch :exit`, so "meter process
down" (`:unavailable`) stays distinct from "nothing observed yet" (`state:
:unknown`). This follows AGENTS.md "a collapsed cause names the collapse".

### 4.2 Output (`block/3`)

- `financial == :locked` → the locked block from C3-T02:
  `%{state: "locked", accessible_name, reason, authentication_path}` copied from
  `FinancialDataAccess.locked_capability/0`. No other key. `load/2` is not
  called (`read/2` returns before it).
- `inputs == :error` (load raised) → `%{state: "unavailable", observed_at: nil,
  reason: "usage_source_failed"}`.
- Otherwise `%{state: "authorized", observed_at, apis: [prow], providers: [prow]}`.
  `observed_at` is the newest `observed_at` of any row, or `nil`.

### 4.3 Provider rows

One row per provider in `inputs.families` (registry order, keyed filter already
applied by `load/2`: an OpenAI-compatible provider without its key env var is
left out, as `run_summary_strip.ex:437-457` does today). `block/3` calls
`ProviderMetersPresenter.present(%{state: :authorized}, inputs.meters, %{})`
once and takes the card of each family in `inputs.families`, so the identity
rule (`known_identity?/1`) and the state names are the presenter's, not new
ones. A family with no card (not in the registry) gives no row.

| Presenter card state | Row |
| --- | --- |
| `:healthy`, `:partial` | windows → `session`/`weekly`, or `credits` (below) |
| `:stale` | same values, `stale: true` |
| `:unknown` (the normal "not observed this boot" case, `ProviderMeterSnapshot.unknown/2`) | `none: true`, `note: "Awaiting first observation"`; with a durable record (Units' rule, `run_summary_strip.ex:477`): `none: true`, `note: "Last known <N>% (previous boot)"`, `observed_at` from the record, `stale: true` |
| `:loading` (nil snapshot, `:no_observation`, credentials missing) | `none: true`, `note: "Awaiting first observation"` |
| `:signed_out` | `none: true`, `note: "Not signed in"` |
| `:error`, `:unavailable` | `none: true`, `note:` the presenter's `health.failure_label` (for example "Transport error"), or "Unavailable" when it is `nil` |

**Window choice.** The presenter's `windows` list, filtered to `kind:
:rate_limit` without `limit_id == "local-concurrency"`, is turned into the map
the deck code expects (`Map.new(windows, &{&1.limit_id, &1})`; `window_view/2`
keeps `kind`, `limit_id` and `duration_minutes`, which is all the deck rules
read) and goes through `ProviderMeterWindows.semantic/2`. The session window is
the one whose `limit_id` has a session token, else the shortest; the weekly one
has a weekly token, else the longest (`five_hour`, `primary`, … /
`seven_day`, `secondary`, …). Credit windows are removed before the call, so
the deck's "credit takes the session slot" rule does not fire here. The
returned `{limit_id, window_view}` pairs give back the presenter maps with their
`meter` field.

**Credits.** A provider with no rate-limit window and a credit window (not
Codex, `run_summary_strip.ex:568`) gets `credits`:
- `pct`: `meter.now` when the window's `meter.kind == :exact` (the probe sets
  `used_percent` only with a baseline), else `nil` (#1436: no baseline means no
  bar, not 0%);
- `left`: `"$" <> Money.format_amount(to_string(amount))` when `credits.amount`
  is a number (`10.4` → `"$10.40"`; `format_amount/1` returns `"unknown"` for a
  bare float, so the `to_string/1` is required); else `"unknown"`;
- `tip`: `[["Prepaid credits", "$10.40 left"]]`. The window has no `limit`
  (§3, credit windows), so the design's "of $10.65" part cannot be sent (§9).

**Window values.** `win = %{acc: [pct | nil], reset_at: ms | nil, win: str | nil}`:
- `pct` is `meter.now` when `meter.kind == :exact`, else `nil`. Never `0` for
  unknown (`meter_percent/1` at `run_summary_strip.ex:699` is the trap).
- `reset_at` is `resets_at` in Unix ms, or `nil`.
- `win` is from `duration_minutes`: divisible by 1440 → `"Nd"`, by 60 → `"Nh"`,
  else `"Nm"`. Without a duration, from the id token: `five_hour` → `"5h"`,
  `seven_day` → `"7d"`. Otherwise `nil` (the design's `ln` then prints no
  `/win`, J:1017). It never guesses `"5h"`.
- A window whose `reset_at` is before `now` has ended. Its `pct` belongs to the
  old window, so the row gets `stale: true`.

**Several accounts (Claude only, EC-25).** When `accounts` has two or more
names, `accounts` is the sorted name list and the two lines come from the
readings: `session.acc` from each reading's `"five_hour"`, `weekly.acc` from
`"seven_day"`, in the same order. A reading with `reading: nil` or a window
without a number gives `nil` in its slot. `reset_at` is the soonest non-nil
`resets_at` of that window over the accounts. The row's `observed_at` is the
newest reading `observed_at`. `UsageReadings.snapshot/2` leaves out a configured
name that has no reading yet, so such an account is absent, not a `nil` slot;
the count is the number of readings, as the presenter's `account_usage/1`
counts it. With zero or one reading the projection windows are used, and
`accounts` is `nil` (no `×N` chip, J:1019).

**Identity of the row.**
- `name`: the presenter's `provider_label`.
- `logo`: the logo key for `claude`, `codex`, `deepseek`, `kimi` (the keys of
  C2-T03's `build-home/logos.js`, which carries `src` and `fill`); else `nil`.
- `mono`: the first letter of `name`, uppercased, when `logo` is `nil` (S-13).
  `hue: nil` (the `.ax-mono` default background `#8b6cf0`, C:59).

**Order.** The design's order for the design's providers (claude, codex, kimi,
deepseek, from `PSETS[4]`), then every other provider in registry order. The
Units-only "DeepSeek leads" rule is not used (§10, item 4).

### 4.4 API rows

Each API row has `lines: [line]` (§4.6) instead of `session`/`weekly`, where
`line = %{tag, acc: [pct | nil], reset_at, win, tip, hold_until}`.

- **GitHub** (`name: "GitHub"`, `icon: "github"`), always present:
  - `core` line (tag `"core"`) and `graphql` line (tag `"gql"`, J:1034), in that
    order.
  - Observed window: `acc: [round(used_percent)]`, `reset_at`, `win: "1h"`
    (`@quota_window_seconds`), `tip: [["Requests left", "4,736 of 5,000"]]`
    (core) or `[["Points left", …]]` (gql), numbers with thousands separators.
  - Hold: `hold_until` is the window's `reset_at` when it is below the 10 %
    floor before its reset (the `dispatch_status/2` rule, so the strip agrees
    with dispatch), else the backoff's `until` when a backoff for that resource
    is active (a request hold, §3), else `nil`. When both apply, the later time
    wins. The server adds no tip row for it: C10-T04 appends `["Held for", …]`
    from `hold_until` (`MP-E8-C10-T04.md` §4.4), so a server row would be a
    duplicate.
  - Window missing from an observed snapshot, or `state: :unknown`:
    `acc: [nil]`, `reset_at: nil`, tip `[["Requests left", "not observed yet"]]`.
  - `{:error, :unavailable}`: same `nil` values, tip
    `[["Requests left", "GitHub budget meter unavailable"]]`.
- **ElevenLabs**, only when its state is not `:unconfigured` (main's rule):
  `name: "ElevenLabs"`, `icon: nil`, `mono: "E"`, one line tag `"credits"`,
  `acc: [round(used_percent) | nil]`, `reset_at`, `win: nil` (the API reports no
  window length), tip `[["Credits left", "90.0K"]]` from `remaining` through
  `compact_number/1` (moved with the other helpers, step 2). `:unknown` gives
  `nil` values and "not observed yet"; `:failed` gives `nil` values and the
  words of `elevenlabs_failure_label/1` (for example "the API key was
  rejected"), moved the same way. The invoice amount is not sent (the design
  has none).
- **Search:** no row (§3).

### 4.5 Live updates (BuildLive)

- **Mount and resync:** C3-T01 calls `DataSource.subscribe` in the LiveView
  process before the first snapshot; C8-T04's `IndexSource` calls
  `Usage.subscribe(financial)` there and `Usage.read(financial)` inside
  `snapshot/1`. Locked: no subscribe, no load. This ticket stores the `usage`
  block of every snapshot and resync reply as `:build_usage_last` (in C3-T02's
  `handle_async(:build_snapshot, …)` and `build-resync` branches), so the first
  tick after a snapshot compares against what the browser has. When connected
  and `financial` is `{:ok, _}`, mount schedules the two ticks and keeps their
  refs in `:build_usage_timers`; a locked or disconnected mount leaves it `nil`.
- **`{FinancialData, :updated, _} = message`:** keep the newest message and
  schedule one `:build_usage_flush` after 250 ms (the dashboard's value; timer
  injectable through `Endpoint.config(:build_usage_flush_timer)`, as
  `schedule_provider_meters_flush/0` does at `dashboard_live.ex:1843-1847`).
  The flush calls C3-T02's `source_opts(socket)[:financial]`, which re-runs
  `FinancialDataAccess.authorize/1`.
  - `{:ok, _}`: `Usage.read(financial, reload: message)`, then push
    `set.usage` through C3-T02's diff path (generation + 1, `build-diff`) only
    if the block differs from `:build_usage_last`.
  - `:locked` (access revoked since mount): C3-T02 step 4 deletes `set.usage`
    for a locked socket, so a pushed locked block would never arrive. Instead
    drop `:build_usage_last`, cancel the ticks, and push the empty diff with
    generation + 2 (C3-T02's `resync: true` path). The client sees the gap and
    resyncs; the resync reply carries the locked block from `source_opts/1`.
- **Ticks:** `:build_usage_github_tick` every 15 s and
  `:build_usage_elevenlabs_tick` every 60 s, the dashboard's values
  (`dashboard_live.ex:76`, `:80`). Each tick re-schedules itself, calls
  `Usage.read(financial)` and uses the same compare-then-push and the same
  locked branch. The meter part of that read goes through the facade with
  `@max_age_ms 5_000` (`provider_meter_source.ex:23`) and reads
  `ProviderMeterProjection`, not a provider, so a tick makes no provider or
  GitHub request.
- **Watch:** BuildLive handles `usage-watch-start` → `ProviderMeterRefresh.watching_started()`
  and `usage-watch-stop` → `watching_stopped()`. The page renders
  `<div id="usage-watch" phx-hook="UsageWatch" hidden></div>` outside
  `#build-root`. `hidden` gives it no box, so no pixel changes.
- **Ages:** `observed_at` is sent, not a preformatted age, so the client can show
  a current age (AGENTS.md "a computed age is rendered").

### 4.6 Additive `prow` fields (interface)

C3-T02's `prow` (`{ name, logo, mono, hue, tag, accounts, session, weekly,
credits, none }`, `win = {acc, reset_at, win: str}`) cannot carry four facts this
ticket must send. Additions, all optional, all `null` by default (settled
2026-10-08, R-G1; listed in C3-T02's accepted additive fields table):

1. `lines: [line] | null`: the GitHub row has two tagged lines with their own
   tips (J:1033–1034). One `tag` per row cannot express it.
2. `icon: "github" | null`: the GitHub row uses an icon, not a logo (J:1032).
   (The design's `"bars"` icon was for Search, which is not sent.)
3. `stale: bool`, `observed_at: ms | null`, `note: str | null` per row: EC-07 and
   EC-25 need stale values marked and the reason for "not observed".
4. `win.win: str | null`: a window with no known length.

Each `line` is `{ tag: str, acc: [int | null], reset_at: ms | null, win: str |
null, tip: [[str, str]], hold_until: ms | null }`; `hold_until` is part of item 1
and C10-T04 reads it (`MP-E8-C10-T04.md` §4.1). This ticket adds the fields to
`Payload.validate/1` and to the C3-T02 fixture mapper in its own PR (R-G1).

`logo` is a key into C2-T03's `LOGOS` table, not a URL; `fill` then comes from
that table, so no `fill` field is needed. This ticket must not ship values the
validator does not accept.

## 5. Implementation steps

1. **Move the window classification.** Create PROPOSED
   `AiurWeb.ProviderMeterWindows` with `semantic/2` (`windows`, `provider`) made
   of `meter_windows/2`, `eligible_window?/2`, `semantic_windows/1` and helpers
   from `streamdeck_projection.ex:361-421`, copied verbatim with a private copy
   of `field/2` (line 533; the deck keeps its own for its other callers), plus
   the two token attributes. `semantic/2` takes the same map
   `%{limit_id => window}` the deck passes today and returns
   `[{"session", {limit_id, window}}, {"weekly", …}]`. Change
   `normalized_windows/5` there (line 346) to call it. Run
   `streamdeck_projection_test.exs` unchanged: it must stay green.
2. **Make the keyed filter, the durable read and the ElevenLabs words public in
   one place.** Move `provider_keyed?/1` + `env_present?/1`,
   `durable_observation/1` + helpers, `elevenlabs_failure_label/1` and
   `compact_number/1` (`run_summary_strip.ex:437-457`, `477-526`, `388-393`,
   `688-690`) into `AiurWeb.Build.Usage` as `keyed?/1`, `durable/2` (provider,
   path; the default path is `ModelAvailability.path/0`), `elevenlabs_failure/1`
   and `compact_number/1` (`@doc false`). `RunSummaryStrip` calls them, so the
   copy count does not grow. Move them unchanged (the `durable_percent_entry/1`
   raise stays; `load/2`'s per-source wrapper contains it, U15). Run
   `run_summary_strip_test.exs` unchanged.
3. **Write `block/3`** (§4.2–4.4) as pure functions with no process reads.
   `DateTime.to_unix(dt, :millisecond)` for every time.
4. **Write `load/2`** (§4.1). Each source is wrapped on its own; a raise in
   one gives that source's unknown value (`nil` meters, `{:error, :unavailable}`
   GitHub, `:unconfigured` ElevenLabs), not a whole-block failure. Only a raise
   outside the per-source wrappers gives `:error`.
5. **Write `read/2` and `subscribe/1`** (§1). `read/2` reads `now` once
   (`DateTime.utc_now/0`, or `opts[:now]` in tests).
6. **BuildLive glue** (§4.5): the tick scheduling at mount, `:build_usage_last`
   from each snapshot and resync reply, the two `handle_event` clauses, the
   flush and tick `handle_info` clauses, the locked branch through C3-T02's
   resync path, and the hidden watch element. Do not call `Usage.subscribe/1`
   from BuildLive: C8-T04's `IndexSource.subscribe/1` does (one subscription
   per socket). Until C8-T04 lands, C3-T02's fixture source keeps its fixture
   `usage`, and the V-tests drive the clauses by sending messages to the view.
7. **Fixture inputs.** PROPOSED `test/support/build_home/usage_inputs.ex`
   builds `inputs` that reproduce `PSETS[4]`: Claude with accounts
   `["Max · work", "Pro · personal"]` session `[1, 3]` weekly `[96, 86]`; Codex
   `[0]`/`[0]` (snapshot shaped like `ProviderMetersLive.codex/0`,
   `fixture_server.exs:1924`); Kimi `[9]`/`[14]`; DeepSeek credit window
   `amount: 10.4`, `used_percent: 2.0`; GitHub core 4,736/5,000 and graphql
   4,998/5,000. Used by the tests and the parity check (§9).

## 6. Non-happy paths

- **Locked session (EC-12).** No `load/2`, no subscribe, no ticks, no values in
  the payload. A flush or tick whose `authorize/1` fails forces a resync
  (§4.5), whose reply carries the locked block. The GitHub and ElevenLabs
  budgets are also withheld, which is stricter than Units (§10, item 5).
- **One provider fails.** `fetch_one/2` already returns `nil`; the row becomes
  `none: true` with "Awaiting first observation". Other rows are unchanged.
- **Malformed durable ledger entry** (`limit: 0`): `durable_percent_entry/1`
  raises; the per-source wrapper gives `durable: %{}` and every row keeps its
  live value (U15).
- **Second account configured but never read:** absent from `accounts`, not a
  `nil` slot (§4.3).
- **GitHub meter process down.** `{:error, :unavailable}` (§4.4), never "0%".
- **Account reading failed.** That account's slot is `nil`; the other
  accounts keep their values.
- **Window ended** (`reset_at < now`): `stale: true` (§4.3).
- **Unknown provider family** (a new registry entry): `logo: nil`, mono letter,
  windows as for any provider.
- **Burst of updates.** Ten `:updated` messages in one window give one reload
  and at most one push.
- **Disconnect.** The new LiveView process mounts again and sends a fresh block
  in the snapshot. The ticks and the watch registration belong to the process,
  so a closed tab withdraws itself (`ProviderMeterRefresh` monitors the pid).
- **Untrusted text.** Account names come from config. The block sends them as
  raw text; C10-T04 escapes them (§11).
- **Privacy.** No account generation, generation label, auth mode, email or
  token leaves the server. The tips hold only names, percentages, counts and
  money left.

## 7. Compatibility and rollout

- No config key, CLI flag or env var. No docs page changes (AGENTS.md "Docs ship
  with the change": internal data for a page C12 documents).
- `StreamdeckProjection` and `RunSummaryStrip` change only by moving code into
  shared modules; their tests guard them unchanged.
- `DashboardLive` keeps its own watch events until C12-T01. Two pages that both
  register are fine: `ProviderMeterRefresh` keys watchers by pid.
- Rollback: revert this ticket; the home strip then gets no `usage` block, and
  C3-T02's validator rejects the snapshot, so it must be reverted with C10-T04.

## 8. Verification

ExUnit, PROPOSED `test/aiur_web/build/usage_test.exs` (pure, `async: true`) and
`test/aiur_web/live/build_live_usage_test.exs`. "Mutation" names the production
change that each test must fail against (AGENTS.md rule).

| # | Input | Expected | Mutation that must fail it |
| --- | --- | --- | --- |
| U1 | Codex healthy, windows 300 min 42 % and 10080 min 61 % | `session.acc == [42]`, `win "5h"`; `weekly.acc == [61]`, `win "7d"`; `reset_at` in ms | swap `:shortest`/`:longest` in the classification |
| U2 | healthy window with `coverage: :empty_supported` | `acc == [nil]`; JSON has `"acc":[null]` | `pct` fallback changed to `0` (the `run_summary_strip.ex:699` shape) |
| U3 | real zero: `:supported`, `used_percent: 0` | `acc == [0]` | treating `0` as unknown |
| U4 | nil snapshot; `ProviderMeterSnapshot.unknown(:codex, :app_server)` with no durable record; `:signed_out` (`:no_oauth_token`); `:error` (stale, `:transport`, no windows) | `none: true` with notes "Awaiting first observation", "Awaiting first observation", "Not signed in", "Transport error"; no `session`/`weekly` | collapsing the three distinct notes to one, or emitting empty windows |
| U5 | `:stale` card with windows | values kept, `stale: true`, `observed_at` = snapshot ms | `stale` hard-coded `false` |
| U6 | `ProviderMeterSnapshot.unknown(:codex, :app_server)` and a temp `durable_path` whose Codex entry is `hourly` used 100 / limit 100 | `none: true`, note "Last known 100% (previous boot)", `stale: true`, `observed_at` from the record | dropping the durable branch |
| U7 | DeepSeek credit window from `credit_window/5`'s shape: `amount: 10.4`, no `used_percent`; then the same with `used_percent: 2.0` | first: `credits == %{pct: nil, left: "$10.40", tip: [["Prepaid credits", "$10.40 left"]]}`; second: `pct: 2` | `pct` fallback `0`; calling `Money.format_amount/1` on the float (gives `"$unknown"`) |
| U8 | Claude with readings `work` (5h 1, 7d 96) and `personal` (`reading: nil`) | `accounts == ["personal", "work"]`, `session.acc == [nil, 1]`, `weekly.acc == [nil, 96]` | mapping a `nil` reading to `0` |
| U9 | one account configured | `accounts == nil`, lines from the projection | using readings for one account |
| U10 | `families: [:muse]` (a registry family with no `LOGOS` key) | `logo: nil`, `mono: "M"`, `hue: nil` | a fallback logo key |
| U11 | `load/2` with an OpenAI-compatible provider's key env var unset, then set (temp env, restored in `on_exit`) | `families` lacks it, then has it | removing the keyed filter |
| U12 | `Usage.order_families/1` (`@doc false`, used by `block/3`) on `[:codex, :claude, :deepseek, :kimi, :muse]` | `[:claude, :codex, :kimi, :deepseek, :muse]` | keeping registry order or DeepSeek first |
| U13 | window with no `duration_minutes` and id `"x:other"` | `win == nil` | defaulting to `"5h"` |
| U14 | `reset_at` one minute before `now` | `stale: true` | ignoring ended windows |
| U15 | `load/2` with a temp `durable_path` whose Codex entry has `limit: 0` | `durable == %{}`; `meters` and `github` still read; no raise | removing the per-source wrapper around the durable read |
| G1 | GitHub core 4,736/5,000, graphql 4,998/5,000 | lines `core` `[5]` tip "4,736 of 5,000", `gql` `[0]` "4,998 of 5,000", both `win "1h"` | swapping tags or tip labels |
| G2 | GitHub `@unknown_snapshot` shape | `acc [nil]`, "not observed yet" | mapping unknown to `[0]` |
| G3 | `github: {:error, :unavailable}` | `acc [nil]`, "GitHub budget meter unavailable" | collapsing G2 and G3 into one note |
| G4 | core remaining 400/5,000 before reset; graphql backoff `until` | core `hold_until == reset_at` ms; gql `hold_until == until` ms; neither tip has a hold row | removing the floor or the backoff check |
| G5 | GitHub at 600/5,000 (12 %) | `hold_until == nil` | floor set above 10 % |
| E1 | ElevenLabs `:unconfigured` / `:unknown` / `:failed :authentication` | no row / `acc [nil]` "not observed yet" / `acc [nil]` with the reason | always adding the row; `0` for unknown |
| E2 | any inputs | no row named "Search" | adding a Search row |
| L1 | `Usage.read(:locked, meter_source: Spy)`; `Usage.subscribe(:locked)` | block has exactly `state, accessible_name, reason, authentication_path` with `locked_capability/0`'s values; the spy records no `load`, `reload` or `subscribe` call | always building the authorized block; subscribing when locked |
| L2 | every block from U1–E2 | `Payload.validate/1` (C3-T02) returns `:ok` | — (contract guard) |
| P1 | `UsageInputs.psets4()` | per provider row, equal to C3-T02's `live` fixture `usage.providers` on `name`, `logo`, `accounts`, `session.acc`, `session.win`, `weekly.acc`, `weekly.win`, `credits.pct`, `credits.left`, and the order of rows; GitHub row `lines` tags, `acc`, `win` and tips equal to J:1033–1034. Not compared: `reset_at` (the fixture derives it from strings), `observed_at`, `stale`, `note`, the credits tip (§9), the Search row | any mapping drift |

LiveView (`build_live_usage_test.exs`), with `ConnCase` and injected timer and
source through `Endpoint.config` (as `DashboardLive` tests do):

| # | Action | Expected | Mutation |
| --- | --- | --- | --- |
| V1 | `render_hook(view, "usage-watch-start", %{})` | `:sys.get_state(Aiur.ProviderMeterRefresh).watchers` has `view.pid` (the app's named child, `lib/aiur.ex:417`; there is no injection seam, as for `DashboardLive`); after `"usage-watch-stop"` the pid is no longer a focused watcher | removing the clauses |
| V2 | send three `{FinancialData, :updated, id}`, fire the timer once | source `reload/3` called once; one `build-diff` with `set.usage` | reloading per message |
| V3 | after the first snapshot, `send(view.pid, :build_usage_github_tick)` with an unchanged quota | no `build-diff` (`refute_push_event`) | pushing every tick; not storing `:build_usage_last` from the snapshot |
| V4 | flush after the config generation changed (authorize fails) | one `build-diff` with generation + 2 and no `set.usage`; the next `build-resync` reply's `usage` is the locked block; no further tick is scheduled | skipping `authorize/1`; pushing a locked `set.usage` (C3-T02 deletes it, so the browser keeps old values) |
| V5 | `live(conn, "/build")` (C3-T01's route before cutover; C12-T01 moves the test to `/`) | HTML has an element with `id="usage-watch"`, `phx-hook="UsageWatch"` and `hidden` | removing the element |
| V6 | locked mount (`financial: :locked`) | the `:build_usage_timers` assign is `nil` (read through `:sys.get_state(view.pid)`) and a sent `:build_usage_github_tick` pushes nothing and schedules nothing | scheduling ticks before the gate; a tick that skips the gate |

Existing suites that must stay green: `streamdeck_projection_test.exs`,
`run_summary_strip_test.exs`, `provider_meters_presenter_test.exs`,
`zero_fetch_page_open_test.exs`.

Commands (from `src/`, isolated HOME as the memory note "mix test clobbers
agent-token" requires):

```bash
HOME=$(mktemp -d) env -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/build/usage_test.exs test/aiur_web/live/build_live_usage_test.exs \
  test/aiur_web/streamdeck_projection_test.exs \
  test/aiur_web/components/operator_control_center/run_summary_strip_test.exs \
  test/aiur_web/components/operator_control_center/provider_meters_presenter_test.exs \
  test/aiur_web/live/zero_fetch_page_open_test.exs
mise exec -- mix format --check-formatted && mise exec -- mix credo --strict
```

Manual: covered by C10-T04 and C12-T01 (the strip is drawn there). This ticket's
manual check is `aiurdev agents` plus opening the home page with dashboard auth
and confirming in the browser devtools that the `build-resync` reply's `usage`
block has the live values, and that with the tab hidden for more than the grace
period `ProviderMeterRefresh` stops observing (its log line).

## 9. Pixel parity

This ticket draws nothing, so parity is proved through data:

- **Design elements fed:** `PSETS` (J:991–1011), `tone`/`avg`/`bar`/`ln`/`whoH`/`winTip`/`prow`
  (J:1012–1028), the APIs block of `renderUsage` (J:1031–1036).
- **Check:** P1 above proves the real presenter, fed `PSETS[4]`-shaped facts,
  produces the same values, field by field, that C1-T01/C3-T02 derive from the
  design. C10-T04 then
  runs C1-T02's side-by-side screenshot of `#bd-usage` with that block against
  the design at `?models=4`; any difference is C10-T04's failing test.
- **Known, intended differences** (S-32, for Kevin's sign-off, not silent):
  - the credits tip is `"$10.40 left"`, not the design's `"$10.40 of $10.65
    left"`: the credit window carries no starting balance (§3). Showing it would
    need the probe's `BalanceBaseline` in the window, which is a probe change
    outside this ticket;
  - no "Search" row; real account names;
  - "2 APIs" becomes the real count (C10-T04 counts `apis`).
- What must match exactly and is carried by data: `acc` integer percentages
  (the design's widths, J:1014, and the `z` class for `0`, C:77), the order of
  the session line before the weekly line, `core` before `gql`, the `×N` count
  from `accounts.length`, credits as one line.

## 10. Decisions made without the owner

1. **No Search row.** No search meter exists. The README row says omit it. The
   APIs card therefore shows one row (GitHub) or two (GitHub, ElevenLabs).
2. **ElevenLabs keeps its row** in the slot the design gives Search, with the
   Search row's `credits` line and a mono "E". Dropping it would remove a meter
   Units shows today (`run_summary_strip.ex:52-55`).
3. **Muse gets the mono letter** even though `/provider-assets/muse.svg` exists
   (`providers/muse.ex:38`, `priv/static/muse.svg`),
   because S-13's default covers muse. Kevin's S-13 answer may switch it to the
   real logo.
4. **Design order** (claude, codex, kimi, deepseek, then registry order) instead
   of Units' DeepSeek-first rule.
5. **A locked session also gets no GitHub or ElevenLabs budget.** Units shows
   both without the financial gate. C3-T02's locked block is value-free, and
   one rule is simpler than a split block. The budget stays visible in
   `aiur github-cost`.
6. **Hold has no new look.** The design has no hold state; the data carries
   `hold_until` only and C10-T04 adds the "Held for" tip row. A floor hold
   (dispatch) and a backoff (requests) share the one field. Kevin may ask
   for a visible mark.
7. **Rate limits win over credits** for a provider that has both: two lines
   at most, as the design's rows have.
8. **Multi-account reset** is the soonest reset among the accounts.
9. **Usage loads per connection,** not in C8-T04's shared index, because the
   financial gate is per session. C8-T04's `IndexSource` calls
   `Usage.subscribe/1` and `Usage.read/2` (its own plan); BuildLive does not
   subscribe a second time.
10. **Revoked access forces a resync** instead of pushing a locked
    `set.usage`, because C3-T02 deletes `set.usage` for a locked socket. Reuses
    C3-T02's gap rule; no C3-T02 change.
11. **The durable "last known" value applies to `:unknown` cards only,** as in
    Units (`run_summary_strip.ex:477`). `:loading` cards (nil snapshot,
    credentials missing) show "Awaiting first observation" without it.
12. **Ticks re-read every source** through `read/2` instead of holding the
    inputs in the socket. Each read is a GenServer call, a projection or
    `:persistent_term` read, or one small file read, so no held state is needed.

## 11. Completion and handoff

- [ ] `AiurWeb.Build.Usage.block/3` and `load/2` with U1–U15, G1–G5, E1–E2, L1–L2, P1
      green, each mutation in §8 run and failing (commands named in the PR body).
- [ ] `AiurWeb.ProviderMeterWindows` extracted; Stream Deck and strip suites
      unchanged and green.
- [ ] BuildLive watch events, coalesced flush, ticks, compare-then-push and the locked resync, V1–V6.
- [ ] No `0` for an unknown value anywhere in the block (U2, U7, U8, G2, G3, E1).
- [ ] Locked payload has no values (L1, V4).
- [ ] §4.6 fields added to `Payload.validate/1` and the C3-T02 fixture mapper
      in this PR (R-G1).

**Handoff notes for neighbours.**
- **C3-T02:** settled 2026-10-08: this ticket adds the optional `prow` fields
  in §4.6 (`lines` with `hold_until`, `icon`, `stale`, `observed_at`, `note`,
  `win.win: null`) in its own PR (R-G1); `logo` is a `LOGOS` key.
- **C10-T04:** the design's `avg()` (J:1013) adds `null` as `0`; it must average
  only the numbers and give `pct: null` when none is a number. The design puts
  `p.name` into `<b>` without `esc` (J:1018); account and provider names must be
  escaped. `PSETS.length` drives the `n2/n4/n7` class (J:1037); real counts can
  be 1, 3, 5 or 6. Render `note`, `stale`, `observed_at` (age) and `hold_until`
  in the tip.
- **C8-T04:** call `Usage.subscribe(financial)` from `IndexSource.subscribe/1`
  and `Usage.read(financial)` from `IndexSource.snapshot/1`, per socket; never
  put usage in the `build-home:index` topic. The "provider meters" topic in the
  README row is this per-socket subscription.
- **C12-T01:** remove `DashboardLive`'s watch clauses when `/` becomes home; the
  `usage-watch` id keeps `zero_fetch_page_open_test.exs:61` valid.

Sources: `plan.md` §5.1 ("Usage" row), §8 (EC-12, EC-25); `tickets/README.md`
C8-T02, C10-T04, C8-T04 rows; `MP-E8-C3-T02.md` (usage block, `prow`);
`MP-E8-C2-T03.md` (`LOGOS` keys); `DESIGN-E8.md` S-13, S-32; `questions.md` OQ-E8-8.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8` sources, design-source and
the C3-T02, C8-T04 and C10-T04 ticket files.

1. Interface: `block/3` took a capability map; C3-T02 and C8-T04 pass
   `financial: {:ok, ctx} | :locked`. Changed the argument and added `read/2` and
   `subscribe/1`, which C8-T04's `IndexSource` already plans to call.
2. Interface: the handoff told C8-T04 not to subscribe, while C8-T04 subscribes
   through C8-T02. Aligned on C8-T04's plan; BuildLive no longer subscribes
   (one subscription per socket).
3. Correctness: a revoked-access flush pushed a locked `set.usage`, which
   C3-T02 step 4 deletes for a locked socket, so the browser would keep old
   values. Replaced with C3-T02's resync gap (§4.5, V4, decision 10).
4. Correctness: the never-observed provider is `:unknown`
   (`ProviderMeterSnapshot.unknown/2`), not `:loading`, and Units attaches the
   durable record to `:unknown`. Fixed the state table, U4, U6 (decision 11).
5. Correctness: credit windows have no `limit`, and `Money.format_amount/1`
   returns `"unknown"` for a float. Fixed `left`/`tip`, U7, §9 difference.
6. Feasibility: the deck's window functions take a map, the presenter gives a
   list; added the conversion and the `field/2` helper.
7. Feasibility: `block/3` was not pure (keyed filter reads env and registry);
   moved the filter into `load/2` with `families` input. U10 dropped the
   impossible unregistered `:zz`; U11 is a `load/2` test; U12 tests a pure
   order helper.
8. Feasibility: `ModelAvailability.load/0` is a file read, not in-memory; added
   `durable_path:` so tests do not read real state; new U15 for the raising
   `durable_percent_entry/1`.
9. Semantics: GitHub backoff is a request hold, not a dispatch hold; removed the
   server "dispatch held" tip row, which C10-T04 would have duplicated.
10. Tests: V1 now uses the app's named `ProviderMeterRefresh` (no injection seam
    exists); V3 stores the last block from the snapshot; V5 uses `/build`;
    new V6 for a locked mount; P1 compares named fields instead of a deep-equal
    that the hand-written tips and new fields would break.
11. Sources: design ranges (PSETS ends J:1011, `avg` is J:1013), added cites for
    the hook, the credit window, `dispatch_status/2`, ElevenLabs words and
    `compact_number/1`; the README's `ProviderMetersLive` fixture is now cited
    and reused; added the presenter and zero-fetch suites to the command.

Residual risks: C3-T02 must still accept the §4.6 fields; the V1 check reads
another process's state after a cast, so it may need a short `eventually`
loop; the "of $10.65" credits tip needs a probe change and Kevin's view.
- Reconciliation 2026-10-08 (coordinator): §4.6 prow fields now added to `Payload.validate/1` and the C3-T02 fixture mapper in this PR (R-G1, non-goal, checkbox, handoff), usage gaps and intended differences cited as S-32.
