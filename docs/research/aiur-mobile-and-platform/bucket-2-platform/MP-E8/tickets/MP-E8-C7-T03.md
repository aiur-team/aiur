---
ticket_id: MP-E8-C7-T03
feature_id: MP-E8
chunk_id: MP-E8-C7
bucket: 2-platform
title: Estimates, overrides, CLI and ETA
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C7-T01, MP-E8-C8-T04, MP-E8-C9-T08, MP-E8-C9-T09, MP-E8-C9-T12, MP-E8-C11-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-08, EC-13]
owner_question_defaults: [OQ-E8-7]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C7-T03 — Estimates, overrides, CLI and ETA

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime/src`). Paths marked PROPOSED do not exist yet. `J`,
> `C` and `H` are `design-source/assets/build.js`, `build.css` and
> `Aiur Dashboard.html` (etag 1791431544512943). If MP-R1 has moved
> `build_order/` or `agent_control_cli.ex` before this starts, re-resolve the
> symbols below.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C7
  (planned, not-queued and estimates).
- **User value.** Every planned card says how long it should take ("≈4h"), a
  planner can correct one estimate with a recorded reason, and the Live band
  says how long the whole planned queue will take at the real agent cap. A
  ticket with no complexity never shows a made-up number.
- **Deliverable.**
  1. PROPOSED `Aiur.BuildOrder.Estimates`: the default table, the resolver, and
     a small durable override store (hours, reason, actor, time, a per-ticket
     journal), with a change signal.
  2. `aiur ticket estimate <id> [<hours> --reason <text> | --clear --reason <text>] [--by <who>] [--json]`
     through the shared launcher engine.
  3. The `est` and `override` fields of every `plan` and `now` row in the C3-T02
     payload, filled by the resolver.
  4. PROPOSED `src/priv/static/build-home/estimate.js`: `estHours(t)`,
     `estLabel(t)` and `etaLabel(D)`. They replace the design's inline
     expressions at J:516, 667, 859–860, 1161 and 1435, and the ETA divides by
     the live agent cap instead of the constant 4.
  5. The `reference/cli.md` entry for the new command (AGENTS.md "Docs ship
     with the change").
  6. The two payload keys that C3-T02's extension rule assigns to this ticket
     (C3-T02 "Extension rule" table: "`capacity`, `sources.estimates` |
     C7-T03"): the `Payload.validate/1` clause for each, their fixture mapping
     in C3-T02's export step, the `capacity` key in the diff `set` map, and the
     producer. They land in this ticket's PR, not in C3-T02.
- **Non-goals.**
  - No historical-median estimate (OQ-E8-7 default is the design table).
  - No dashboard control to edit an estimate: the design has none.
  - No dynamic tool for agent workspaces (decision 4).
  - No forecast or queue simulation against capacity (decisions.md "How planned
    tickets get times" stays open; this is the design's single ETA figure).
  - No card, Gantt or modal layout work. C9-T05, C9-T08, C9-T09, C9-T12 and
    C11-T02 port those; this ticket supplies the values and the three helpers.

## 2. Dependencies and blockers

- **DESIGN-E8** (the gate on every E8 ticket). No S-item covers an unknown
  estimate; the defaults in §4.5 are this ticket's and are listed in §10 for
  sign-off.
- **MP-E8-C7-T01** (predecessor): its planned rows carry `cx` (1..5 or `nil`)
  and `qpos`/`wave`. This ticket adds `est`/`override` to those rows. Now rows
  come from C8-T01; the C8-T04 assembler calls the resolver for them too (§4.3).
- **MP-E8-C8-T04, C9-T08, C9-T09, C9-T12, C11-T02** (predecessors, R-G12). This
  ticket lands after them: it wires `est`/`override`/`capacity`/
  `sources.estimates` into the C8-T04 assembler (adding the
  `"build-estimates:changed"` subscription there) and replaces their interim
  estimate/ETA sites (and C9-T05's) with `estHours`/`estLabel`/`etaLabel`.
  Until then those sites render `—` / `ETA —`.
- **OQ-E8-7** is not a blocker (tickets/README.md rules). The default is the
  design table `[1,2,4,7,11]`. If Kevin picks the historical median, only
  `default_hours/1` changes; the store, CLI and ETA stay.
- **Contracts and schema.** C3-T02 (payload v1) already defines
  `est: number | null` and `override: {hours, reason, by, at} | null` on the row.
  Its extension rule names this ticket as the owner of `capacity` and
  `sources.estimates`: "Each additive key therefore lands in one PR together
  with its validator clause, its fixture mapping and its producer, in the ticket
  that owns it". So this ticket edits C3-T02's PROPOSED
  `src/lib/aiur_web/build/payload.ex` (validator) and fixture export for those
  two keys only (§4.4, §5 step 6).
- **C9-T08** ships `bandEta(D)` as a placeholder that prints `ETA —` and a
  parity allowlist entry on `.bd-now-eta` marked "pending: removed by C7-T03".
  This ticket replaces `bandEta` with `etaLabel` and deletes that entry.
- **C9-T09** owns the band Gantt height at J:493 and already uses `estHours`
  there.
- **Downstream.** C5-T04 (skill guidance for `aiur ticket estimate`), C12-T07
  (docs pass), and the renderers listed in non-goals.
- **May run concurrently with** C7-T02, C7-T04, C5-T03, C6-T04 (different files;
  C5-T03 and C6-T04 also add engine subcommands, so expect a trivial merge in the
  engine's `case` block near `aiur-engine.sh:4234`).

## 3. Verified starting point (`58854d4c8`)

| What | Where | Use here |
| --- | --- | --- |
| Complexity label parse | `lib/aiur/build_order/metadata.ex:21-34` `parse/1` → `complexity: 1..5 \| :unknown`, `:99` `parse_complexity/1` (`complexity:1`..`complexity:5` only; missing, invalid and ambiguous all give `:unknown`) | C7-T01 maps `:unknown` to `cx: nil`; the resolver reads `cx` only |
| Other complexity reader | `lib/aiur/coding_agent.ex:928-945` `complexity_level/1` (takes the max of several labels) | Not used: the board must not pick one of two conflicting labels |
| Complexity labels | `lib/aiur/github/labels.ex:119` `complexity_labels/0`, `:123` description "story-point complexity N" | Defines the 1..5 domain |
| Agent cap, runtime | `lib/aiur/orchestrator/slots.ex:192-203` `max_concurrent_agent_limit/1` (session override from `aiur set max-agents`, then state, then config); `:216-238` `max_concurrent_agent_status/1` returns `max`, `configured`, `session_override?` | ETA divisor is `max` |
| Agent cap, config | `lib/aiur/config.ex:702-707` `max_concurrent_agents/0` (`agent.max_concurrent_agents`, else `default_max_concurrent_agents/1` at `:721-728`); schema `lib/aiur/config/schema/agent.ex:138-142` | Explains why `max` differs from the config key |
| Cap in the published snapshot | `lib/aiur/orchestrator/status_report.ex:403` `capacity: Slots.max_concurrent_agent_status(state)`; `:180` `max_concurrent_agents` in the poll-state broadcast | The assembler reads the cap without a blocking call |
| Cap normalisation | `lib/aiur_web/presenter.ex:51` and `:476-486` `capacity_payload/1` (only positive integers; else `nil`, "labelled unknown rather than deriving capacity from rows"); `:521-522` `positive_integer/1` | Same rule for the ETA divisor |
| Snapshot read | `lib/aiur_web/presenter.ex:24-35` `Orchestrator.dashboard_snapshot/2` → `{:current \| :stale, snapshot, freshness}`, `:snapshot_unpublished`, `:orchestrator_unavailable` | Source of `capacity.max` and its freshness |
| Atomic write | `lib/aiur/fs.ex:18-19` `Fs.atomic_write/3` (`mode:` option); `:105-119` `Fs.quarantine/1` | Store write and corrupt-file handling |
| State dir | `lib/aiur/config/paths.ex:60-66` `decision_state_dir/0`; `:99-110` `progress_retention_state_dir/0` (app-env override, then a leaf under the decision dir) | `build_estimates_state_dir/0` copies `:99-110` with leaf `build-estimates` |
| Health struct | `lib/aiur/build_order/lifecycle.ex:1-62` `Aiur.BuildOrder.ProviderHealth` (`state`, `complete?`, `failure`; `usable?/1` at `:47`) | Store health, as C4-T01 does |
| Application tree | `lib/aiur.ex:447` `Aiur.ProgressRetention`; `:452` `TicketHistoryProvider` | New child next to C4-T01's History child |
| Engine dispatch | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:4234-4237` `build-orders)` case; `:3043-3073` `cmd_build_orders` (argument loop, base64 values); `:2861-2863` `encode_control_value`; `:2463-2480` `run_control_rpc` (timeout → "outcome is unknown"); `:466` help line | Pattern for `cmd_ticket` |
| RPC entry | `lib/aiur/agent_control_cli.ex:376-378` `build_orders/1` through `guarded/2` (`:3209-3229`), `control_error/1` (`:3273-3277`), `exit_marker/1` (`:3510-3513`) | `ticket_estimate/1` follows it |
| Engine tests | `test/aiur_engine_test.exs:1388-1401` (`run_sourced_engine` with a stub `run_control_rpc`) | Same shape for the new parser |
| Agent tools | `lib/aiur/codex/dynamic_tool.ex:15` `@handlers` (no estimate tool) | Decision 4 |
| CLI docs | `website/docs-app/reference/cli.md:22-32` "What the CLI does" table (row "Act on durable records" at `:31`); `:241` "Decisions, Executor events, and findings" | The command writes a durable record, so it joins that row and section, not the read-only "Dashboard page commands" section (`:197`) |

Current behaviour: no estimate exists anywhere in the product. `grep -rln
estimate lib/` hits only unrelated modules (GitHub cost, telemetry, model
discovery). The Units and Build Order pages show no duration forecast.

**Design facts this ticket must reproduce** (read at the etag above):

- `EST = [1, 2, 4, 7, 11]` hours by complexity 1..5 (J:94). `PTS = [1,2,3,5,8]`
  (J:93) is C7-T01's, not this ticket's.
- The mock jitters planned estimates (`EST[cx-1] * (0.35 + r()*1.5)` rounded to
  quarter hours, J:261) and derives running estimates from elapsed time and
  progress (J:255). Both are mock data. The product uses the table value; the
  exported fixtures keep the jittered values, so parity runs on fixtures are
  unaffected.
- The override shape is `{ hours, reason }` (J:224: `hours: 7, reason: "Planner
  override · needs 3 illustration rounds with design review — bumped from 2h to
  7h"`). C3-T02 extends it with `by` and `at`.
- The effective estimate is `t.override ? t.override.hours : t.est` everywhere:
  card status (J:859–860, `"≈" + est + "h · " + t.pts + " pts"`), Gantt planned
  height (J:516–517), list row (J:1161, `"Q" + qpos + " · W" + wave + " · ≈" + h +
  "h"`), ETA (J:667). The modal adds a fallback `t.est || EST[t.cx - 1]`
  (J:1435) that this ticket removes (the server is the one source).
- Override cue on a full-detail planned card (J:857):
  `<span class="bd-q ovr" title="<esc(reason)>">` + pencil icon (J:55) +
  `" estimate overridden"`. Modal cue (J:1426): `<p class="bm-cue">` + pencil +
  `esc(reason)`.
- ETA (J:667): `<span class="bd-now-eta">` + `(D.plan.length + D.now.length) +
  " to go · ETA " + (D.plan.length ? Math.round(Σ/4) + "h" : "—")`. The sum
  covers planned rows only; running rows count toward "to go" but not toward
  the hours.
- CSS: `.bd-q` (C:252) `600 .68em JetBrains Mono`, padding `.12em .45em`,
  radius 999px, `1px solid var(--line)`, `var(--muted)`; `.bd-q svg` 1em (C:253);
  `.bd-q.ovr` (C:256) `var(--super-ink)`, `var(--super-line)`, `border-style:
  dashed`, `cursor: help`. `.bd-now-eta` (C:390) `margin-left: auto; 600 .68rem
  JetBrains Mono; var(--muted)`; hidden at `@container bd (max-width: 560px)`
  (C:393); in the minimised band `margin-left: 1rem; order: 8` (C:1103).
  `.bm-cue` (C:592–594) `.84rem`, svg 14 px; `.bm-facts b` (C:598) `600 .9rem`.
  Gruvbox `--super-ink` is `#e3aab9` dark (C:1037) and `#8f3f71` light (C:1048);
  the default palette is in H:61–63 and H:113–115.

## 4. Chosen design

### 4.1 Default estimate (OQ-E8-7 default)

```elixir
@default_hours %{1 => 1, 2 => 2, 3 => 4, 4 => 7, 5 => 11}   # J:94
@spec default_hours(1..5 | nil) :: pos_integer() | nil
def default_hours(cx) when is_map_key(@default_hours, cx), do: Map.fetch!(@default_hours, cx)
def default_hours(_), do: nil
```

`nil` complexity (missing, invalid or ambiguous labels) gives `nil`, never a
guessed tier.

### 4.2 Override store (PROPOSED `Aiur.BuildOrder.Estimates`, one GenServer)

- **Key:** the issue number (positive integer). Only filed tickets can be
  overridden; `pack:` rows (C7-T02) take the default only.
- **Record:** `%{hours: number, reason: String.t(), by: String.t(), at: DateTime.t()}`.
- **Journal:** each ticket keeps its last 20 writes, newest first, as
  `%{op: :set | :clear, hours: number | nil, reason, by, at}`. ponytail: 20 is
  plenty for a planning correction; raise it if a census finds a ticket near it.
- **Writes are serialised** through the GenServer. Two writers on one ticket:
  the later call wins and both are in the journal (EC-13). A write that changes
  nothing (same hours and reason) is still journaled, because the actor and time
  are the record, but does not bump the generation.
- **File:** `<build_estimates_state_dir>/estimates.json`, mode `0600`, written
  with `Fs.atomic_write/3` on every write (no debounce: writes are rare and the
  CLI must not report success before the data is on disk).

```json
{"version": 1, "repository": "owner/name", "generation": 7,
 "tickets": {"2412": {"override": {"hours": 7, "reason": "…", "by": "cli:kevin", "at": "2026-10-08T09:00:00Z"},
                      "journal": [{"op": "set", "hours": 7, "reason": "…", "by": "cli:kevin", "at": "…"}]}}}
```

- **Health** (`ProviderHealth`):

| Situation | Health | `overrides/0` | Writes |
| --- | --- | --- | --- |
| No file | `:healthy`, `complete?: true` | `{:ok, %{}}` | accepted |
| File loaded | `:healthy`, `complete?: true` | `{:ok, map}` | accepted |
| Corrupt JSON or bad shape | `:unavailable`, `:estimates_corrupt`; file quarantined (`Fs.quarantine/1`) | `{:error, health}` | refused, `{:error, :estimates_unavailable}` |
| `version` > 1 | `:unavailable`, `:version_unsupported`; file untouched | `{:error, health}` | refused |
| `repository` differs from config | `:unavailable`, `:repository_mismatch`; file untouched | `{:error, health}` | refused |
| Symlink, non-regular file, or over 1 MB | `:unavailable`, `:estimates_unsafe_path` | `{:error, health}` | refused |
| State dir unresolvable | `:unavailable`, `:state_dir_unavailable` | `{:error, health}` | refused |
| Write fails (disk full) | unchanged | as before | `{:error, :write_failed}`; memory is not changed |

  A corrupt store refuses writes (unlike C4-T01's history, which rebuilds from
  GitHub): overrides cannot be rebuilt, and a fresh empty file would silently
  drop them. Recovery is manual: restore or delete the quarantined file, then
  restart. The CLI message says this.

- **Signal:** topic `"build-estimates:changed"`, message
  `{:build_estimates_changed, %{generation: g, changed: [number]}}`, guarded on
  `Process.whereis(Aiur.PubSub)` as `pack_status.ex:226-232` does.

```elixir
@spec put(pos_integer(), number(), String.t(), String.t(), keyword()) :: {:ok, record()} | {:error, term()}
@spec clear(pos_integer(), String.t(), String.t(), keyword()) :: {:ok, :cleared | :absent} | {:error, term()}
@spec get(pos_integer(), keyword()) :: {:ok, %{override: record() | nil, journal: [entry()]}} | {:error, ProviderHealth.t()}
@spec overrides(keyword()) :: {:ok, %{pos_integer() => record()}} | {:error, ProviderHealth.t()}
@spec health(keyword()) :: ProviderHealth.t()
@spec subscribe() :: :ok
```

### 4.3 Resolver (row fields)

```elixir
# called by C8-T04 for every plan and now row, once per assembly
@spec resolve(row :: %{num: pos_integer() | nil, cx: 1..5 | nil}, overrides :: map() | :unavailable) ::
        %{est: number() | nil, override: map() | nil}
def resolve(_row, :unavailable), do: %{est: nil, override: nil}
def resolve(%{num: n, cx: cx}, ovr) do
  %{est: default_hours(cx), override: n && json_override(Map.get(ovr, n))}
end
```

- `est` stays the **default**, and `override` carries the override. Both are
  sent so the modal and the cue can say "bumped from 2h" without a second read,
  and the design's `t.override ? t.override.hours : t.est` works unchanged.
- An override applies even when `cx` is unknown: `est: nil`,
  `override.hours: 6` renders "≈6h". The recorded value is known.
- **Store unavailable → `est: nil` for every row** and `sources.estimates`
  `unavailable`. Showing the table value would claim "no override" when the
  store cannot say (AGENTS.md "Unknown is never zero").
- History rows get no `est` (C3-T02: "`est` only on now and plan rows").
- An override on a ticket that later starts running stays on its `now` row.
  The design's band height (J:493) reads `t.est` only; C9-T09 uses
  `estHours(t)` there (its decision 3), so the override also sets the band
  height. With a `null` estimate, `t.est * pphG` would be `NaN`; C9-T09 uses
  its fallback height.
- On a `now` row `est` is the table value. The design's running estimate
  (J:255, from elapsed time and progress) is mock data, as for planned rows.

### 4.4 Payload additions (owned here by C3-T02's extension rule)

- `"capacity": { "max": int | null, "observed_at": ms | null, "stale": bool }`,
  from the orchestrator snapshot's `capacity.max` through the
  `presenter.ex:476-486` rule (positive integer, else `null`). `stale` is true
  when `dashboard_snapshot/2` returns `:stale`; `max` is `null` on
  `:snapshot_unpublished` and `:orchestrator_unavailable`. Also a key of the
  diff `set` map, so `aiur set max-agents` updates the ETA live.
- `"sources.estimates"`, the same `{state, observed_at, reason}` shape as the
  other `sources` entries (C3-T02 snapshot schema): `ok` when the store is
  healthy, `unavailable` with the health `failure` atom as `reason` otherwise.
- Validator clauses: `capacity.max` is a positive integer or `null`;
  `observed_at` an integer or `null`; `stale` a boolean; no other keys.
  `sources` gains `estimates` as a required key.
- Fixture mapping (C3-T02 step 5): every fixture gets `capacity: {max: 4,
  observed_at: NOW, stale: false}` and `sources.estimates: ok`, so the fixture
  ETA equals the design's `/ 4` figure.

### 4.5 Client helpers (PROPOSED `src/priv/static/build-home/estimate.js`)

`etaLabel(D)` reads `D.plan`, `D.now`, `D.sources` and `D.capacity`. C9-T08's
`bandEta(D)` already reads `D.sources.queue`; C9-T01's `intake` keeps
`D.sources` and `D.capacity`.

```js
export const estHours = (t) => t.override ? t.override.hours : (t.est ?? null);   // J:516, 859, 1161, 1435
export const estLabel = (t) => { const h = estHours(t); return h == null ? "—" : "≈" + h + "h"; };
export function etaLabel(D) {                                                     // J:667
  const q = D.sources.queue.state;            // "ok" | "stale" | "incomplete" | "unavailable" | "disabled"
  const part = q === "incomplete" ? "≥" : "";  // a partial queue gives lower bounds
  const toGo = q === "unavailable" ? "—" : part + String(D.plan.length + D.now.length);
  const cap = D.capacity && D.capacity.max;
  const hs = D.plan.map(estHours), known = hs.filter((h) => h != null);
  let eta = "—", title = "";
  if (q === "unavailable") title = "Queue unavailable";
  else if (!D.plan.length) title = "";                                         // design: "—"
  else if (!cap) title = "Agent cap unknown";
  else if (D.sources.estimates && D.sources.estimates.state === "unavailable") title = "Estimates unavailable";
  else if (!known.length) title = "No planned ticket has an estimate";
  else {
    const h = Math.max(1, Math.round(known.reduce((s, x) => s + x, 0) / cap));
    const miss = hs.length - known.length;
    eta = (miss || part ? "≥" : "") + h + "h";
    title = (miss ? miss + " planned without an estimate · " : "") + "at " + cap + " agents";
  }
  return { text: toGo + " to go · ETA " + eta, title };
}
```

Rendering rules for the sites other tickets port:

| Site | Known | Unknown (`estHours` is `null`) |
| --- | --- | --- |
| Card status, J:860 | `≈7h · 2 pts` | `— · 2 pts` (pts unknown is C9-T05's) |
| List row, J:1161 | `Q4 · W2 · ≈7h` | `Q4 · W2 · —` |
| Modal fact, J:1435 | `≈7h` | `—` (no `EST[cx-1]` fallback) |
| Gantt planned height, J:516 | `hours * pph` | the existing minimum (`span > 2 ? 4 : CH.mini / CH.line`), as S-5 does for unknown start; C9-T09 owns it |
| Band Gantt height, J:493 | `estHours(t)` in place of `t.est` | C9-T09's fallback height (never `NaN`); C9-T09 owns it |
| Override cue, J:857 / J:1426 | shown when `t.override` | not shown |
| `.bd-now-eta`, J:667 | `etaLabel(D).text`, `title` attribute set | as the function returns |

The `title` attribute is new on `.bd-now-eta`. It changes no pixels.

### 4.6 CLI

```text
aiur ticket estimate <id>                                  show default, override and journal
aiur ticket estimate <id> <hours> --reason <text> [--by <who>] [--json]
aiur ticket estimate <id> --clear --reason <text> [--by <who>] [--json]
```

- Engine (`cmd_ticket` → `estimate`) validates shape and exits 64 on: a
  non-numeric id; hours that are not a multiple of 0.25 in `0.25..999`; a missing
  or blank `--reason` on a write; `--clear` with hours; an unknown option; `--by`
  outside `^[A-Za-z0-9._:@-]{1,64}$`. Hours must match
  `^[0-9]{1,3}(\.(0|00|25|5|50|75))?$` and be greater than 0 (so `0.25..999`).
  `--by` defaults to `cli:$USER`. The id and hours pass the digit checks first
  and go into the RPC as literals (`id: 5, hours: "7"`), as `cmd_build_orders`
  never needs to escape a checked value; `--reason` and `--by` go base64
  through `encode_control_value` (`:2861-2863`).
- RPC `Aiur.AgentControlCLI.ticket_estimate/1` (through `guarded/2`) calls
  PROPOSED `Aiur.BuildOrder.EstimateCLI.run/1`, which re-validates everything
  (the daemon is the trust boundary; reason trimmed, 1..500 characters, control
  characters other than space rejected).
- Output: `#2412 estimate ≈7h (override by cli:kevin, 2026-10-08 09:00; default
  ≈2h from complexity:2). Reason: …`. With `--json`, the record plus
  `default_hours` and `planned: true | false | "unknown"` (from C7-T01's planned
  rows; `"unknown"` when the queue is unavailable). Setting an override on a
  ticket that is not planned succeeds and says "not planned now; no card shows
  it until it is queued".
- Exit codes: 0 success; 1 refused (store unavailable, validation); the
  engine's existing timeout path reports "outcome is unknown"
  (`aiur-engine.sh:2470`), and the user re-runs `aiur ticket estimate <id>` to
  read the result.

## 5. Implementation steps

1. `Aiur.Config.Paths.build_estimates_state_dir/0`: a copy of
   `progress_retention_state_dir/0` (`paths.ex:99-110`), app-env key
   `:build_estimates_state_dir`, leaf `build-estimates`. Add a case to
   `test/aiur/config_paths_test.exs`.
2. PROPOSED `lib/aiur/build_order/estimates.ex`: `default_hours/1`,
   `resolve/2`, the GenServer and file code of §4.2 (load with `File.lstat`,
   regular-file and 1 MB checks, `Jason.decode`, shape validation, quarantine on
   corrupt; `Fs.atomic_write(path, json, mode: 0o600)` before the state is
   replaced). About 200 lines.
3. Add `Aiur.BuildOrder.Estimates` to the tree in `lib/aiur.ex` next to C4-T01's
   History child (before `:452`).
4. PROPOSED `lib/aiur/build_order/estimate_cli.ex` (`run/1`, human and JSON
   output) and `AgentControlCLI.ticket_estimate/1` next to `build_orders/1`
   (`agent_control_cli.ex:376`).
5. `aiur-engine.sh`: `cmd_ticket` (dispatches `estimate`, rejects other
   subcommands with exit 64), the `ticket)` case next to `build-orders)`
   (`:4234`), the help line next to `:466`.
6. Assembler hook-up (C8-T04's module, merged before this ticket): add the
   `"build-estimates:changed"` subscription; read `Estimates.overrides/0` once per assembly, call
   `resolve/2` for plan and now rows, fill `sources.estimates` and `capacity`,
   and emit a diff for `changed` rows on `{:build_estimates_changed, …}` and a
   `set.capacity` diff on the poll-state broadcast (`status_report.ex:177-181`
   `AgentPubSub.broadcast_poll_state/1`, which carries `max_concurrent_agents`
   from `Slots.max_concurrent_agent_limit/1`). In C3-T02's `payload.ex`, add
   the §4.4 validator clauses, `capacity` to the diff `set` keys, and the
   fixture mapping; regenerate the five fixtures and `hostile.json`.
7. `estimate.js` (§4.5) and its use at the five sites. The ports (C9-T05,
   C9-T08, C9-T09, C9-T12, C11-T02) have merged with interim `—` / `ETA —`
   sites; replace each with the helper. Replace C9-T08's `bandEta(D)`
   placeholder with `etaLabel(D)` and delete its `.bd-now-eta` parity
   allowlist entry ("pending: removed by C7-T03").
8. `website/docs-app/reference/cli.md`: add `ticket estimate` to the "Act on
   durable records" row (`:31`) and a short "Ticket estimates" subsection under
   "Decisions, Executor events, and findings" (`:241`) (syntax, the 0.25-hour rule, the reason rule, the
   journal, the "outcome unknown" re-read).

## 6. Non-happy paths

| Input or state | Expected behaviour | Test |
| --- | --- | --- |
| Planned row, no `complexity:` label, no override | `est: null`, `override: null`; card `— · pts`; modal `—` | E-1, J-2 |
| Two `complexity:` labels (`complexity:2`, `complexity:4`) | `cx: nil` from `Metadata.parse/1` → `est: null` (not 7 from the max) | E-2 |
| Queue `incomplete` | "≥N to go · ETA ≥Mh" | J-9 |
| Store unavailable, cap known | "ETA —", title "Estimates unavailable" | J-10 |
| Override on a ticket with unknown complexity | `est: null`, `override.hours: 6` → "≈6h" | E-3, J-1 |
| Store file corrupt | file quarantined; rows `est: null`; `sources.estimates.state: "unavailable"`; CLI write exits 1 with "estimate store unavailable (estimates_corrupt); restore or remove <path>.corrupt-*, then restart" | S-3, C-4 |
| Store file from a newer release | not touched; reads and writes refused | S-4 |
| Disk full on write | CLI exits 1; `get/1` returns the old value; journal unchanged | S-5 |
| Two writers at once (CLI in two shells) | both succeed in order; the later is the override; both in the journal | S-6 (EC-13) |
| Daemon restart | overrides reload from the file | S-2 |
| Orchestrator snapshot unpublished or unavailable | `capacity.max: null` → "ETA —", title "Agent cap unknown" (never ÷4) | J-4 |
| Cap changed with `aiur set max-agents 8` | `set.capacity` diff; ETA re-rendered without a reload | J-5, L-1 |
| Some planned rows without estimates | "ETA ≥Nh", title names the count | J-3 |
| Queue unavailable | "— to go · ETA —" | J-6 |
| Queue disabled | "<now count> to go · ETA —" | J-6 |
| Small plan, Σ/cap < 0.5 (one 1 h ticket, cap 20) | "ETA 1h", not "0h" | J-7 |
| Reason with HTML (`" onmouseover="window.__xss=1`) | stored raw; escaped by `esc` in `title` (J:857) and the cue (J:1426) | J-8 (C3-T02 already has this fixture string) |
| Reason with a newline or other control character | refused, exit 64 in the engine and `{:error, :invalid_reason}` in the daemon | C-2, E-6 |
| Hours `0`, `-1`, `2.3`, `1000`, `abc` | exit 64; the daemon also refuses when called directly | C-1, E-6 |
| Id of a closed or unknown issue | stored (harmless); output says "not planned now" | C-3 |
| CLI timeout | engine prints "outcome is unknown"; re-run the show form | existing engine path |
| Read-only dashboard (EC-12) | no estimate write exists on the page; nothing to hide | — |

Privacy: reasons and actor names are operator text shown to dashboard viewers;
no tokens or paths are stored. The file is `0600` in the daemon-private state dir.

## 7. Compatibility and rollout

- New file only; no migration. An install without the file has no overrides.
- No config key is added. The cap comes from `agent.max_concurrent_agents` (or
  its host default, or the session override) through the existing snapshot.
- The CLI is additive in the shared engine, so `aiur` and `aiurdev` gain it
  together.
- Rollback: drop the release. The `estimates.json` file is ignored by older
  builds; a later re-install reads it again.
- The page change ships with the home page cutover (C12-T01); before that, the
  helpers are exercised only by fixtures and unit tests.

## 8. Verification

ExUnit (PROPOSED `test/aiur/build_order/estimates_test.exs`, `async: false`,
state dir from `tmp_root!/1` per `test/support/test_support.exs:167`):

| # | Test | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| E-1 | "unknown complexity has no estimate" | `resolve(%{num: 5, cx: nil}, %{})` → `%{est: nil, override: nil}` | `default_hours(_)` returning `1` or `cx \|\| 1` |
| E-2 | "two complexity labels give no estimate" | through the step-6 assembler hook with a stub queue: one planned issue labelled `complexity:2` and `complexity:4` → its row has `est: nil` | the hook deriving `cx` with `CodingAgent.complexity_level/1` instead of the row's `cx` (gives 7) |
| E-3 | "override applies without complexity" | `cx: nil` + override 6 → `override.hours == 6`, `est: nil` | `resolve/2` skipping overrides when `est` is nil |
| E-4 | "table by tier" | cx 1..5 → 1, 2, 4, 7, 11 | any swapped or mistyped entry |
| E-5 | "store unavailable hides defaults" | `resolve(%{num: 5, cx: 3}, :unavailable)` → `est: nil` | the `:unavailable` clause returning the default |
| E-6 | "daemon validates input" | `put(5, 0, …)`, `put(5, 2.3, …)`, blank reason, reason with `\n`, `by` with a space → each `{:error, _}`, file unchanged | removing any one guard |
| S-1 | "put then get" | record and a one-entry journal; file mode `0600` | — (round trip; guards the format) |
| S-2 | "reload after restart" | stop and start the server on the same dir → same override | reading from memory only |
| S-3 | "corrupt file is quarantined and refuses writes" | write `"{not json"` → `overrides/0` is `{:error, %ProviderHealth{state: :unavailable, failure: :estimates_corrupt}}`; a `estimates.json.corrupt-*` file exists; `put/5` → `{:error, :estimates_unavailable}` | returning `{:ok, %{}}` on corrupt load (the test gets `{:ok, …}` and fails) |
| S-4 | "newer version left alone" | `version: 2` → unavailable; file bytes unchanged | treating it as corrupt and quarantining |
| S-5 | "failed write keeps the old value" | inject a write function that returns `{:error, :enospc}` → `{:error, :write_failed}`; `get/1` returns the previous record | updating state before the write |
| S-6 | "concurrent writers are journaled" | 2 tasks `put(5, 3, …)` and `put(5, 9, …)` → journal has 2 entries with hours `{3, 9}`; the override equals the journal head (whichever ran last) | replacing the journal instead of prepending |
| S-7 | "journal is capped at 20" | 25 writes → 20 entries, newest first | no cap |
| S-8 | "change is broadcast" | subscriber gets `{:build_estimates_changed, %{changed: [5]}}` after `put` | no broadcast |
| V-1 | "capacity is validated" (in C3-T02's `test/aiur_web/build/payload_test.exs`) | `live` fixture with `capacity.max: 0`, then with `capacity.max: "4"` → `{:error, [{[:capacity, :max], _}]}`; `capacity.max: nil` → `:ok` | deleting the `capacity` clause |
| V-2 | "sources.estimates is required" | `live` fixture without `sources.estimates` → `{:error, [{[:sources, :estimates], _}]}` | leaving `estimates` out of the required `sources` keys |
| V-3 | "snapshot capacity follows the orchestrator" | assembler hook with a stub snapshot `{:current, %{capacity: %{max: 8}}, _}` → `capacity.max == 8, stale == false`; `:snapshot_unpublished` → `capacity.max == nil` | a hook that falls back to `Config.max_concurrent_agents/0` (gives a number) |

Engine (`test/aiur_engine_test.exs`, the `run_sourced_engine` pattern at
`:1388-1401`):

| # | Test | Expected |
| --- | --- | --- |
| C-1 | "ticket estimate rejects bad hours" | `cmd_ticket estimate 5 2.3 --reason x` → exit 64, message names the 0.25 rule; same for `0`, `1000`, `abc` |
| C-2 | "ticket estimate needs a reason" | missing or blank `--reason` → 64; `--clear 3` → 64 |
| C-3 | "ticket estimate routes through the control rpc" | stub prints `RPC:Aiur.AgentControlCLI.ticket_estimate([id: 5, hours: "7", reason: Base.decode64!("…"), by: Base.decode64!("…")])` |
| C-4 | "unknown ticket subcommand" | `cmd_ticket frob` → 64 |

`AgentControlCLI` (`test/aiur/agent_control_cli_test.exs`): C-5 the human line
and the JSON shape, C-6 a store-unavailable refusal prints the recovery
message on the error marker and exits 1.

JS (PROPOSED `src/browser/tests/build-home-estimate.test.mjs`, `node --test`,
npm script `test:build-home-estimate` added to the `test` chain):

| # | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| J-1 | `{est: null, override: {hours: 6}}` | `estLabel` → `≈6h` | override ignored when `est` is null |
| J-2 | `{est: null, override: null}` | `—` | `t.est ?? 0` or `EST[cx-1]` fallback |
| J-3 | plan est `[4, 7, null]`, cap 4 | `"3 to go · ETA ≥3h"`, title starts "1 planned without an estimate" | `?? 0` in the sum (gives `ETA 3h` without `≥`) |
| J-4 | plan `[4, 4]`, `capacity.max: null` | `ETA —`, title "Agent cap unknown" | `cap \|\| 4` (gives `2h`) |
| J-5 | plan Σ = 40, cap 4 then cap 20 | `ETA 10h`, then `ETA 2h` | the design's constant `/ 4` (second case gives 10h) |
| J-6 | queue `unavailable`; queue `disabled` with 2 now rows | `— to go · ETA —`; `2 to go · ETA —` | treating unavailable as empty (`0 to go`) |
| J-7 | plan `[1]`, cap 20 | `ETA 1h` | plain `Math.round` (gives `0h`) |
| J-8 | `hostile.json` override reason `" onmouseover="window.__xss=1` | `estLabel` and `etaLabel(...).text` never contain the reason text (the helpers never touch it) | a helper that appends the reason |
| J-9 | queue `incomplete`, plan `[4, 4]`, cap 4 | `"≥2 to go · ETA ≥2h"` | ignoring `incomplete` (gives `2 to go · ETA 2h`) |
| J-10 | plan `[null, null]`, cap 4, `sources.estimates.state: "unavailable"` | `ETA —`, title "Estimates unavailable" | dropping the estimates branch (title becomes "No planned ticket has an estimate") |

Escaping the reason at J:857 and J:1426 belongs to the card and modal ports
(C9-T05, C11-T02), which run the `hostile.json` fixture; when either has
merged, L-1 also asserts `window.__xss` is undefined on the `hostile` fixture.

Live check L-1 (browser spec against the fixture server, PROPOSED
`src/browser/tests/build-home-estimate.browser.spec.mjs`): load `live`, push a
`set.capacity` diff from 4 to 8 through the fixture control route (C3-T02 step
6), assert `.bd-now-eta` text changes from the 4-agent value to the 8-agent
value without a reload.

Commands (isolated HOME, no GitHub tokens, per the "mix test clobbers
agent-token" note; run from a worktree):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/estimates_test.exs test/aiur/config_paths_test.exs \
  test/aiur_engine_test.exs test/aiur/agent_control_cli_test.exs \
  test/aiur_web/build/payload_test.exs
env -C src/browser npm run test:build-home-estimate
env -C src/browser node scripts/run-browser-tests.mjs tests/build-home-estimate.browser.spec.mjs
env -C src/browser npm run test:design-parity
```

Mutation check (AGENTS.md): in a worktree, apply each mutation in the tables,
confirm `git status --porcelain` shows only that hunk, run the named test, see it
fail, restore, see it pass. Record the commands in the PR body.

Manual check (AGENTS.md "Manual testing"): with `aiurdev --test` running, run
`aiurdev ticket estimate <a planned sandbox ticket> 9 --reason "manual check"`
and confirm on the home page that the card shows `≈9h`, the dashed
`estimate overridden` chip with the reason as its tooltip, the modal cue, and a
changed ETA; then `aiurdev set max-agents 2` and confirm the ETA doubles. Then
`--clear` and confirm the chip goes away.

## 9. Pixel parity

Design elements reproduced: `.bd-q.ovr` with the pencil icon (J:55, 857;
C:252–256), `.bm-cue` with the pencil (J:1426; C:592–594), `.bd-now-eta`
(J:667; C:390, 393, 1103), the "Estimate" fact (J:1435; C:596–598), the
`≈Nh` text in `.bd-status` (J:860) and `.lr-mu` (J:1161).

How parity is checked (C1-T02 harness, same fixture data and frozen clock on
both sides):

- `npm run test:design-parity` on the `live` fixture, dark and light, default
  and Gruvbox: the planned section in full detail (where `p11` carries the
  override chip), the minimised and expanded Live band header, and the modal of
  `p11` open. Zero diff outside the allowlist.
- The fixture's ETA must equal the design's: this ticket's fixture mapping
  adds `capacity: {max: 4}` (§4.4), so `Math.round(Σ/4)` and the product's
  `Math.max(1, Math.round(Σ/cap))` give the same text for the design data
  (Σ/4 ≥ 1 in every design fixture except `noqueue`, whose plan is empty and
  shows "—" on both sides).
- The container query at 560 px hides `.bd-now-eta` on both sides (the phone
  viewport cell of `parity:matrix`).
- New states that the design has no picture of (`ETA —` for unknown cap, `≥`,
  `—` estimates) render in the existing elements with no new style. They are
  shown in the C12-T08 sign-off package and listed in §10.

## 10. Decisions made without the owner

1. **Default estimate = the design table** `[1,2,4,7,11]` (OQ-E8-7 default,
   plan §10 item 10). The design's jitter is mock data and is not ported.
2. **ETA divisor = the runtime cap `max`** from the orchestrator snapshot
   (session override, then config, then the host default), not the raw config
   key and not the load-adjusted `effective` value. Reason: `aiur set
   max-agents` is how an operator changes the cap, and `effective` moves with
   host load every few seconds. Plan §10 item 9 says
   `agent.max_concurrent_agents`; `max` is that key when it is set.
3. **The ETA keeps the design's formula** (planned rows only; running rows count
   in "to go" but add no hours). Adding the running tickets' remaining time would
   be a forecast, which decisions.md leaves open.
4. **CLI only; no agent-workspace tool.** E8-D7 names "the Executor's planning
   agent", which runs where the CLI runs. Agent workspaces reach the daemon only
   through dynamic tools (`dynamic_tool.ex:15`); adding one is a separate
   decision. C5-T03 has the same question for epics; if it adds a tool, an
   `estimate` handler can follow the same path.
5. **Separate store, not C5-T03's epic registry.** C5-T03 is not a predecessor
   and may land in parallel. Both copy the same file pattern; if they land in
   the same release, a follow-up may merge them.
6. **Unknown estimate renders "—"** on cards, list rows and the modal, and a
   corrupt store makes every estimate unknown rather than showing defaults.
7. **Partial sum renders "≥Nh"** with a count in the tooltip; no known estimate,
   no cap, or an unavailable queue renders "—". S-29 in
   DESIGN-E8 (§11).
8. **An ETA below 1 hour renders "1h"**, so known work never reads "0h".
9. **Hours are multiples of 0.25 from 0.25 to 999**, matching the design's
   quarter-hour rounding (J:261) and keeping the "≈Nh" text short.
10. **`--clear` and the show form are included.** Without `--clear`, the only
    way back to the default would be an override equal to it, which still shows
    "estimate overridden".
11. **A reason is required for `--clear` too**, because the journal is the
    record E8-D7 asks for.
12. **The CLI accepts an override for a ticket that is not planned** and says
    so, so a planner can set it before the ticket is queued.
13. **Running rows use the table estimate**, not the design's elapsed-time
    estimate (J:255), which is mock data. A running-estimate model would be a
    forecast (decision 3).
14. **An `incomplete` queue prefixes "≥"** to both "to go" and the ETA, because
    both are lower bounds; `stale` shows the numbers as they are (C9-T13 owns
    the stale styling).
15. **A store-unavailable ETA says "Estimates unavailable"**, not "No planned
    ticket has an estimate", so the tooltip names the real cause (AGENTS.md
    "A collapsed cause names the collapse at the source").

## 11. Completion and handoff

Acceptance:

- [ ] `default_hours/1`, `resolve/2` and the store exist with the API in §4.2–4.3.
- [ ] Plan and now rows carry `est` and `override` from the resolver;
      `sources.estimates` and `capacity` are in the snapshot and the diff `set`.
- [ ] `aiur ticket estimate` works in all three forms, with the validation in §4.6
      in both the engine and the daemon.
- [ ] `estimate.js` is used at all five sites; no `EST[` fallback and no `/ 4`
      remain in the ported code.
- [ ] Every test in §8 passes, and each mutation listed makes its test fail.
- [ ] `test:design-parity` shows zero new diff for the elements in §9, and
      C9-T08's `.bd-now-eta` allowlist entry is gone.
- [ ] `Payload.validate/1` accepts the new keys in every fixture and rejects
      `capacity.max: 0` and a missing `sources.estimates`.
- [ ] The manual check in §8 was run and its captures are in the PR.
- [ ] `reference/cli.md` documents the command.

Interface requests (for the Executor; this ticket does not edit those files):

- **C3-T02:** Settled 2026-10-08: `capacity` and `sources.estimates` are in its
  additive table. Its extension rule already assigns `capacity` and
  `sources.estimates` to this ticket, which adds the validator clauses, the
  `set` key and the fixture mapping itself (§4.4, step 6).
- **C8-T04:** Settled 2026-10-08: C7-T03 lands after C8-T04 and adds
  `"build-estimates:changed"` and the poll-state topic to the assembler in its
  own PR (§5 step 6).
- **C8-T01:** Settled 2026-10-08: `est` on now rows comes from the C8-T04 join
  that this ticket wires (`resolve/2`).
- **C9-T05, C9-T08, C9-T09, C9-T12, C11-T02:** Settled 2026-10-08 (R-G12): they
  ship interim `—` / `ETA —` sites (never `EST[t.cx - 1]` or Σ/4); this ticket
  replaces them with `estHours`/`estLabel`/`etaLabel` at J:860, 667, 516, 1161
  and 1435.
- **C9-T08:** Settled 2026-10-08: this ticket replaces `bandEta` with `etaLabel`
  and drops the ETA allowlist entry.
- **DESIGN-E8:** S-29, "Planned estimate and ETA unknown or partial":
  default "—" and "≥Nh" in the existing elements (decisions 6–8).

Dependents: C5-T04 (skill text for the command and the "strong reason" rule),
C12-T07 (docs pass; this ticket already writes the `cli.md` entry).

Sources: plan.md §8 (EC-08, EC-13), §10 items 9–10; decisions.md E8-D3, E8-D4,
E8-D7; questions.md OQ-E8-7; tickets/README.md C7-T03 row; MP-E8-C3-T02 row
schema; MP-E8-C4-T01 store pattern; design-source J/C/H lines cited above.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, design-source and the
neighbour tickets. All cited code symbols and line numbers were opened; the
design values (J, C, H lines) match. Changes:

1. Ownership of `capacity` and `sources.estimates`: C3-T02's extension rule
   already assigns them to this ticket, so the "request to C3-T02" and the
   C1-T01 fixture request were wrong. Moved the validator clauses, `set` key
   and fixture mapping into this ticket (deliverable 6, §2, §4.4, step 6, §9,
   §11) and added tests V-1..V-3.
2. J:493 claim fixed: the design's band height reads `t.est` only; C9-T09 owns
   the `estHours` change there. Added the J:493 row to the rendering table.
3. C9-T08 handoff: this ticket replaces its `bandEta` placeholder and deletes
   its `.bd-now-eta` allowlist entry (§2, step 7, acceptance).
4. `etaLabel`: stated which `D` fields it reads; added the `incomplete` queue
   (`≥`) and the store-unavailable title; tests J-9, J-10; decisions 14, 15.
5. Engine encoding made consistent with test C-3 (id and hours as checked
   literals, reason and by base64); gave the exact hours regex.
6. `cli.md` placement: a write command goes in "Act on durable records" and
   the Decisions section, not the read-only "Dashboard page commands".
7. E-2 rewritten to run through the assembler hook; the old form only
   re-tested E-1 and could not fail on the stated mutation.
8. S-6 made deterministic (two tasks have no fixed order).
9. J-8 rescoped: escaping is C9-T05/C11-T02 code; this ticket asserts the
   helpers never carry the reason, and L-1 checks `hostile` once a port exists.
10. Small citation fixes: `lifecycle.ex:1-62`, `status_report.ex:177-181`;
    decision 13 for running-row estimates.
- Reconciliation 2026-10-08 (coordinator): §2 lists the new R-G12 predecessors (C8-T04, C9-T08, C9-T09, C9-T12, C11-T02), steps 6-7 assume the ports merged with interim sites, C9-T01 intake keeps D.sources/D.capacity, acceptance drops the not-merged branch, interface requests marked settled, S-18 -> S-29.
