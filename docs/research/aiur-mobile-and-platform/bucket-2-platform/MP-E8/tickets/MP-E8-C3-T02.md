---
ticket_id: MP-E8-C3-T02
feature_id: MP-E8
chunk_id: MP-E8-C3
bucket: 2-platform
title: Payload schema v1, diff and resync protocol
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T01]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-11, EC-30, EC-09]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C3-T02 — Payload schema v1, diff and resync protocol

> **Wave 0b.** Paths are cited at `58854d4c8`. Paths marked PROPOSED do not exist
> yet. `J` = `design-source/assets/build.js`. This ticket draws nothing. It fixes
> the data contract that every server ticket (C7, C8) produces and every client
> ticket (C9–C11) reads.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C3 (home LiveView,
  data seam, payload protocol, URL state).
- **User value.** The board shows exactly what the server knows, and it stays
  correct across reconnects, missed messages and duplicate messages. An unknown
  value reaches the browser as `null`, never as `0` or a plausible default. A
  ticket title cannot run script in the page.
- **Deliverables.**
  1. PROPOSED `src/lib/aiur_web/build/payload.ex` (`AiurWeb.Build.Payload`): the
     versioned schema (`@version 1`) as code. It builds snapshot, diff and
     page messages, validates them, scrubs strings, and measures bytes.
  2. The protocol in `AiurWeb.BuildLive` (the module C3-T01 creates): an epoch and
     a generation per LiveView process, the `build-resync` and `load-earlier`
     events, and the `{:build_changes, changes}` message (its shape is defined
     here, C8-T04 produces it) that pushes a `build-diff` event, including the
     stale-change filter and the `resync: true` rule.
  3. PROPOSED `src/priv/static/build-home/protocol.js`: two pure functions,
     `decide(state, msg)` (apply, ignore or resync) and `intake(snapshot)`
     (payload → the design's `D` object).
  4. The design-to-payload mapping that C1-T01 shipped raw, rewritten to emit v1,
     plus the five fixtures regenerated and one hostile-text fixture.
  5. A contract test suite (ExUnit, LiveViewTest and a Node round-trip check).
- **Non-goals.**
  - No producer of real data. C8-T04 assembles the real index, C8-T01 now rows,
    C8-T02 usage, C8-T03 daemon state, C7-T01 planned rows.
  - No coalescing of changes into diffs (C8-T04, ≤ 500 ms).
  - No rendering. The hook that applies diffs to the DOM is C9-T01.
  - No handlers for the modal and write events (`open-ticket`,
    `conversation-page`, `send`, `request-unit-control`, `answer-decision`,
    `queue-add`, …). Their tickets (C11) own their names, parameters and reply
    kinds; this ticket fixes only the shared rules they follow (kebab-case,
    reply envelope, write re-check, fallback clause).
  - No schema fields whose producer is a later ticket (see "Extension rule"):
    each owner adds its key to the validator and the fixture mapping in its own
    PR.
  - No websocket compression decision (C12-T06).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6).
- **Predecessor: MP-E8-C3-T01.** It creates `AiurWeb.BuildLive`, the
  `AiurWeb.Build.DataSource` behaviour (`subscribe/1`, `snapshot/1`, called
  through `DataSource.call(source, fun, args)`, which appends the keyword `opts`
  when the source is a `{module, opts}` tuple), the fixture source
  `Aiur.TestSupport.BuildHome.FixtureSource`, the `:build_state` load machine
  (`:loading` → `:ready` | `{:unavailable, tag}`, 15 s timeout) and the
  `:build_snapshot` assign that it keeps "for C3-T02 to decide retention"
  (C3-T01 "Load state machine" and step 2). This ticket changes the behaviour in
  place; it does not add a second seam. The arities are the ones C8-T04 already
  implements (C8-T04 "DataSource callbacks", interface note 2):
  - `subscribe(opts) :: :ok | {:error, term()}` — after it,
    the source sends `{:build_changes, changes}` to the LiveView process;
  - `snapshot(opts) :: {:ok, map()} | {:error, term()}` — the initial window;
  - `earlier(before_ms, time_zone, opts) :: {:ok, map()} | {:error, term()}`
    (new) — history day pages;
  - later, `ticket/2` (C11-T01) and `unit_row/2` (C11-T07, added in its PR).

  `opts` is a keyword list: `time_zone: String.t()` (the socket's zone, `"Etc/UTC"`
  when missing), `financial: {:ok, %FinancialDataAccess.Context{}} | :locked`,
  and for `earlier/3` `days: 1..31` (default 1). BuildLive builds it in one
  private `source_opts/1` (the name C11-T01 already calls). C3-T01's mount call
  `DataSource.call(source, :snapshot, [])` becomes `[source_opts(socket)]`; the
  default module and the fixture source gain the argument and ignore it.
- Transitively after C1-T01 (fixtures, the raw mapping) and C2-T03 (the
  `build-home/` static directory and its loader).
- **Successors that read this contract:** C8-T01, C8-T02, C8-T03, C8-T04, C9-T01
  (row README "Predecessors"). C1-T02's screenshots use the fixtures this ticket
  regenerates. Tickets that extend the schema additively (see "Accepted
  additive fields"): C4-T04, C4-T05, C6-T05, C7-T01..T04, C8-T01, C8-T02,
  C8-T04, C10-T03, C11-T01..T04, C11-T07, C11-T08, C11-T10.
- **May run concurrently with** C3-T03 (URL state; different handlers, same
  LiveView file: merge in either order), all of C4, C5, C6 and C7-T01..T04.
- **Owner questions.** None block this ticket. S-9 (unavailable copy) and S-13
  (unknown model logo) are rendering defaults owned by C9-T13 and C9-T06. The
  schema only carries the states they need.

## Verified starting point (`58854d4c8`)

- **No server-pushed hook data exists today.** `grep push_event` over
  `src/lib` finds no call. Hooks only send events (`pushEvent`), for example
  `src/priv/static/sortable-table-hook.js:182` and
  `src/lib/aiur_web/components/layouts.ex:114,139`. This ticket introduces the
  first server → hook data channel. Event names in the product are kebab-case
  (`load-more-history`, `table-sort-changed`, `send-operator-message` in
  `src/lib/aiur_web/live/dashboard_live.ex`).
- **Libraries.** `mix.lock`: `phoenix_live_view` 1.1.33, `phoenix` 1.8.9,
  `jason` 1.4.5; `config/config.exs:5` sets Jason as the JSON library.
  LiveView 1.1 supports `push_event/3`, `{:reply, map, socket}` from
  `handle_event/3`, and the `pushEvent(event, payload, onReply)` callback; the
  test helpers `assert_push_event/3` and `assert_reply/2` are in
  `Phoenix.LiveViewTest`.
- **Seam pattern.** `src/lib/aiur_web/build_order/data_source.ex:1-138`: a
  read-only behaviour (`@callback` lines 21-36), every dependency injectable
  through `opts` (`dependency/3`, line 128). Its moduledoc (lines 2-13) forbids
  provider or mutation callbacks. C3-T01 copies this for
  `AiurWeb.Build.DataSource`.
- **Socket and reconnect.** `src/lib/aiur_web/endpoint.ex:14-16` mounts
  `/live` with `connect_info: [:user_agent, session: ...]` and no compression
  option. `layouts.ex:272-287` creates the `LiveSocket`, passes the browser's IANA
  `time_zone` in connect params, and sets `window.liveSocket`.
  `dashboard_live.ex:1155-1157` documents the UTC fallback when the zone is
  missing; the reader `browser_time_zone/1` (line 1158) is private, so BuildLive
  copies its four lines into `source_opts/1`. A reconnect starts a new LiveView
  process, so any counter held in assigns starts again from its mount value.
- **Writable and financial gates.** `dashboard_live.ex:140` assigns `:writable`
  from `dashboard_writable?/0` (line 1153, `Endpoint.config(:dashboard_writable)
  == true`); line 499 re-checks it inside the event. `router.ex:139-148` puts every
  dashboard page in `live_session :dashboard, on_mount: AiurWeb.FinancialDataAccess`.
  `financial_data_access.ex:98-111` assigns `:financial_data_capability`
  (`%{state: :authorized}` or `locked_capability/0`, lines 144-153, which is
  "value-free"); `authorize/1` (line 123) revalidates.
- **Ticket identity.** `src/lib/aiur/tracker_identity.ex:267-276`:
  `identifier` is the issue number as a decimal string (`"123"`, no `#`). The
  struct derives `Jason.Encoder` (lines 13-24).
- **UTF-8 precedent.** `src/lib/aiur/agent_event_feed.ex:259-265`
  `AgentEventFeed.scrub/1` checks `String.valid?/1` and **drops** invalid bytes.
  This ticket uses `String.replace_invalid/1` instead (Elixir 1.19.5 per
  `mise.toml`), so a bad byte shows as U+FFFD rather than silently joining two
  words. Jason raises `Jason.EncodeError` on invalid UTF-8, and a raise while
  the reply or push is encoded kills the LiveView process.
- **Browser harness.** `src/browser/tests/support/browser-helpers.mjs:121-126`
  `reconnectLiveView` disconnects and connects through `window.liveSocket`, but
  it waits for `#worker-status[data-live-status]`, an element that exists only
  in the fixture `FixtureLive` page (`fixture_server.exs:377`). It cannot be
  reused on `/build`. `src/test/browser/fixture_server.exs:2263-2264` has
  test-only control routes (`/streamdeck-control/:mode`) and lines 2267-2279 the
  fixture LiveViews. `src/browser/package.json` lists one npm script per spec.
- **The design's data.** `build(kind)` returns
  `{ kind, epics, features, order, all, byId, hist, now, plan, nq, children,
  counts, failedId }` (J:294). The client reads `D.byId` 30 times, `D.features` 17,
  `D.epics` 11, `D.now` and `D.plan` 8 each, `D.hist`/`D.all`/`D.order` 6 each,
  `D.nq` 4, `D.children` 3, `D.counts` 2 and `D.kind` once (a `grep -o` count of
  J). Details that the schema must handle:
  - ids are mock `"AIUR-" + num` (J:190, 254, 260, 273); `deps` hold those ids;
  - an open feature has `to: Infinity` (J:132, `addF(... , Infinity)`), which
    JSON cannot encode; `to` is read only inside `build()` (J:134);
  - `cue.promoted` is a preformatted string `"6m ago"` (J:214, rendered raw at
    J:853); `cue.held` is display text (J:217, rendered through `esc` at J:854);
    `cue.failed` is `{by, blocks[]}` (J:282, rendered at J:858);
  - `cue` exists only on plan rows; `est` only on now and plan rows; `agent` is
    absent on not-queued rows (J:273) and `{model, state: null, effort}` on
    history rows (J:191);
  - `counts` are computed over all rows (J:293) and shown in the epic column
    headers (J:788);
  - history paging is client-only: `histDays()` is built from the loaded
    `D.hist` (J:744), `moreHistory()` compares with its first day (J:745), and
    `initHistFrom()` keeps one day for `D.kind === "dense"`, else two (J:746);
  - usage resets are preformatted strings (`"1h 27m"`, J:991-1012) and an
    unobserved provider is `p.none` (J:1024);
  - the PR number is invented from the ticket number (`200 + num % 300`, J:1310)
    and the repository URL is hard-coded (J:1381).
- **Raw interpolation in the design.** The design escapes titles and labels with
  `esc` (J:9; used at J:788, 830-842, 854, 857, 1080, 1164-1165), but it puts
  these values into HTML or CSS **without** escaping: `t.num`, `t.pct` (J:850),
  `t.qpos`, `t.wave`, `t.pts`, `est` (J:860), `c.wait` and `c.failed.by/blocks`
  (J:855, 858), feature `hue` (J:1086, 1164), `t.agent.effort` (J:1390, inside a
  `title` attribute), and `MODELS[t.agent.model]` (J:828, which throws for an
  unknown model). `esc` handles `& < > "` but not `'`; every design attribute is
  double-quoted, so this is safe today.
- **Measured size** (2026-10-08, `TZ=America/Los_Angeles`, the unmodified `build.js`
  in a Node `vm` with `dataFor` exposed, `JSON.stringify` of the row objects):

  | Dataset | Rows (all) | All rows, bytes | Initial window rows | Window bytes | Window gzip | Meta bytes |
  | --- | --- | --- | --- | --- | --- | --- |
  | live | 332 | 109,211 | 108 (2 days) | 36,100 | 5,163 | 1,342 |
  | dense | 1,384 | 451,089 | 89 (1 day) | 30,010 | 4,215 | 4,502 |
  | newrepo | 64 | 23,278 | 64 | 23,278 | 3,208 | 1,307 |
  | noqueue | 278 | 88,323 | 54 | 15,212 | 2,799 | 1,342 |

  Mean row size is 318–364 B. The densest day in `dense` has 31 history rows.
  "Meta" is `epics + features + order + counts`.

## Chosen design

### Transport (one path for first load, rejoin and gap)

- The hook asks; the server answers. In `mounted()` and `reconnected()` the hook
  calls `pushEvent("build-resync", {}, reply)`. The reply **is** the snapshot.
  The same call repairs a gap. There is no separate "initial push", so the hook
  never races its own `handleEvent` registration.
- Live changes arrive as `push_event(socket, "build-diff", diff)`.
- Older history arrives as the reply to `pushEvent("load-earlier", {before, days})`.
- One LiveView channel carries all three, in order. A reply sent from
  `handle_event` reaches the client before any diff pushed by a later
  `handle_info`. Changes that reach the mailbox while a read runs are handled
  after the reply, with a higher generation; a change already contained in the
  snapshot is an upsert by `id` of the same row, so applying it again changes
  nothing.
- **Reads are bounded.** The reply needs the data inside `handle_event`, so the
  read is synchronous, but it never blocks without limit and never crashes the
  process: `safe_read/1` runs the source call in `Task.async/1` with a
  `try` inside the task, waits with
  `Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)`, and maps a
  timeout, an exit or a raise to `{:error, :timeout | :crashed}`. A real source
  (C8-T04's `GenServer.call`) or the `hold` fixture therefore costs the process at
  most 5 s and gives an `unavailable` error reply.
- **The first reply reuses C3-T01's mount read.** When `:build_state` is
  `:ready` and `:build_generation` is still 0 (no change since the read), the
  `build-resync` reply is built from `:build_snapshot` without a second read.
  Otherwise the handler reads again. While `:build_state` is `:loading` or
  unavailable, it reads too (C3-T01's state machine keeps driving
  `data-build-state`; this ticket does not change it). After the reply, the
  handler stores the new data in `:build_snapshot` (used only by this rule; it
  is not in the template, so it adds nothing to the render diff) and its
  `history` block in `:build_history` (used by the diff window filter).

### Epoch and generation

- On a connected mount, BuildLive assigns `:build_epoch` (12 random bytes,
  URL-safe base64) and `:build_generation = 0`.
- Each accepted `{:build_changes, changes}` increments the generation by
  exactly 1 and pushes one `build-diff` stamped with the epoch and the new
  generation. The two exceptions are below: a stale change is dropped (no
  increment) and `resync: true` adds 2.
- A `build-resync` reply carries the current epoch and generation. It does not
  increment.
- **The change message** (one definition; C8-T04 produces it, the fixture source
  sends it in tests):

  ```elixir
  {:build_changes, %{optional(:index_generation) => pos_integer(), now: ms,
                     upsert: [row], remove: [id], set: %{optional(block) => value},
                     resync: false}}
  {:build_changes, %{optional(:index_generation) => pos_integer(), resync: true}}
  # block ∈ :epics | :features | :order | :counts | :sources | :history_meta
  #       | :daemon | :repo | :usage | :writable
  ```

- **Stale changes:** a snapshot may carry `index_generation` (C8-T04: the Index
  generation it was cut at). BuildLive keeps it in `:build_index_generation`
  (never sent to the browser) and drops, without a push and without an
  increment, every change whose `index_generation` is ≤ it. A change without
  the key (fixture source) is never dropped by this rule.
- **`resync: true`** (the Index restarted, so earlier changes are unknown):
  BuildLive advances the generation by 2 and pushes an empty diff
  (`upsert: [], remove: [], set: {}`). The client sees a gap and asks for a
  fresh snapshot, which the handler reads again because the generation is no
  longer 0. No client change is needed. The fixture route `skip` uses the same
  message, so the gap test needs no test-only code in BuildLive.
- **Why an epoch:** a reconnect creates a new process whose generation starts at
  0 again. Without the epoch the client would read the new process's diff 1 as
  an old duplicate and drop it.

### Client decision rule (`protocol.js` `decide`)

| Client state | Message | Action |
| --- | --- | --- |
| any | `v` ≠ 1 | reload (the hook reloads the page once) |
| any | `kind: "error"` | ignore for the data (the hook shows the reason; C9-T01) |
| no snapshot | `diff` | ignore (the snapshot will contain it) |
| any | `snapshot` with a different epoch, or no snapshot yet | apply; replace everything |
| epoch E, gen g | `snapshot` epoch E, gen ≤ g | ignore (stale reply) |
| epoch E, gen g | `snapshot` epoch E, gen > g | apply; replace everything |
| epoch E, gen g | `diff` epoch E, gen g+1 | apply |
| epoch E, gen g | `diff` epoch E, gen ≤ g | ignore (duplicate or old) |
| epoch E, gen g | `diff` epoch E, gen > g+1 | resync (gap) |
| epoch E | `diff` with another epoch | resync |
| resync in flight | another gap | no second request (single flight) |
| any | `reconnected()` | resync |

`decide` returns one of `"apply" | "ignore" | "resync" | "reload"`. It is a pure
function of `(state, msg)`; the single-flight flag is part of `state`.

### Messages (schema v1)

All times are epoch milliseconds (integers). The browser's time zone formats them
for display; data times come from the daemon (EC-20). **There are no defaults:**
an unknown value is `null`, and a missing required key is a validation error.

**Snapshot** (`build-resync` reply):

```json
{ "v": 1, "kind": "snapshot", "epoch": "q2Vx…", "generation": 17, "now": 1791407600000,
  "writable": true,
  "repo": { "url": "https://github.com/<owner>/<repo>/" },
  "epics":    { "<key>": { "key", "label", "hue", "icon", "general"?, "feature"?, "temp"?, "unsorted"? } },
  "features": { "<key>": { "key", "label", "hue", "epics": ["<epic key>"], "from": ms|null, "to": ms|null } },
  "order":  ["<epic key>"],
  "counts": { "<epic key>": int } | null,
  "sections": { "hist": [row], "now": [row], "plan": [row], "nq": [row] },
  "history":  { "from": ms|null, "more": bool, "total": int|null, "undated": int|null, "tz": str },
  "sources":  { "history"|"features"|"queue"|"agents"|"index": { "state": "ok"|"stale"|"incomplete"|"unavailable"|"disabled", "observed_at": ms|null, "reason": str|null } },
  "usage":  { "state": "authorized", "observed_at": ms|null, "apis": [prow], "providers": [prow] }
          | { "state": "locked", "accessible_name": str, "reason": str, "authentication_path": str }
          | { "state": "unavailable", "observed_at": ms|null, "reason": str },
  "daemon": { "state": "live"|"stale"|"offline"|"unknown", "heartbeat_at": ms|null, "observed_at": ms|null } }
```

- `repo` is `null` when no repository is configured (EC-29). The client then
  shows no GitHub links; it never falls back to the design's URL.
- `counts` are **server totals over the whole index**, not over the loaded rows.
  The client must not recompute them from `sections` (with paged history the
  loaded rows are a subset). When present, every key of `order` has an entry
  (`0` for an empty epic). `counts: null` means "not known" (C8-T04: history
  unavailable or incomplete); the client shows an unknown marker, never 0
  (C9-T04, C10-T02).
- **Referential rules** (validator): every key in `order`, in each
  `features[k].epics` and in `counts`, and every non-null row `epic`, is a key of
  `epics`; every non-null row `feature` and every `also` entry is a key of
  `features`. Otherwise `applyCols` reads `undefined` (J:784; C9-T04 note 2).
- `history.from` is the first loaded day (local midnight in the socket's zone);
  `history.more` says whether an earlier day exists. These replace the design's
  `initHistFrom`/`moreHistory` reasoning over loaded rows. `total` is the number
  of dated history rows in the whole index and `undated` the closed rows with no
  known `end` (both `null` when unknown; C8-T04, C9-T03 note 1). `tz` is the zone
  the server used for day boundaries.
- `features.to: null` means "open" (the one place where `null` is not
  "unknown"; C1-T01 note). `intake()` turns it into `Infinity`.
- `sources` lets C9-T13 tell "empty" from "unavailable" or "disabled" (EC-03,
  EC-07). A missing source key is a validation error, not "ok". Per-source
  failures are reported by the source inside a successful `{:ok, snapshot}`
  (C8-T04 "Parts and their failure states"); a whole `{:error, _}` from
  `snapshot/1` is C3-T01's unavailable page plus an `unavailable` error reply.
- `usage` with `state: "locked"` carries the `locked_capability/0` copy and **no
  values**: no provider rows, no percentages, no money. Hiding them in the
  renderer would still send them to a locked browser.
- `prow` (usage row) follows the design's `PSETS` shape with times instead of
  strings: `{ name, logo | null, mono | null, hue | null, tag | null, accounts:
  [str] | null, session: win | null, weekly: win | null, credits: { pct | null,
  left: str, tip: [[str, str]] } | null, none: bool }`, where `win = { acc:
  [pct | null], reset_at: ms | null, win: str }`. C8-T02 fills it; this ticket
  only validates it.

**Ticket row** (the field names are the design's, so the port changes little):

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | `TrackerIdentity.identifier` (`"123"`), or `"pack:<pack>/<item>"` for an unfiled planning item (C7-T02 widens the id regex in its PR). `#` is display only: `?ticket=#123` would start a URL fragment |
| `num` | int \| null | `null` only for `pack:` rows |
| `title` | string | raw text, never HTML-escaped on the server |
| `type` | `bug` \| `feature` \| `chore` \| `docs` | |
| `epic`, `feature` | key \| null | `epic: null` → the Unsorted column |
| `also` | [feature key] | |
| `cx` | 1..5 \| null | |
| `pts` | int \| null | |
| `sec` | `hist` \| `now` \| `plan` \| `nq` | |
| `ord` | int | sort key inside the section, ascending; ties by `num`. The producer sets it (history: start; plan: queue rank; nq: `num` ascending, C7-T04; now: C8-T01's band order) |
| `start`, `end`, `created` | ms \| null | `end` is a required integer on `hist` rows: day keys and paging need it (C9-T02, C9-T03 requests). A closed ticket with no known `end` is not a `hist` row; it is counted in `history.undated` (C8-T04) |
| `status` | `done` \| `failed` \| `not_planned` \| `closed` \| `running` \| `queued` \| `open` | `not_planned` is S-17; `closed` = closed for any other reason, cause-neutral (duplicates and unknown close reasons; C8-T04), shown as "Closed" |
| `pct` | 0..100 \| null | |
| `agent` | `{ model: str, state: AST key \| null, effort: low\|medium\|high \| null }` \| null | `model` matches `^[a-z0-9][a-z0-9._-]{0,31}$`; any value outside `MODELS` uses the S-13 letter fallback (C9-T06) |
| `est` | number \| null | hours |
| `override` | `{ hours, reason, by, at }` \| null | C7-T03 |
| `added` | bool | |
| `deps` | [id] | ids not in the index are dropped by the producer (EC-21) |
| `wave`, `qpos` | int \| null | on `plan` rows `wave` is an integer ≥ 1 or `null` (the client shows "W?"); `qpos: null` for `pack:` rows |
| `cue` | object on `plan` rows, `null` elsewhere | `{ held: str\|null, promoted: ms\|null, wait: int\|null, waitAny: bool, failed: {by: int, blocks: [int]}\|null, blockedChain: bool }` |
| `pr` | `{ num: int, state: open\|merged\|closed }` \| null | never invented |

**Diff** (`build-diff` push):

```json
{ "v": 1, "kind": "diff", "epoch": "q2Vx…", "generation": 18, "now": 1791407660000,
  "upsert": [row], "remove": ["123"],
  "set": { "counts"?, "epics"?, "features"?, "order"?, "usage"?, "daemon"?, "sources"?, "history"?, "repo"?, "writable"? } }
```

- The server-side change `set.history_meta` (`{total, undated}`) is merged into
  the socket's own `history` block (`from`, `more`, `tz` are per socket) and
  sent as the whole `set.history`.

- A row in `upsert` replaces the row with the same `id` wherever it is. A
  section move (plan → now → hist) is one upsert (EC-10).
- `set` replaces whole top-level blocks. There is no deep merge.
- `now` is the server clock at send time. Between messages the client may
  advance it with a monotonic timer; it never uses the browser's wall clock as
  the data clock.
- History rows older than `history.from` are never sent in a diff (the server
  knows the window because it answers `load-earlier`).

**History page** (`load-earlier` reply):

```json
{ "v": 1, "kind": "earlier", "epoch": "q2Vx…", "generation": 18,
  "rows": [row], "history": { "from": ms, "more": bool, "total": int|null, "undated": int|null, "tz": str } }
```

The client applies it only when the epoch matches, and keeps any row it already
has (a diff is newer than the page). Parameters: `{ "before": ms, "days"?: 1..31 }`;
`before` is the client's current `history.from`, `days` defaults to 1 (C8-T04,
C9-T03). The server returns the latest `days` active days strictly before
`before`, in the socket's connect-param time zone (UTC when it is missing).

**Error reply** (any event): `{ "v": 1, "kind": "error", "reason":
"invalid_params" | "unavailable" | "read_only" | "not_found" }` (`not_found` is
for C11-T01's `open-ticket`).

**Extension rule.** v1 grows only by additive keys; `v` changes only for a
rename, a removal or a meaning change. The validator is strict: an unknown key is
an error, so a typo fails a test instead of reaching the browser. Each additive
key therefore lands in one PR together with its validator clause
(`Payload.validate/1`), its fixture mapping and its producer, in the ticket
that owns it.

**Accepted additive fields (reconciled 2026-10-08).** † = already in this
ticket's v1 validator; the owner produces it.

| Field, state, event or reply kind | Owner |
| --- | --- |
| row `agent.name`; nullable `agent.model`; widened `effort` enum | C8-T01 |
| row `agent.units` (model version in `units.version`) | C11-T10 |
| row `start_src`; nullable `start` | C4-T04 |
| row `children`, `dep_states`, `deps_missing` (then `intake` uses `children` instead of deriving it, J:288) | C4-T05 |
| `features[k].stats` | C6-T05 |
| `features[k].oldest` (server side, in the C8-T04 assembler) | C10-T03 |
| `cue.unknown` | C7-T01 |
| `capacity`, `sources.estimates` | C7-T03 |
| row `src`, `was`; `sources.packs`; pack id `pack:<pack>/<item>` (id regex widened) | C7-T02 |
| `sources.open_tickets`, `truncated`, source state `unsupported` | C7-T04 |
| `sources.features`†, state `incomplete`†, nullable `counts`†, `history.total`/`undated`/`tz`†, status `closed`†, `load-earlier` `days` 1..31† | C8-T04 |
| `prow` `lines`, `icon`, `stale`, `observed_at`, `note`, `hold_until`; nullable `win.win` | C8-T02 |
| `k: "ev"` conversation items | C11-T04 |
| reply kind `ticket`, error `not_found`†, event `close-ticket` | C11-T01 |
| event `conversation-close` | C11-T03 |
| event `open-conversation` | C11-T07 |
| `build-ticket-doc.body_html` (the HTML exception: `Markdown.render` output only) | C11-T02 |
| push `modal:command` | C11-T08 |

The "no HTML in the payload" rule covers the board messages (snapshot, diff,
earlier). A modal reply that carries sanitised HTML, such as C11-T02's
`build-ticket-doc.body_html`, is outside it and is validated by its owner.

### Client → server events (shared rules here; names owned by each ticket)

Kebab-case, as the product's other events are. This ticket handles
`build-resync {}` and `load-earlier {before, days?}`. The other names are the
ones their owners' ticket files already use (2026-10-08): `open-ticket {id}`
and `close-ticket` (C11-T01), `conversation-page {id, before}` and
`conversation-close` (C11-T03), `send {id, text}` (C11-T06; the reply carries
`request_id`, `entry_id`), `open-conversation` and `request-unit-control` for
`pause` and `resume` (C11-T07, not C11-T05; reusing
`dashboard_live.ex:451-458`), `answer-decision` (C11-T08), `queue-add {id}`
(C11-T02). All event names are kebab-case (R-G5). Shared rules for every handler on BuildLive:

- every event name has a guarded clause and a fallback clause after it (as
  `dashboard_live.ex:498-509` does for `open-add-agent`), and the fallback of an
  event the hook sends with a reply callback replies `invalid_params`;
- every write handler re-checks `socket.assigns.writable and
  dashboard_writable?()` inside the event, as `dashboard_live.ex:499` does, and
  replies `read_only` when it fails;
- every reply has `v: 1` and a `kind`.

### Escaping and string safety (EC-30)

1. **Server:** strings are data. The payload never contains HTML and is never
   HTML-escaped (a title `A & B` must render `A & B`, not `A &amp; B`). Every
   string is scrubbed to valid UTF-8 before encoding, so a bad title cannot crash
   the LiveView inside `push_event`.
2. **Types close the raw-interpolation holes.** The validator requires numbers for
   every field the design puts into HTML or CSS unescaped (`num`, `pct`, `qpos`,
   `wave`, `pts`, `est`, `wait`, `failed.*`, `hue`, `override.hours`) and enums for
   `effort`, `state`, `type`, `sec`, `status`, `pr.state` and epic `icon` (one of
   `bug pen server docs layers unsorted`, the keys of `I` that epics use).
3. **Client:** every string goes through `esc` before `innerHTML` or an attribute.
   `esc` gains `'` → `&#39;`. This changes no pixel and closes the one gap a future
   single-quoted attribute would open.

### Size budget (EC-09)

- The initial window is the queue, the band, the not-queued rows and the last two
  active history days (one for dense), as C8-T04 defines. The 64 KB budget below
  excludes the not-queued section; C12-T06 owns a separate 160 KB budget for
  300 not-queued rows.
- **Budget, from the measurement above:** the `live` and `dense` v1 snapshots
  must each be ≤ 64 KB of JSON (measured design rows: 37.4 KB and 34.5 KB
  including meta; the margin covers `ord`, `pr`, `sources`, `usage` and longer
  real titles). The mean row over all five fixtures must be ≤ 400 B.
- At runtime, `Payload.bytes/1` is measured on every snapshot. Over 512 KB, the
  server logs one warning with the byte count and the row count per section, and
  still sends the whole snapshot (no truncation, no silent data loss). C12-T06
  measures the 10,000-ticket case and decides on compression.

## Implementation steps

1. **`AiurWeb.Build.Payload`** (PROPOSED `src/lib/aiur_web/build/payload.ex`):
   - `@version 1`; `snapshot(data, epoch, generation)`, `diff(changes, epoch,
     generation, history)`, `earlier(page, epoch, generation)`, `error(reason)`.
     `snapshot/3` drops the source-only `index_generation` key.
   - `row(map)`: fetches every required key with `Map.fetch/2` and returns
     `{:error, {:missing, key}}`; it never uses `Map.get(row, key, default)`.
   - `validate(message) :: :ok | {:error, [{path, reason}]}`: closed key sets
     (unknown key = error), types, enums, section rules (`cue` only on `plan`,
     integer `end` on `hist`, `wave` ≥ 1 or `null` on `plan`), id format (`^[1-9][0-9]*$`
     or `^pack:[a-z0-9][a-z0-9-]{0,63}$`, which C7-T02 widens to `pack:<pack>/<item>`), `deps` ids are strings, every
     `sources` key present, the referential rules, `counts` complete or `null`,
     and a locked `usage` that carries no value keys.
   - `scrub/1`: walks the message and replaces invalid UTF-8
     (`String.replace_invalid/1`).
   - `bytes/1`: `IO.iodata_length(Jason.encode_to_iodata!(message))`.
   - The moduledoc is the schema text above; the tables live there, not in a
     second file.
2. **DataSource arities** (C3-T01's `src/lib/aiur_web/build/data_source.ex`):
   `@callback subscribe(keyword())`, `@callback snapshot(keyword())`, new
   `@callback earlier(integer(), String.t(), keyword())`; the default module
   answers `{:error, :not_wired}` for `earlier/3` too. Update C3-T01's fixture
   source and its tests to the new arities in the same PR.
3. **BuildLive protocol** (C3-T01's `src/lib/aiur_web/live/build_live.ex`):
   - connected mount: assign `:build_epoch`
     (`:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)`),
     `:build_generation` 0, `:build_index_generation` `nil`,
     `:build_history` `nil`, `:writable` (`dashboard_writable?()`, a copy of the
     one-line `dashboard_live.ex:1153` check, unless C3-T01 already assigns it) and
     `:build_source` (the `DataSource.source()` value C3-T01 computes). C3-T01
     already calls `subscribe` **before** the first `snapshot` read; keep that
     order and pass `[source_opts(socket)]` to both. In C3-T01's
     `handle_async(:build_snapshot, {:ok, {:ok, data}}, …)` branch, also store
     `:build_index_generation` and `:build_history` from `data`, so the
     stale-change filter and the window filter work before the first resync.
   - `source_opts/1`: `[time_zone: zone, financial: financial]`, where `zone` is
     the `browser_time_zone/1` logic and `financial` is
     `{:ok, ctx}` when `ctx = FinancialDataAccess.context(socket)` passes
     `FinancialDataAccess.authorize(ctx)`, else `:locked`. Called on every
     resync, so a revoked access takes effect at the next resync.
   - `handle_event("build-resync", _params, socket)`: the "first reply reuses the
     mount read" rule, else `safe_read(fn -> DataSource.call(source, :snapshot,
     [source_opts(socket)]) end)`. On `{:ok, data}`: store `:build_snapshot`,
     `:build_index_generation` (from `data["index_generation"]`, if present) and
     `:build_history`; reply `Payload.snapshot(data, epoch, generation)`. On
     `{:error, _}`: reply `Payload.error(:unavailable)`. If the encoded snapshot
     fails `Payload.validate/1`, log one warning with the paths (never the
     values) and reply `unavailable`; never send invalid data.
   - `handle_event("load-earlier", %{"before" => b} = p, socket)` when `b` is an
     integer with `0 < b ≤ now + 86_400_000` and `p["days"]` is absent or an
     integer in 1..31: `safe_read` of `earlier/3` → reply `Payload.earlier/3`;
     set `:build_history` to the page's block. Fallback clause: `invalid_params`.
   - `handle_info({:build_changes, changes}, socket)`, in this order:
     1. `resync: true` → generation + 2, push the empty diff;
     2. `index_generation ≤ :build_index_generation` → drop (no push, no
        increment);
     3. remove `hist` upserts whose `end` is before `:build_history`'s `from`;
     4. if the socket is locked, delete `set.usage` (defence; C8-T04 never
        broadcasts usage);
     5. merge `set.history_meta` into `:build_history`;
     6. generation + 1, `push_event(socket, "build-diff", Payload.diff(...))`.
     Before the first snapshot (`:build_history` is `nil`) the same rules run and
     the diff is pushed; the client ignores it (decision table).
   - `safe_read/1`: `Task.async(fn -> try do fun.() rescue _ -> {:error,
     :crashed} catch _, _ -> {:error, :crashed} end end)`, then
     `Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)`. The `try`
     sits **inside** the task: `Task.async` links the task to the LiveView, so an
     uncaught raise in the task would kill the LiveView even though `yield` is
     used. `nil` → `{:error, :timeout}`; a result that is neither `{:ok, map}`
     nor `{:error, _}` → `{:error, :invalid}`.
4. **Fixture source** (`Aiur.TestSupport.BuildHome.FixtureSource`): `snapshot/1`
   serves the window of the selected dataset (the two last active days; one for
   `dense`, J:746) with the `history` block; `earlier/3` serves day pages from the
   same JSON; `subscribe/1` subscribes the caller to the PubSub topic
   `"build-home:fixture"`. Fixed `now` (2026-10-07 14:20 America/Los_Angeles,
   J:11). Its `hold` and `unavailable` datasets keep C3-T01's meaning.
5. **Mapping and fixtures:** rewrite the body of C1-T01's
   `mapRawToPayload(dataset)` in `src/browser/scripts/build-home-fixture-map.mjs`
   (C1-T01 "Mapping") to emit v1, and bump the manifest `schema`:
   - `id = String(num)`, with `deps` mapped the same way;
   - `cue.promoted "6m ago"` → `NOW − 6 min`;
   - `to: Infinity` (exported as `"Infinity"`) → `null`;
   - `agent` absent → `null`; `cue` absent → `null`; `est` absent → `null`;
   - `ord` from the design's array position;
   - `pr: null`, `repo.url` set to a fixture repository
     (`https://github.com/example/aiur-fixture/`);
   - `counts` from the design (J:293) plus `0` for every other `order` key;
   - `history.total = D.hist.length`, `undated: 0`, `tz: "America/Los_Angeles"`;
   - `sources` all `ok` with `observed_at = NOW`;
   - `usage` from `PSETS[4]`, with each reset string turned into `NOW + duration`;
   - `daemon` live, except `offline`, which follows C1-T01's rule; a raw
     `cached_at` is dropped;
   - an `ids` map {design id -> payload id} is written into the manifest
     (C1-T02 and C1-T03 read it).
   Regenerate the five fixtures (`live`, `dense`, `newrepo`, `noqueue`,
   `offline`) under PROPOSED `src/test/fixtures/build_home/`.
   Add `hostile.json`, the `live` fixture with these values injected:
   - a title `<img src=x onerror="window.__xss=1">'"&`;
   - an epic label and a feature label `<b>x</b>`;
   - a `cue.held` and an `override.reason` `" onmouseover="window.__xss=1`;
   - one title with invalid UTF-8 bytes, kept as a base64 field that the Elixir
     test decodes.
6. **`protocol.js`** (PROPOSED `src/priv/static/build-home/protocol.js`, an ES
   module inside the `build-home/` directory C2-T03 registers): `decide(state,
   msg)` per the table and `intake(snapshot)` → `{epics, features, order, counts,
   hist, now, plan, nq, all, byId, children}` (sorted by `ord`, then `num`;
   `to: null` → `Infinity`; `children` derived from `deps` as J:288 does, until
   C4-T05 sends it). C9-T01 calls both; it may move the file inside its module
   layout but keeps the two exports.
7. **Fixture server:** PROPOSED `get("/build-control/:action", …)` next to
   `/streamdeck-control/:mode` (`fixture_server.exs:2264`), a small plug
   modelled on `FixtureStreamdeckControl` (`fixture_server.exs:1571`). Like the
   `"streamdeck:fixture"` broadcast at line 1092, it broadcasts on
   `"build-home:fixture"`: `diff` sends one `{:build_changes, …}` that upserts
   the first `plan` row with `pct + 1` (later tickets add `?name=<file>`);
   `skip` sends `{:build_changes, %{resync: true}}`, which makes BuildLive skip
   one generation. Unknown actions answer 404.
8. **Tests and script:** a `node --test` file
   `src/browser/scripts/build-home-protocol.test.mjs` for `decide` and the round
   trip, and the npm script
   `"test:build-home-protocol": "TZ=America/Los_Angeles node --test scripts/build-home-protocol.test.mjs"`,
   added to the `test` chain in `src/browser/package.json`.

## Non-happy paths

- **Reconnect** (EC-11): a new process sends a new epoch, and the hook resyncs on
  `reconnected()`. Diffs pushed while the socket was down are lost by design; the
  resync replaces them.
- **Gap, duplicate, late:** handled by `decide`: a duplicate diff never applies
  twice. A change that is already inside a snapshot can still arrive as the
  next diff (it was in the mailbox during the read); it is an upsert or remove by
  `id`, so applying it again leaves the same rows.
- **Slow or hung source:** `safe_read/1` gives up after 5 s and replies
  `unavailable`; the process stays alive and handles the next event. A raise or
  exit inside the source is the same reply. C3-T01's own 15 s mount timeout still
  sets `data-build-state="unavailable"`.
- **Stale change after a snapshot** (C8-T04 D6): dropped by the
  `index_generation` rule, with no push and no increment.
- **Index restart** (`resync: true`): generation + 2 and an empty diff; the
  client's gap resync reads the new Index.
- **Resync while a resync is in flight:** single flight. If the reply never comes
  (the socket drops), `reconnected()` starts a fresh one.
- **Source failure:** a part failure is a `sources` entry with `unavailable` and
  a reason, inside a valid snapshot; sections from other sources still render. A
  whole `{:error, _}` is an `unavailable` error reply. The process does not
  crash in either case.
- **Invalid data from a source:** the snapshot fails `Payload.validate/1`, the
  server logs the paths (not the values) and replies `unavailable`. Invalid data
  never reaches the browser.
- **Invalid UTF-8 or oversized strings:** scrubbed; no crash. This ticket does
  not truncate titles (GitHub caps issue titles at 256 characters); a real cap
  belongs to the producer if one is ever needed.
- **Locked financial data:** no usage values in the payload. `source_opts/1`
  re-runs `FinancialDataAccess.authorize/1` on every read, so a configuration
  change that revokes access takes effect at the next resync; a `set.usage` in a
  change is deleted for a locked socket. Granting access takes effect on the next
  read too (the source then returns the authorized block; C8-T02 owns the usage
  subscription).
- **Read-only dashboard:** `writable: false` in the snapshot. The client hides or
  disables writes (C11). The server still rejects each write (`read_only`).
- **Malformed client parameters:** an `invalid_params` reply, no state change, no
  crash. Each event name has a fallback clause after its guarded clause (as
  `dashboard_live.ex:509` does for `open-add-agent`), so bad parameters never raise a
  `FunctionClauseError` that would restart the process.
- **History window after a resync:** the snapshot carries the initial window
  again, so a client that had loaded earlier days loses them and pages again
  (replace everything is the rule; C9-T03 keeps its anchor).
- **Dead render** (not connected): no payload. The C3-T01 skeleton shows (EC-01).
- **Two tabs:** two processes, two epochs; no shared state.

## Compatibility and rollout

- No configuration key, CLI flag or environment variable. No user-facing docs
  (AGENTS.md "Docs ship with the change": internal contract only). The schema is
  documented in the `Payload` moduledoc.
- The route stays the temporary `/build` from C3-T01 until cutover (C12-T01).
- **Versioning:** `v` is checked by `decide`. A message with `v ≠ 1` returns
  `reload`, and the hook reloads the page once instead of misreading the data.
  Additive keys do not bump `v` (see "Extension rule"). A breaking change bumps `v` and ships
  with the hook in the same release (the hook is a hand-served file from the same
  release, so a mismatch only happens on a tab open across a daemon upgrade).
- The DataSource arity change touches only C3-T01's default module, its fixture
  source and its tests; no product caller exists yet.
- Rollback: remove the route; nothing persists.

## Pixel parity

This ticket renders no pixel. It carries the data that the C1-T02 side-by-side
screenshots compare, so data parity is its parity check:

- **Design element:** the `build()` return object (J:294) and the fields listed in
  "Verified starting point".
- **Check 1 (round trip, Node):** for each of `live`, `dense`, `newrepo` and
  `noqueue`, `intake(mapRawToPayload(<kind>.json))`, with all `earlier` pages merged,
  deep-equals `build(kind)` except this allowlist: `id`/`deps` (`AIUR-N` →
  `"N"`), `cue.promoted` (string → ms), `kind`, `failedId` and `_days` (not sent),
  and the new fields `ord`, `pr`, `sources`, `usage`, `daemon`, `repo`, `history`,
  `writable`, `epoch`, `generation`. `counts` must be equal for every key the
  design has and `0` for the added keys. Any other difference fails.
- **Check 2:** C1-T02 renders the design with `?example=<kind>` and the product
  with `GET /build-fixture/<kind>` then `/build` (C3-T01 handoff), with the same
  fixture. A data mistake here shows up there as a
  screenshot difference. This ticket does not own those screenshots.

## Verification

ExUnit (PROPOSED `src/test/aiur_web/build/payload_test.exs` and
`src/test/aiur_web/live/build_live_protocol_test.exs`):

| Test | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| fixtures validate | each of the 5 fixture snapshots and `hostile.json` | `Payload.validate/1` → `:ok` | — (guard; it proves the fixtures reach the rules below) |
| validator rejects | one case per rule: `pct: "50"`, `effort: "<b>"`, `hue: "1);x"`, `cue` on an `nq` row, `sec: "x"`, `end: nil` on a `hist` row, `wave: 0` on a `plan` row, an `order` key missing from `epics`, an `order` key missing from `counts`, a `sources` key missing, an unknown row key `colour`, a locked `usage` with `providers` | `{:error, [{path, reason}]}` naming that path, one test per rule | delete that rule's clause (each case fails alone); replacing the body with `:ok` fails all |
| no default for unknown | `row/1` on a row map without `:pct` | `{:error, {:missing, :pct}}` | `Map.get(row, :pct, 0)` |
| unknown stays null | row with `pct: nil, est: nil, start: nil`; snapshot with `counts: nil` | JSON has `"pct":null`, `"est":null`, `"start":null`, `"counts":null` | a `\|\| 0` (or `\|\| %{}`) fallback |
| locked usage is value-free | snapshot built with `financial: :locked` | `usage` keys are exactly `accessible_name`, `authentication_path`, `reason`, `state`; `state == "locked"`; the values equal `locked_capability/0`'s | always emitting the authorized block |
| invalid UTF-8 | the hostile fixture's invalid title | `Jason.encode!/1` succeeds; the title contains U+FFFD and the valid characters on both sides | remove `scrub/1` (Jason raises); drop instead of replace (no U+FFFD) |
| raw strings | title `A & B` | JSON value `"A & B"` | any HTML escape in the server |
| budget | `live`, `dense` snapshots | `bytes/1` ≤ 65,536; mean row ≤ 400 B over all 5 | — (regression guard for EC-09; says so in its name) |
| resync reply | `render_async(view)`, then `render_hook(view, "build-resync", %{})` | `assert_reply` with `v: 1`, `kind: "snapshot"`, the mount epoch, `generation: 0`, and the `live` row count | the handler |
| first reply reuses the read | counting fixture source (`snapshot/1` sends `:read` to the test) | after mount + one resync, exactly one `:read`; after a change + resync, two | always reading (the count is 2 on the first) |
| bounded read | dataset `hold`, then `render_hook(view, "build-resync", %{})` | reply `%{kind: "error", reason: "unavailable"}` within 6 s; `Process.alive?(view.pid)` | a bare `DataSource.call` (the test times out) |
| source raises | a source whose `snapshot/1` raises | reply `unavailable`; view alive | no `safe_read` (the view dies) |
| whole-source error | dataset `unavailable` | reply `%{kind: "error", reason: "unavailable"}`; view alive | replying `{kind: "snapshot"}` with empty sections |
| part failure passes through | `live` with `sources.queue = {state: "unavailable", reason: "queue_down"}` and `plan: []` | reply `sources.queue.state == "unavailable"`, reason kept | `Payload.snapshot/3` normalising states to `"ok"` |
| invalid source data | `live` with one row `pct: "50"` | reply `unavailable`; log names the path, not `"50"` | sending the snapshot unvalidated |
| diff stamping | broadcast two `{:build_changes, …}` on `"build-home:fixture"` | `assert_push_event "build-diff"` twice, generations 1 then 2, same epoch | the increment |
| stale change | snapshot with `index_generation: 6`; change with 5, then 7 | one push only, for 7, generation 1 | the `index_generation` rule |
| index restart | `{:build_changes, %{resync: true}}` at generation 3 | push `build-diff` with generation 5 and empty `upsert`, `remove`, `set` | the `resync` clause (generation 4) |
| locked socket drops usage | locked socket; change with `set.usage` and one upsert | pushed diff has no `usage` key, still has the upsert | step 3.4 |
| epoch per process | mount twice | different epochs | a constant epoch |
| load-earlier valid | `%{"before" => from}`, then `%{"before" => from2, "days" => 2}` on `live` | first reply: rows all from the previous active day; `history.from` moves back one day; second reply: two days | the handler; ignoring `days` |
| load-earlier invalid | `%{"before" => "x"}`, `-1`, `now + 2 days`, `"days" => 0`, `"days" => 32`, `%{}` | `%{kind: "error", reason: "invalid_params"}`; view still alive | the guard; the fallback clause (`%{}` crashes the view) |
| window for diffs | after load-earlier, a change to a `hist` row whose `end` is older than the new `from` | not pushed; a change to a newer row is pushed | the window filter |

Node (PROPOSED `src/browser/scripts/build-home-protocol.test.mjs`, `node --test`):

- **`decide` table:** one case per row of the decision table, including
  `v: 2` → `reload` and the single-flight row. Mutations: return `apply` for
  `gen ≤ g` → the duplicate case fails; drop the epoch comparison → the
  "another epoch" case fails; drop the in-flight check → the single-flight case
  fails; drop the `v` check → the reload case fails.
- **Round trip:** "Pixel parity" check 1. Mutation: drop the `to: null` →
  `Infinity` step, or the `ord` sort → the case fails.
- **Hostile text:** `intake(hostile.json)` plus the ported `esc` (with `'`): the
  escaped strings equal the expected entity strings (`&lt;img src=x
  onerror=&quot;window.__xss=1&quot;&gt;&#39;&quot;&amp;`). Mutation: the design's
  `esc` without `'` → the case fails. C9-T05 adds the DOM assertions
  (`window.__xss` undefined, no `img[src="x"]`, literal title text). This is a
  recorded handoff, not a silent skip.

End-to-end reconnect and gap tests need the hook, which arrives in C9-T01. They
are C9-T01's B5 (gap, using this ticket's `/build-control/skip` and `diff`) and
B7 (reconnect, a new `data-build-epoch`). They call `window.liveSocket.disconnect()`
and `connect()` directly, because `reconnectLiveView` waits for
`#worker-status`, which `/build` does not render. This ticket proves the server
side of EC-11 with the "epoch per process", "resync reply", "index restart" and
"diff stamping" tests, and the client side with the `decide` table.

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/build/payload_test.exs test/aiur_web/live/build_live_protocol_test.exs
env -C src/browser npm run test:build-home-protocol
env -C src/browser npm run check:build-home-fixtures   # C1-T01's check, after regenerating
```

Mutation check (AGENTS.md): for each row above with a mutation, apply it in a
worktree, confirm `git status --porcelain` shows only that hunk, run the test,
see it fail, restore, see it pass. Record the exact commands in the PR body.

## Completion and handoff

- [ ] `AiurWeb.Build.Payload` with the v1 schema in its moduledoc; the
      validator, scrub and bytes functions.
- [ ] BuildLive: epoch, generation, `build-resync` (bounded read, first reply
      reuses the mount read), `load-earlier` (with `days`),
      `{:build_changes, _}` → `build-diff` with the stale-change filter, the
      `resync: true` rule and the history window; financial and writable gates
      as specified; `source_opts/1`.
- [ ] DataSource arities `subscribe/1`, `snapshot/1`, `earlier/3`; C3-T01's
      default module, fixture source and tests updated.
- [ ] `mapRawToPayload` rewritten; five fixtures regenerated; `hostile.json`
      added; `/build-control/:action` (`diff`, `skip`) in the fixture server.
- [ ] `protocol.js` with `decide` and `intake`.
- [ ] The ExUnit and Node tests pass, and every mutation listed makes its test
      fail.
- [ ] The measured snapshot bytes for `live` and `dense` are in the PR body.
- **Dependents:** C8-T01, C8-T02, C8-T03 and C8-T04 produce v1 rows and blocks.
  C9-T01 consumes `decide`/`intake` and owns the end-to-end gap (B5) and
  reconnect (B7) tests. C9-T05 adds the hostile-text DOM assertions. The owners
  in the "Accepted additive fields" table add their keys. C12-T06 re-measures with 10,000
  tickets.
- **Interface notes for neighbour tickets:**
  1. **C3-T01** handoff "send it with `push_event`" is replaced by the
     `build-resync` reply (C2-T03 note 3: the hook's listeners exist only after
     its module loads). C3-T01's `data-build-state` machine is unchanged.
  2. **C11-T01** reads `socket.assigns.epoch`, `.generation` and `.source`. The
     assigns are `:build_epoch`, `:build_generation` and `:build_source`.
     `source_opts/1` exists with the name it calls.
  3. **C8-T04** lists the stale-change filter, the restart resync and `days`
     under its own BuildLive checklist. This ticket implements all three with
     the fixture source; C8-T04 only tests them against `IndexSource` (D6, D8).
     Its `opts[:financial]` is `{:ok, %FinancialDataAccess.Context{}} | :locked`,
     the form both its `subscribe/1` text and its F1 test need.
  4. **Event names.** Settled 2026-10-08: kebab-case everywhere (R-G5);
     `pause`/`resume` are C11-T07's (decision 1).
  5. **C3-T03** note 2 (id form): settled. `id` is the bare number string, so
     `?ticket=2748` and `open-ticket {id: "2748"}` use the same value.
- **Sources:** `tickets/README.md` row C3-T02, `chunks.md` C3, `plan.md` §5, §8
  (EC-09, EC-10, EC-11, EC-30), §9 (K-8); J lines cited above; the code paths
  cited in "Verified starting point".

## Decisions made without the owner

1. **Kebab-case event names** (`build-resync`, `load-earlier`, and the C11
   tickets' `open-ticket`, `conversation-page`, `queue-add`, `send`,
   `request-unit-control`, `answer-decision`) instead of the row's snake_case, to
   match every existing `handle_event` in `dashboard_live.ex`. The neighbour
   ticket files already use these spellings; only the README rows differ.
2. **Pull, not push, for snapshots:** the hook requests the snapshot in
   `mounted()`/`reconnected()`. One code path covers first load, rejoin and gap.
3. **An epoch next to the generation**, because a reconnect resets the
   generation counter.
4. **`id` is the decimal identifier (`"123"`), not `"#123"`.** The `#` is added at
   render. It keeps `?ticket=123` (C3-T03) free of URL-fragment problems.
   Unfiled pack items use a `pack:` prefix.
5. **`cue.promoted` is a timestamp,** not the design's text. The client renders
   the age (AGENTS.md "a computed age is rendered").
6. **`counts` and `history.more` come from the server,** because paged history
   makes counts over the loaded rows wrong.
7. **Locked usage carries no values in the payload,** not only none on screen.
8. **`esc` also escapes `'`.** No visual change.
9. **Budget 64 KB per fixture snapshot and a 512 KB runtime warning,** set from
   the 2026-10-08 measurement. C12-T06 may tighten them.
10. **No JSON Schema file or library.** The validator is Elixir code with its
    schema in the moduledoc (ponytail: one source, no new dependency).
11. **A bounded synchronous read, not a deferred reply.** The `build-resync`
    reply must carry the snapshot (C2-T03 note 3, C9-T01), and LiveView 1.1 has
    no deferred reply from `handle_event`. So the read is synchronous, bounded to
    5 s by `safe_read/1`, and maps every failure to `unavailable`. Rejected:
    holding a server-side copy of the window and applying every change to it
    (more code, a second diff applier to keep equal to the client's).
12. **The first reply reuses C3-T01's mount read** while no change has arrived,
    so a normal page load reads the source once.
13. **This ticket implements C8-T04's `index_generation` filter and
    `resync: true` rule** in BuildLive, because they are protocol rules on the
    message this ticket defines. C8-T04 keeps the producer side and its tests.
14. **Schema requests from neighbours:** the validation rules and enum values
    that need no new producer (`end` on `hist`, `wave` ≥ 1 or `null`, complete or `null`
    `counts`, referential checks, `status: closed`, `sources.features`,
    `incomplete`, `history.total/undated/tz`, `days`, `not_found`) are in v1
    now. New fields with their own producer follow the "Extension rule" and land
    with their owner.
15. **Strict validator** (unknown keys are errors), so a misspelt key fails a
    test instead of shipping; the cost is that each additive key needs its
    validator clause in the same PR.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the design source and the
neighbour ticket files.

1. Fixed the DataSource contract: C3-T01 defines `subscribe/0`/`snapshot/0`
   through `DataSource.call/3`; this ticket now states the change to the
   C8-T04 arities, the `opts` keys and `source_opts/1`.
2. Fixed a feasibility gap: the synchronous `build-resync` read could block or
   crash the LiveView (C3-T01's `hold` fixture, a `GenServer.call` timeout).
   Added `safe_read/1` with the `try` inside the linked task, and reuse of the
   mount read.
3. Added the `{:build_changes, …}` shape, the `index_generation` stale filter and
   the `resync: true` rule that C8-T04 relies on; `skip` now uses that message
   instead of an unexplained server-side generation jump.
4. Added the neighbour schema requests that need no new producer (C8-T04,
   C9-T02, C9-T03, C9-T04, C11-T01) and an "Extension rule" table for the rest
   (C4-T04, C4-T05, C6-T05, C7-T01, C7-T03, C8-T01, C8-T02, C11-T03, C11-T10);
   scoped the "no HTML" rule to board messages (C11-T02 note 3).
5. Corrected event names to the neighbours' ticket files (`request-unit-control`
   in C11-T07, not `pause`/`resume` in C11-T05; `answer-decision` in C11-T08)
   and rewrote the garbled decision 1.
6. Removed the end-to-end reconnect and gap browser tests: the hook that writes
   `data-build-epoch` is C9-T01's, and `reconnectLiveView` waits for
   `#worker-status` (`fixture_server.exs:377` only). They are C9-T01 B5/B7; the
   Node `decide` tests stay here.
7. Replaced vacuous or unreachable tests: the "source failure" test (the fixture
   source returns one result, not per-queue errors), the locked-usage test (a
   `%`/`$` scan over the whole snapshot would hit titles), and the single
   "validator body = `:ok`" mutation (now one mutation per rule). Added tests
   for the bounded read, a raising source, invalid source data, stale changes,
   the restart rule, `days`, the fallback clause and the first-read reuse.
8. Fixed citations: `p.none` is J:1024; `AgentEventFeed.scrub/1` drops bytes
   (lines 259-265) rather than replacing them; `browser_time_zone/1` is private;
   C1-T01's mapping is `mapRawToPayload` in
   `src/browser/scripts/build-home-fixture-map.mjs`; the fixture route is
   `/build-fixture/<dataset>`, not `?fixture=`.
9. Added the missing decision-table rows (`v` ≠ 1, error replies), the
   `:writable` assign, the `set.history_meta` merge and `repo` in `set`, and the
   history-window reset after a resync.
- Reconciliation 2026-10-08 (coordinator): "Accepted additive fields (reconciled 2026-10-08)" table with owner per field replaces the extension table, DataSource arities `/1` (no `/0`; `call` appends opts; `ticket/2`, `unit_row/2` later), pack id `pack:<pack>/<item>` (C7-T02 widens the regex), nq sort `num` ascending, plan `wave: null` allowed ("W?"), `closed` cause-neutral "Closed", 64 KB budget excludes not-queued (C12-T06 160 KB), event list kebab-case with `close-ticket`, `conversation-close`, `open-conversation`, `send {id, text}` and pause/resume as C11-T07's, mapper writes the manifest `ids` map and drops raw `cached_at`, interface note 4 settled.
