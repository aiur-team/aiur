---
ticket_id: MP-E8-C3-T03
feature_id: MP-E8
chunk_id: MP-E8-C3
bucket: 2-platform
title: Server-owned URL state and legacy URL presets
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-26, EC-17]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C3-T03 — Server-owned URL state and legacy URL presets

Abbreviations: `J` = `../design-source/assets/build.js`. Product paths are
relative to `src/` at `58854d4c8`. PROPOSED marks a path that does not exist yet.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C3 (home
  LiveView, data seam, payload protocol, URL state).
- **User value:** a copied or bookmarked home-page link opens the same view,
  span, feature focus, filters and ticket modal for every reader. A bad link
  cannot put the page in a state the UI cannot show. Old Units links
  (`/?v=1&scope=…&conditions=…`) still land on a sensible filtered view after
  the cutover.
- **Deliverable:**
  1. PROPOSED `AiurWeb.Build.URLState`, a pure module that parses, validates,
     and serializes every design URL parameter, and maps legacy Units
     parameters to filter presets.
  2. `AiurWeb.BuildLive.handle_params/3` (the LiveView from C3-T01) parses the
     URL into one `:url_state` assign. It canonicalizes the address bar with
     `push_patch(replace: true)` when the URL is not canonical.
  3. The bridge contract with the hook: a `"build:url"` client event (the
     replacement for the design's `history.replaceState`, J:327) and a
     `"build:url"` server push for back, forward and server-side changes.
- **Non-goals:**
  - The hook code that calls the bridge. That is C9-T01. This ticket defines the
    contract and tests the server side with `render_hook/3`.
  - Opening the modal from `?ticket=`, fetching an id outside the loaded window,
    and the not-found state (S-10). That is C11-T01. This ticket only validates
    the parameter.
  - Routing `/` to `BuildLive`. That is C12-T01. Build Order route redirects
    (`/build-orders/:n` → `/?feature=<slug>`) are C12-T02.
  - What a filter does to the page (dim or relayout). That is C10-T02.
  - The demo parameters `example` and `models` (plan §10 item 5).

## Dependencies and blockers

- **Blocked by DESIGN-E8.** No S-item applies to this ticket. PQ-10's
  recommendation ("the old `?scope=` URLs redirect to filter presets",
  `../questions.md` §8 item 10) is the default followed here.
- **Predecessor: MP-E8-C3-T01.** It creates `AiurWeb.BuildLive` at the temporary
  route `/build` inside `live_session :dashboard`, and the `#build-root`
  container (`phx-update="ignore"`). This ticket adds `handle_params/3`, one
  `handle_event/3` clause, and one attribute on `#build-root`.
- **Successors:** C9-T01 (the hook calls the bridge), C10-T02 (filters write the
  URL through the bridge), C11-T01 (`?ticket=` deep link and close), and C12-T01
  (the cutover makes the legacy mapping live on `/`).
- **Runs concurrently with** C3-T02. The two tickets touch different functions
  in `build_live.ex`. Merge order does not matter, but the second one rebases.
- **Seam scan (C3-T01).** This module reads
  `AiurWeb.OperatorControlCenter.UnitsURL` (legacy decode). It is not on the
  C3-T01 allow-list as written. This ticket adds that one entry in the same PR
  (R-G3; see "Interface notes"). The model rule is a key pattern, so this
  module does not read `Aiur.CodingAgent`.

## Verified starting point (`58854d4c8`)

**The design (reference, do not edit).**
- `J:300` `FKEYS = ["epic", "feature", "model", "tstate", "astate"]`.
  `J:302` `SPANS = [1, 2, 3, 5, 7, 10, 14, 21, 30]`. `J:303` the defaults:
  `view: "graph"`, `span: 1`, `feature: null`, `fmode: "focus"`,
  `trees: false`, `liveMin: false`.
- `J:304-315` `readURL`: accepts `view` only in `gantt|list`; `trees` only `1`;
  `live` only `min`; `span` only when `+value` is in `SPANS`; `feature` any
  non-empty string; `fmode` only `compact`; each of `epic`, `model`,
  `tstate`, `astate` as `value.split(",")` with **no value check** (empty items
  kept); `models` and `example` (demo only). It reads with `p.get`, so for a
  duplicate key the **first** value wins. `span` is read as `+value`, so `07`,
  `7.0`, ` 7` and `0x7` all read as `7`.
- `J:316-328` `writeURL(extra)`: starts from the current `location.search`
  (J:317), so keys keep their **incoming position** and unknown keys survive
  (only `zoom` and `density` are deleted, J:320-321). It then sets or deletes,
  appending a key that was absent, in this order: `view` (omitted when `graph`), `trees`,
  `models`, `live`, `span` (omitted when `1`), deletes `zoom` and `density`,
  `feature`, `fmode` (only when a feature is set and the mode is compact), then
  `epic`, `model`, `tstate`, `astate` (joined with `,`), `example`, then the
  `extra` keys (`ticket`). An empty value deletes the key. It replaces `%2C`
  with a literal `,` (J:327) and calls `history.replaceState`, so a filter
  change never adds a history entry.
- `writeURL` callers: J:629 (live min), J:631 (now-band state buttons),
  J:963 (`fitTree` span), J:1041 (models demo), J:1088 (fmode), J:1094
  (`setFeature`), J:1124 (`filtersChanged`), J:1143-1145 (view, density,
  trees), J:1231 (`setSpan`), J:1259 (`setDemo`), J:1455
  (`writeURL({ ticket: t.id })` on modal open), J:1556 (the backdrop observer
  clears `ticket` on close).
- The vocabularies the filters use: `J:88-91` `AST` keys `active error retries
  command paused parked`, plus `none` (`J:1102`); `J:1101` ticket states
  `merged failed "in progress" queued held blocked open`; `J:82-87` `MODELS`
  keys `claude codex deepseek kimi`.
- The now-band presets compare the **joined string** (`J:1121` `syncAst`):
  `active`, `error,retries,command`, `paused,parked` (`J:666-667`). The order
  of the values in `astate` therefore decides whether a preset button shows `.on`.
- The feature filter group writes `S.feature` (single value), not a list
  (`J:1107` `sel`, `J:1118` `setFeature`).
- `Aiur Dashboard.html` has no URL code (no `replaceState`, `pushState`,
  `URLSearchParams` or `location.search`).

**The product.**
- `lib/aiur_web/router.ex:139-148` `live_session :dashboard, on_mount:
  AiurWeb.FinancialDataAccess`; `/` is `DashboardLive, :index` (`:140`).
- `lib/aiur_web/live/dashboard_live.ex:196-212` `handle_params/3` decodes Units
  state and ends with `maybe_canonicalize_units_url/2` (`:1195-1205`), which
  patches with `replace: true` when the params differ from the canonical ones.
  `:1168-1171` `units_path/2` builds `"/?" <> URI.encode_query(params)`.
  `:1187-1193` `assign_units_selection/2`. This is the pattern to copy.
- `lib/aiur_web/operator_control_center/units_url.ex:33-51` `decode/1`: version
  `"1"` or absent is accepted (`:65-67`); any other version returns
  `default_selection/0`; `decode_query/1` (`:69-73`) rescues a malformed query.
- `lib/aiur_web/operator_control_center/units_policy.ex:9-10` scopes
  `live unfinished all none`, conditions `active alert paused stuck queued
  finished`; `:29` the default `%{scope: :live, conditions: []}`;
  `:31-39, 152-188` normalization drops unknown scopes and conditions without
  creating atoms. `normalize_conditions/1` (`:166-174`) returns the kept
  conditions in `@conditions` order, so `UnitsURL.decode/1` output is already
  ordered.
- `lib/aiur/coding_agent.ex:208-229` `provider_descriptors/0` and `:233`
  `provider_families/0`: the provider families that have a `presentation` entry
  (a logo). At `58854d4c8` these are codex, claude, kimi, deepseek, openrouter
  and muse, plus `fake` when `Mix.env() == :test`
  (`lib/aiur/coding_agent/registry.ex:7-28`). It is a superset of the design's
  `MODELS` keys (J:82-87). Every one matches the model key pattern (Chosen
  design); the URL is not limited to this list.
- `lib/aiur/tracker_identity.ex:266-277` `display_identifier/1` (private): a
  GitHub display id is a positive integer (`Integer.parse/1` with no
  remainder). `"007"` becomes `"7"`. It also accepts `"+7"`; this ticket's
  digits-only rule does not.
- `deps/phoenix_live_view` is `1.1.33` (`mix.lock`). In
  `deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:913-920`, a
  `push_patch` from `handle_event` runs `handle_params` **inline** in the same
  process, so a hook event and its patch cannot interleave with another event.
  `:857-869` raises after 20 patch redirects in a row, so canonicalization must be
  idempotent.
- Dead render: `deps/phoenix_live_view/lib/phoenix_live_view/static.ex:320-336`
  turns a `push_patch` from `handle_params` on the disconnected render into
  `{:stop, socket}`, which is an HTTP redirect to the patched URL. A
  non-canonical first load is therefore a redirect, not a patch.
  `DashboardLive` already relies on this (`maybe_canonicalize_units_url/2` has no
  `connected?` check).
- `deps/plug/lib/plug/conn/query.ex:147-157`: Plug www-form-decodes each value
  with `URI.decode_www_form/1`, which leaves a bad escape such as `%zz` as the
  literal text `%zz` (checked with Elixir 1.19.5). Only invalid UTF-8 (for
  example `%ff`) raises `Plug.Conn.InvalidQueryError` (status 400,
  `deps/plug/lib/plug/conn.ex:283-292`). A query over 1,000,000 bytes raises
  status 414 (`conn.ex:1108-1116`). The HTTP server is Bandit (`mix.exs:157`).
- `{:stream_data, "~> 1.2", only: :test}` is a dependency (`mix.exs:160`).
- Tests to copy: `test/aiur_web/live/dashboard_live_test.exs:4222-4272` (Units
  URL round trip with `render_patch` + `assert_patch`);
  `test/aiur_web/operator_control_center/units_url_test.exs`.
- Hook precedent: `priv/static/time-brush-hook.js:94`
  (`this.hook.pushEvent("time-domain", …)`).
- Browser harness: `test/browser/fixture_server.exs:905-963`
  (`Aiur.BrowserHarness.UnitsLive` with `handle_params` at `:962`), routes
  `:2266-2279`.

## Chosen design

**One parser, two inputs.** The URL query (from `handle_params`) and the hook's
event payload (from `"build:url"`) are the same flat map of string keys to
string values. Both go through `URLState.parse/1`. The server never trusts the
hook more than the address bar.

**State shape** (`URLState.t()`; plain strings, no atoms made from input):

```elixir
%{
  view: "graph" | "gantt" | "list",       # default "graph"
  span: 1 | 2 | 3 | 5 | 7 | 10 | 14 | 21 | 30,  # default 1
  feature: String.t() | nil,
  fmode: "focus" | "compact",             # "compact" only when feature != nil
  epic: [String.t()], model: [String.t()], tstate: [String.t()], astate: [String.t()],
  live_min: boolean(), trees: boolean(),
  ticket: String.t() | nil                # digits only, canonical integer form
}
```

**Validation rules** (`parse/1`). A value that fails is dropped. The key falls
back to its default:

| Key | Accepted | Notes |
| --- | --- | --- |
| `view` | `gantt`, `list` (exact, case-sensitive) | `graph` is the default and is never written (J:306, J:319) |
| `span` | `Integer.parse/1` with no remainder, value in `SPANS` | `07` → `7`; `7.0`, `4`, `-1` dropped |
| `feature` | a slug: 1–64 bytes of `[A-Za-z0-9._-]` | membership is not checked (see below) |
| `fmode` | `compact`, and only when `feature` is kept | J:323 writes it only in that case |
| `epic` | comma list of slugs (same rule as `feature`) | |
| `model` | comma list, each matching `^[a-z0-9][a-z0-9._-]{0,31}$` (not only `provider_families/0`), so C10-T02 can keep a model outside the known list (`zz-new`) | `none` dropped: the design has no `none` model option (J:1098) |
| `tstate` | comma list, each in `merged failed in progress queued held blocked open not planned` | `not planned` is C10-T02's state (E8-R1) |
| `astate` | comma list, each in `active error retries command paused parked none` | |
| `live` | `min` | |
| `trees` | `1` | |
| `ticket` | `^[0-9]{1,10}$` and > 0, rewritten to `Integer.to_string`; after C7-T02 also the `pack:<pack>/<item>` form (C7-T02 widens this rule in its PR) | same rule as `TrackerIdentity.display_identifier/1` |
| anything else | dropped | `models`, `example`, `zoom`, `density`, `filter`, `sort`, any unknown key |

List rules: split on `,`, drop empty and invalid items, drop duplicates,
**keep the given order**, at most 32 items. The order is kept because
`syncAst` (J:1121) lights a now-band preset only on an exact joined-string
match. Sorting would change which button shows `.on` (a parity break). A
non-string value (for example `epic[]=x`, which Phoenix decodes to a list) is
dropped.

**Why `epic` and `feature` are shape-checked and not membership-checked.** The
page pages history by day (C8-T04, C10-T03). A valid epic or feature can exist
outside the loaded window ("a focused feature with no tickets in the loaded
window loads its oldest day first", C10-T03). Dropping it at parse time would
break shared links. A shape-valid slug that matches nothing is C10-T02's empty
filter result, never a crash.

**Serialization** (`URLState.to_query/1`). A fixed key order that equals the
order the design produces from an empty query: `view, trees, live, span,
feature, fmode, epic, model, tstate, astate, ticket`. Default values are
omitted. Encode with `URI.encode_query/1` (www-form: a space is `+`, as
`URLSearchParams` does), then replace `%2C` with `,` (J:327). For example
`tstate=in+progress,queued`.

**Invariant.** `parse(URI.decode_query(to_query(s))) == s` for every state `s`
that `parse/1` can return, and
`to_query(parse(q))` is a fixed point. Without this, the channel's 20-patch
limit (`channel.ex:857-869`) would crash the LiveView on a canonicalization loop.

**Legacy Units presets** (`URLState.legacy_preset/1`). This runs when the params
contain any of `v`, `scope` or `conditions` (`legacy?/1`). `sort` is not a
trigger: alone it maps to the defaults either way, and it is dropped as an
unknown key (C12-T01 relies on that for `/?sort=fleet:…`). It reuses
`UnitsURL.decode/1` for the version check and normalization, then maps the
selection. `decode/1` already returns the conditions in
`UnitsPolicy.conditions/0` order, so `URLState` iterates
`selection.conditions` and does not reference `UnitsPolicy`:

| Units selection | Home preset |
| --- | --- |
| no conditions, scope `live` (the Units default, URL `/?v=1`), `all` or `none` | no filter (the home default) |
| no conditions, scope `unfinished` | `tstate=in progress,queued,held,blocked` |
| only agent conditions (`active`, `alert`, `paused`, `stuck`) | `astate`, the union of `active`→`active`; `alert`,`stuck`→`error,retries,command`; `paused`→`paused,parked`, in condition order, deduplicated |
| any of `queued` or `finished` among the conditions | `tstate`, the union of agent conditions→`in progress`; `queued`→`queued,held,blocked`; `finished`→`merged,failed`, in design tstate order (J:1101) |
| `v` other than `1` | no filter (`UnitsURL.decode/1` returns the default) |

A single agent condition gives exactly a now-band preset string, so the matching
button shows `.on`. When conditions are present, the scope is ignored. Units
ANDs scope with OR-ed conditions; home ANDs across groups. The closest faithful
preset for a mixed selection is a single `tstate` group (OR within it). If the
same URL also carries a home key for the same group (`astate` or `tstate`), the
home key wins. The result is then canonicalized and patched with
`replace: true`. The legacy keys disappear from the address bar.

**Bridge contract** (C9-T01 implements the client side):

- **Initial state.** `#build-root` gets `data-url-state={Jason.encode!(state)}`
  on render (keys `view span feature fmode epic model tstate astate live_min
  trees ticket`, as C9-T01's `fromServer` reads them). The hook reads it once
  in `mounted()`, in place of `readURL()` (J:1550). Later changes reach the hook
  only as `"build:url"` pushes.
- **Hook → server.** `this.pushEvent("build:url", params)` in place of every
  `writeURL(extra)`. `params` is the full flat map the design would have written
  (lists joined with `,`). It includes `ticket` only when `extra` has it
  (`""` clears, as the design's `set` deletes). The server keeps the current
  `ticket` when the key is absent, as the design's `writeURL` keeps
  `location.search` keys (J:317). The payload goes through `parse/1` only:
  legacy keys (`v`, `scope`, `conditions`) in a hook payload are dropped, not
  mapped. The server parses, assigns `:url_state` **before** it calls
  `push_patch`, and patches with `replace: true` only when the canonical query
  changed. Because the patch runs `handle_params` inline (`channel.ex:913-920`)
  and that call sees an equal `:url_state`, it pushes nothing (no echo).
  **Push back** when parsing rewrote input: let `sent` be the payload's
  non-empty string values minus `ticket`; push the parsed state when
  `Map.take(URI.decode_query(to_query(state)), Map.keys(sent)) != sent`. An
  unknown key, a dropped value, a removed duplicate or `07` → `7` all count.
- **Server → hook.** `push_event(socket, "build:url", %{state: state})` whenever
  `handle_params` produces a state different from a **previous** `:url_state`
  assign (`socket.assigns[:url_state]` is not `nil`) and the socket is
  connected. The first `handle_params` after a mount or rejoin never pushes:
  `data-url-state` already carries that state. This covers back and forward (the browser's `popstate` makes LiveView
  call `handle_params`), a legacy redirect, and a `live_patch` link. The hook
  applies the state and does not call `"build:url"` in reply (no echo).
- `replace: true` everywhere matches the design: filter changes do not add
  history entries (J:327). "Back and forward restore state" means: leaving the
  page and coming back, or opening a stored link, restores everything in the URL.
- **Path.** `handle_params/3` stores `URI.parse(uri).path` in an assign, and the
  patch target is that path, plus `"?" <> query` only when the canonical query
  is not empty. The raw query is `URI.parse(uri).query || ""`. The same code then works at
  `/build` (temporary), at `/` after C12-T01, and at any later route.

URL state is not a write: it needs no `dashboard_writable` check and works on a
read-only dashboard (EC-12 is not affected).

## Implementation steps

1. PROPOSED `lib/aiur_web/build/url_state.ex`: `defaults/0`, `parse/1`,
   `to_query/1`, `legacy_preset/1`, `legacy?/1`, and module attributes for the
   closed vocabularies (`@views`, `@spans`, `@tstates`, `@astates`) and the
   `@model_key` pattern `^[a-z0-9][a-z0-9._-]{0,31}$`. Add a `ponytail:` comment on the slug rule that names its link to
   C5-T01 and C6-T01.
2. `lib/aiur_web/live/build_live.ex` (C3-T01):
   - `handle_params(params, uri, socket)`: `state = if legacy?(params), do:
     parse(Map.merge(legacy_preset(params), home_params(params))), else:
     parse(params)`, where `home_params/1` is `Map.drop(params, ["v", "scope",
     "conditions"])` (so a home key wins over the preset). Read
     `previous = socket.assigns[:url_state]`. Assign `:url_path` and
     `:url_state`. Push `"build:url"` when `previous != nil`, `previous !=
     state` and `connected?(socket)`. Patch with `replace: true` when
     `to_query(state)` differs from the raw query (same shape as
     `maybe_canonicalize_units_url/2`, `dashboard_live.ex:1195-1205`). C3-T01's
     `mount/3` is not changed.
   - `handle_event("build:url", params, socket) when is_map(params)`, placed
     **before** C3-T01's catch-all `handle_event/3`: keep the current `ticket`
     when the key is absent; parse; assign `:url_state`; then patch when the
     canonical query changed; push back by the rule above. Any non-map payload
     falls through to the catch-all and is ignored.
   - `#build-root` gets `data-url-state`.
3. C3-T01's seam-scan allow-list (PROPOSED `test/aiur_web/build/seam_test.exs`,
   rule 1): add `AiurWeb.OperatorControlCenter.UnitsURL` (one entry, R-G3).
4. PROPOSED `src/browser/scripts/build-home-url-golden.mjs`, next to C1-T01's
   exporter and in the same style (ESM, `node:vm`, `node:fs`, `node:crypto`).
   Read the vendored `src/test/fixtures/build_home/design-source/assets/build.js`,
   insert `window.__E8URL = { readURL, writeURL, S };` at C1-T01's anchor (count
   must be 1), and for **each case run a fresh context** (`S` is module state):
   `{ window: {}, document: {}, URLSearchParams, location: { search: q,
   pathname: "/build", hash: "" }, history: { replaceState: (_a, _b, url) =>
   (out = url) } }`. `URLSearchParams` must be passed in: a `vm` context has no
   Web APIs. Call `readURL()` then `writeURL()` and record `out`. Write PROPOSED
   `src/test/fixtures/build_home/url_cases.json` with the `build.js` sha256 (the
   C1-T01 staleness rule). `--check` recomputes and compares. Add it to C1-T01's
   `check:build-home-fixtures` npm script so the browser CI job runs it.
5. Tests (see Verification). No docs in this PR: `/build` is temporary and not
   in the nav. The text for C12-T07 is under "Completion and handoff".

## Non-happy paths

- **Malformed query.** A bad escape (`%zz`, a lone `%`) reaches the LiveView
  as literal text (Plug, see "Verified starting point"). It fails the slug or
  vocabulary rule and is dropped, so the first load redirects to the canonical
  URL. Invalid UTF-8 (`%ff`) is a 400 from Plug before the LiveView runs.
  Anything that reaches `handle_params` is a map of strings, lists or maps.
  Non-strings are dropped. A `"build:url"` payload goes through the same parser.
- **Non-canonical first load.** On the dead render the canonical `push_patch`
  is an HTTP redirect (`static.ex:320-336`), as `/?v=1&scope=…` on `/` is
  today. The browser then loads the canonical URL once. Tests check the first
  load with `get/2` and `redirected_to/1`, and check live canonicalization by
  mounting on a canonical URL and then calling `render_patch/2`.
- **Hostile values:** a value is never turned into an atom. Values are checked
  against string allow-lists or the slug charset, so no markup survives parsing.
  `data-url-state` is attribute-escaped by HEEx, and the hook still treats every
  string as data (C3-T02's escaping rule, EC-30).
- **Oversized input:** lists are capped at 32 items and slugs at 64 bytes, so the
  canonical URL stays bounded whatever arrives. Plug rejects a query over
  1,000,000 bytes (414), and Bandit's request-line limit applies before that.
- **Duplicate keys** (`?view=gantt&view=list`): Plug keeps the last value
  (`list`); the design's `p.get` keeps the first (`gantt`). The canonical URL has
  one key. This is an allowed parity difference (see Pixel parity).
- **Canonicalization loop:** prevented by the idempotence invariant and its
  test. A loop would raise "too many redirects" at the 20th patch.
- **Race between hook events:** none. `push_patch` runs `handle_params`
  inline (`channel.ex:913-920`), and events on one socket are serial.
- **Disconnect and rejoin:** the new LiveView process mounts from the current
  address bar, and its first `handle_params` does not push. The hook is not
  mounted again on a rejoin; LiveView calls its `reconnected()`, where C9-T01's
  `flushURL()` sends the hook's current state once as `"build:url"`. The server
  parses it like any hook event, so a write lost while the socket was down is
  applied, and an equal state causes no patch.
- **`?ticket=` well-formed but unknown or closed:** kept in the URL (not
  dropped), so C11-T01 can show the not-found state (S-10) or fetch it by id
  (EC-17). Malformed values (`AIUR-12`, `#12`, `0`, `12a`, 11+ digits) are
  dropped. The design's `AIUR-N` ids are mock.
- **Unknown, stale or unavailable values:** URL state carries no observed data.
  A dropped parameter is removed from the address bar, so the page never looks
  filtered when it is not. The AGENTS.md unknown-path mutation test does not
  apply. There is no unknown rendering branch in this ticket.

## Compatibility and rollout

- No config key, no migration, no new environment variable.
- Before C12-T01, BuildLive lives at `/build` and the Units page still owns `/`.
  The legacy mapping is tested at `/build` and takes effect on `/` at cutover
  with no extra code.
- After cutover, the hidden `/units` rollback route (OQ-E8-3, C12-T01) keeps
  `UnitsURL` in use, so the module stays until C12-T03.
- Rollback: reverting this ticket leaves BuildLive with the design defaults and
  no URL sync. Nothing persistent changes.

## Pixel parity

There is no visual element in this ticket. Parity here means the **address
bar**: after the same interaction on the same dataset, the design and the
product show the same `location.search`.

- **Design elements reproduced:** `readURL`/`writeURL` (J:304-328), the key
  order and default omission (J:319-326), the literal-comma rule (J:327), and the
  `replaceState` (no history entry) behaviour.
- **Check 1 (ExUnit, this ticket):** the golden table in `url_cases.json`
  (generated from the unmodified `build.js`) is asserted against
  `to_query(parse(q))`. Allowed differences come only from the C3-T03 row and
  plan §10, and are marked in the case file with `"differs"` and the reason:
  - unknown or empty list values dropped (the design keeps any value);
  - `models` and `example` dropped (demo parameters);
  - unknown keys dropped (the design keeps every key except `zoom` and
    `density`, J:320-321);
  - key order fixed (the design keeps each key's incoming position, J:317);
  - duplicate keys: last value kept (the design keeps the first);
  - `span` forms that `+value` reads but `Integer.parse/1` rejects (`7.0`,
    ` 7`, `0x7`) dropped (the design writes `7`);
  - malformed `ticket` values dropped (the design keeps them);
  - legacy Units keys mapped.
  Every other case must be byte-identical. The case table must include at least
  one canonical-order case per key, and one case per difference above.
- **Check 2 (C1-T03, interaction parity):** C1-T03 already compares the URL
  query after each interaction (its step 4, "Also the URL query"). This ticket
  adds one assertion there: `history.length` did not grow after each scripted
  interaction (view switch, span, feature focus and compact, each filter group,
  now-band presets, live min, trees, modal open and close). The `ticket` value
  differs by design (`AIUR-N` against the real number) and C11-T01 owns that
  comparison. If C1-T03 has not merged, it records this as a required step for
  its writer.

## Verification

ExUnit (PROPOSED `test/aiur_web/build/url_state_test.exs` and
`test/aiur_web/live/build_live_url_test.exs`):

| Test | Input → expected | Fails without |
| --- | --- | --- |
| "parse keeps every valid design key" | `view=gantt&trees=1&live=min&span=7&feature=f-docs&fmode=compact&epic=bugs,docs&model=claude&tstate=in+progress&astate=error,retries,command&ticket=2748` (canonical order) → all fields set; `to_query` returns the same string byte for byte | `parse/1` and `to_query/1` |
| "key order is fixed" | `span=7&view=gantt` → `"view=gantt&span=7"` | the fixed key order (mutate: keep input order → fails) |
| "span accepts only integers" | `span=07` → `7`; `span=7.0`, `span=4`, `span=-1` → default | the `Integer.parse` rule |
| "parse drops invalid values" | `view=Gantt&span=4&fmode=compact&astate=bogus,active,active&model=none&ticket=AIUR-12&zoom=2&models=7&example=dense` → `defaults/0` except `astate: ["active"]`; `to_query` == `"astate=active"` | each validation clause (mutate one: accept `view` case-insensitively → the test fails) |
| "model accepts any key" | `model=zz-new,claude` → `["zz-new", "claude"]`; `model=Claude`, `model=-x`, a 33-character key → dropped | the key pattern (mutate: restrict to `provider_families/0` → the `zz-new` case fails) |
| "list order is kept" | `astate=paused,parked` and `astate=parked,paused` → `to_query` keeps each order | the order rule (mutate: `Enum.sort` → fails) |
| "commas are literal and spaces are plus" | `tstate=in progress,queued` → `"tstate=in+progress,queued"` | the `%2C` replacement |
| "canonical form is a fixed point" | for every case in `url_cases.json` and 200 generated valid states (`ExUnitProperties`, StreamData is a test dep): `parse(URI.decode_query(to_query(s))) == s` | the invariant (mutate: write `fmode` without `feature` → fails) |
| "golden parity with build.js" | each `url_cases.json` case without `"differs"`: `to_query(parse(q)) == design_output` | key order or default omission |
| "ticket validation" | `007` → `"7"`; `0`, `-3`, `12a`, `#12`, `12345678901` → `nil`; `99999` (unknown) → `"99999"` (kept) | the ticket clause (mutate: drop unknown-looking ids → the `99999` row fails) |
| "legacy presets" | `v=1` → `""`; `v=1&scope=unfinished` → `tstate=in+progress,queued,held,blocked`; `v=1&conditions=alert` → `astate=error,retries,command`; `v=1&conditions=active,paused` → `astate=active,paused,parked`; `v=1&conditions=active,queued` → `tstate=in+progress,queued,held,blocked`; `v=1&scope=all&conditions=finished&sort=units:age:desc` → `tstate=merged,failed`; `v=999&conditions=alert` → `""`; `conditions=alert&astate=paused` → `astate=paused`; `sort=fleet:age:desc` alone → `""` | `legacy_preset/1` |
| "BuildLive canonicalizes the address bar" | `live(conn, "/build")`, then `render_patch(view, "/build?span=4&view=list&zoom=2")` → `assert_patch(view, "/build?view=list")` | the `handle_params` patch |
| "non-canonical first load redirects" | `get(conn, "/build?view=list&zoom=2")` → 302, `redirected_to(conn) == "/build?view=list"` | the `handle_params` patch on the dead render |
| "legacy Units URL redirects to a preset" | `render_patch(view, "/build?v=1&scope=unfinished&conditions=active")` → `assert_patch(view, "/build?astate=active")` | the legacy branch in `handle_params` |
| "hook event patches the URL" | after `live(conn, "/build")`: `render_hook(view, "build:url", %{"view" => "gantt", "span" => "7"})` → `assert_patch(view, "/build?view=gantt&span=7")`; `refute_push_event(view, "build:url", _)` (no echo, and no push from the first `handle_params`) | the `handle_event` clause; assigning `:url_state` after the patch instead of before (the inline `handle_params` then pushes) |
| "hook event keeps the ticket unless cleared" | on `/build?ticket=12`: `render_hook(…, %{"view" => "list"})` → `"/build?view=list&ticket=12"`; then `%{"ticket" => ""}` → `"/build?view=list"` | the ticket-merge rule |
| "hook event with an invalid value pushes the parsed state back" | `%{"astate" => "bogus"}` → `assert_push_event(view, "build:url", %{state: %{astate: []}})` | the push-back branch |
| "back and forward restore state" | `render_patch(view, "/build?view=list&epic=bugs")` → `assert_push_event(view, "build:url", %{state: %{view: "list", epic: ["bugs"]}})`; `render_patch(view, "/build")` → pushes the defaults | the push in `handle_params` |
| "mount does not push" | `live(conn, "/build?view=gantt")` → `refute_push_event(view, "build:url", _)` | the `previous != nil` guard |
| "initial state is in the container" | `live(conn, "/build?view=gantt")` → `#build-root[data-url-state]` decodes to `view: "gantt"` | the attribute |
| "malformed escape is dropped" | `get(conn, "/build?epic=%zz")` → 302, `redirected_to(conn) == "/build"`; `get(conn, "/build?epic[]=x")` → 302 to `/build` | the slug rule; the non-string drop clause |
| "invalid UTF-8 is a 400" (regression guard on Plug, not counted as coverage) | `assert_error_sent(400, fn -> get(conn, "/build?epic=%ff") end)` | nothing in this ticket; guards the claim in Non-happy paths |

Mutation check (AGENTS.md): in a worktree with a clean `git status --porcelain`,
remove the legacy branch, the `handle_event` clause, the push in
`handle_params`, the `previous != nil` guard, and the order rule, one at a time. Run the two files and
confirm the named test fails each time. Then restore. Report the commands in
the PR body.

Command (isolated HOME, memory note "mix test clobbers agent-token"):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/build/url_state_test.exs test/aiur_web/live/build_live_url_test.exs
env -C src/browser node scripts/build-home-url-golden.mjs --check
```

Browser (once C9-T01 exists, in `src/browser/tests/`, PROPOSED
`build-url.browser.spec.mjs`): load `/build?view=list&astate=paused,parked`;
the List view is shown and the "paused" now-band button has `.on`. Click Gantt;
`page.url()` ends `?view=gantt&astate=paused,parked`, and `history.length` is
unchanged. Navigate to `/commands` and `page.goBack()`; the Gantt view and the
filter are restored.

No manual TUI test is needed: this ticket does not touch agent chat. C12-T01's
manual run covers `/` after cutover.

## Completion and handoff

- [ ] `URLState` parses, validates and serializes every design key; the golden
      parity cases pass, and every `"differs"` case names its reason.
- [ ] `BuildLive` canonicalizes with `replace: true`, maps legacy Units URLs,
      handles `"build:url"` without echo, and pushes state on back and forward.
- [ ] Idempotence test passes; mutation checks reported in the PR body.
- [ ] Seam-scan allow-list updated for `UnitsURL`.
- **Dependents:** C9-T01 (the bridge client, per the contract above), C10-T02
  (filters call the bridge), C11-T01 (reads `state.ticket`, sends
  `ticket` on open and `""` on close), C12-T01 (cutover test: `/?v=1&scope=…`
  on `/` lands on the preset), C12-T07 (docs).
- **Docs text for C12-T07** (`guide/gui.md` route-change table): "Old Units links
  (`/?v=1&scope=…&conditions=…`) open the home page with the matching agent-state
  or ticket-state filter. The home page keeps its view, range, feature focus,
  filters and open ticket in the URL (`view`, `span`, `feature`, `fmode`, `epic`,
  `model`, `tstate`, `astate`, `live`, `trees`, `ticket`). Invalid values are
  removed." The `sort` sentence in `gui.md` stays true for the other tables.
- **Sources:** J:82-91, 300-328, 629-631, 666-667, 1097-1127, 1455, 1549-1576;
  the product files cited under "Verified starting point".

### Interface notes for neighbour rows

1. **C3-T01 seam scan.** Settled 2026-10-08: this ticket adds the one
   `UnitsURL` entry in its PR (R-G3); no `Aiur.CodingAgent` entry is needed.
2. **C3-T02 ticket id (agreed).** The URL carries the display number
   (`ticket=2748`). The design writes `t.id` (`AIUR-N`, J:1455). C3-T02's row
   `id` is already the bare `TrackerIdentity.identifier` string (`"123"`), or
   `"pack:<pack>/<item>"` for an unfiled item (C3-T02 row table). Settled
   2026-10-08: C7-T02 widens this parser's `ticket` rule to the pack form in its
   PR (and makes the C11-T01 `writeURL` change).
3. **C10-T02 `not planned`.** C10-T02 says the not-planned collapse is "a default
   filter that appears in the URL". This ticket keeps the bare URL canonical (the
   design omits every default, J:319-326). The default collapse is therefore the
   **absence** of `tstate`, and the token for the state is `not planned` (the
   design's spaced style, as in `in progress`). C10-T02 must render its default
   chip from that absence, not from a written parameter. C10-T02 has adopted
   this ("the default is the absence of `tstate`"). If it later needs a written
   token, both tickets change together.
4. **C5-T01 / C6-T01 slugs.** The slug rule here is `[A-Za-z0-9._-]{1,64}`. If an
   epic or feature slug may contain another character (or a comma), those tickets
   must say so, and this one function changes.

## Decisions made without the owner

1. **Unknown list values are dropped,** although the design keeps them. This
   follows the C3-T03 row ("Unknown values are dropped"). It is marked as an
   allowed difference in the golden file.
2. **List order is kept, not sorted,** so the now-band preset `.on` state
   behaves exactly as in the design (J:1121).
3. **`epic` and `feature` are shape-checked only,** because history is paged
   and a valid slug can be outside the loaded window.
4. **The legacy mapping ignores the Units scope when conditions are present,**
   and maps a selection that mixes agent and ticket conditions to one `tstate`
   group. Units' scope-AND-conditions logic has no exact equivalent across two
   AND-ed home groups. A single preset string is the closest shareable view.
   `/?v=1` (the old Units default) maps to the unfiltered home page.
5. **A model is any key matching `^[a-z0-9][a-z0-9._-]{0,31}$`,** not only
   `CodingAgent.provider_families/0`, so C10-T02 can keep a model outside the
   known list in the URL (`zz-new`). `none` is not a model value, because the
   design has no such option.
6. **Initial state is a `data-url-state` attribute,** read once in `mounted()`,
   and later changes travel as `"build:url"` events. This does not depend on
   whether LiveView updates attributes on a `phx-update="ignore"` container.
7. **Complexity stays 2,** as the row sizes it. One pure module, two callbacks,
   one small Node script that reuses the C1-T01 loader.
8. **`sort` is not a legacy trigger.** It is dropped as an unknown key, which
   gives the same result and keeps `legacy?/1` to the three `UnitsURL` keys.
9. **The server does not push on the first `handle_params`** after a mount or
   rejoin. `data-url-state` already carries that state, and C9-T01's
   `flushURL()` covers a rejoin.

## Review log

Adversarial review, 2026-10-08, against `runtime/src` at `58854d4c8`, the
design source, the README row, and the C1-T01, C1-T03, C3-T01, C3-T02, C9-T01,
C10-T02, C11-T01, C12-T01 and C12-T02 ticket files.

1. Citations corrected: `FKEYS` is J:300; `readURL()` call J:1550; backdrop
   observer J:1556; feature filter J:1107/J:1118; `tracker_identity.ex:266-277`;
   `units_policy.ex:31-39, 152-188`; fixture routes `:2266-2279`.
2. Design facts added: `writeURL` keeps incoming key order and unknown keys
   (J:317, J:320-321); `p.get` keeps the first duplicate; `+value` accepts
   `7.0`, ` 7`, `0x7`. The golden "allowed differences" list now covers key
   order, unknown keys, duplicates, span forms, empty items and ticket values.
   Before, the golden test would have failed on any non-canonical input.
3. Test "parse keeps every valid design key" used a non-canonical key order
   and could not pass byte for byte. The input is now in canonical order. Added
   "key order is fixed" and "span accepts only integers".
4. Server push rule: no push on the first `handle_params` after mount or
   rejoin (`previous != nil`). Without it, the initial connected mount pushed,
   and `refute_push_event` in the no-echo test would have failed. Added a
   "mount does not push" test and a mutation step.
5. No-echo depends on assigning `:url_state` before `push_patch` (the patch
   runs `handle_params` inline). This is now explicit, with a mutation named.
   The clause sits before C3-T01's catch-all.
6. Push-back ("parse rewrote input") was undefined. It is now a concrete
   comparison over the sent non-empty keys.
7. Rejoin was wrong: a hook is not mounted again on rejoin. It now uses
   C9-T01's `reconnected()` → `flushURL()`.
8. Malformed query: verified that Plug keeps `%zz` as literal text and returns
   400 only for invalid UTF-8; verified that a dead-render `push_patch` is an
   HTTP redirect (`static.ex:320-336`). The "400 or 200" test, which accepted
   either result, became concrete `get` + `redirected_to` tests and a labelled
   Plug guard.
9. Seam scan: the scanner works on modules, so the allow-list entry is the
   exact `Aiur.CodingAgent`, and the function limit is a review comment.
   `UnitsPolicy` is not needed because `decode/1` already orders conditions.
10. Removed `sort` as a legacy trigger. It was redundant, and C12-T01 expects it
    to be dropped as an unknown key.
11. Golden script moved to `src/browser/scripts/` next to C1-T01's exporter. It
    now passes `URLSearchParams`, `pathname` and `hash` into the `vm` context,
    uses a fresh context per case, and joins C1-T01's CI check script.
12. StreamData is a test dependency (`mix.exs:160`); the "if available"
    hedge was removed. Bandit replaces the Cowboy claim; Plug's 414 limit
    cited.
13. Interface notes 2 and 3 updated: C3-T02 `id` is already the bare number,
    and C10-T02 has adopted the "absence of `tstate`" default. C1-T03 already
    compares the URL query, so this ticket adds only `history.length`.
14. Model allow-list cited completely (codex, claude, kimi, deepseek,
    openrouter, muse; `fake` in test).

Residual risks: the golden case table is written by the implementer, and its
quality decides how much parity it proves. The dead-render redirect status
(302) is read from the LiveView source, not from a test run here.
- Reconciliation 2026-10-08 (coordinator): `model` values accept any key matching `^[a-z0-9][a-z0-9._-]{0,31}$` (not only `provider_families/0`; table, step 1, Decision 5, new "model accepts any key" test), `Aiur.CodingAgent` seam entry dropped (only `UnitsURL`, R-G3), `ticket` takes the `pack:<pack>/<item>` form after C7-T02 widens the rule, interface notes 1 and 2 settled.
