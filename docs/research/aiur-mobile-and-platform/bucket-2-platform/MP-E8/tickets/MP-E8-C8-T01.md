---
ticket_id: MP-E8-C8-T01
feature_id: MP-E8
chunk_id: MP-E8-C8
bucket: 2-platform
title: Now-band rows and agent-state mapping
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-05, EC-08]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C8-T01 — Now-band rows and agent-state mapping

> **Wave 0b, server data.** Paths are cited at `58854d4c8` in
> `aiur-worktrees/runtime/src`. Paths marked PROPOSED do not exist yet.
> `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`.
> This ticket draws nothing on the board. It turns the existing per-ticket Units
> row into the agent-owned fields of a v1 `now` row, and it ships the two small
> client rules (unknown progress, unknown state) that every now-row renderer
> must call.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C8 (live state,
  usage, daemon status, ticket index).
- **User value.** The live band shows every agent the orchestrator reports, with
  the right model logo, the right one of the design's six states, and its real
  progress. An agent whose state, model or progress is not known shows as
  unknown. It never shows as "Running", as Claude, as 0 % or as the amber
  "early progress" hue.
- **Deliverables.**
  1. PROPOSED `src/lib/aiur_web/build/now_rows.ex`, `AiurWeb.Build.NowRows`: a
     pure function from the Units catalog (`UnitsPresenter.load/2` output) to
     the agent-owned fields of each now row, plus the `sources.agents` block.
  2. The agent-state table below, as code and as the moduledoc (one copy).
  3. Three additive rules in `AiurWeb.Build.Payload` (C3-T02's validator):
     `agent.model` may be `null`; `agent.name` (string or `null`, the key
     C3-T02's extension table assigns to this ticket); the `effort` enum is the
     product's vocabulary. Plus the matching change to C3-T02's fixture mapping
     (`mapRawToPayload`) so the five fixtures carry `agent.name`. See
     "Interface changes to C3-T02".
  4. PROPOSED `src/priv/static/build-home/now-state.js`: the design's `AST`
     constant (J:88–91, verbatim), `UNKNOWN_STATE`, `agentState(state)`,
     `progress(pct)` and `modelLabel(agent)`, with a Node test. This is the one
     copy of `AST` on the client. C9-T05, C9-T06, C9-T08, C9-T11, C9-T12,
     C10-T02 and C11-T01 import these instead of reading `AST[...]`,
     `MODELS[...]` or `t.pct` directly (see "Interface notes").
  5. A public predicate `Aiur.Orchestrator.State.non_reserving_pause_reason?/1`
     over the existing `@non_reserving_pause_reasons` (`state.ex:738`), so the
     "parked" rule is the orchestrator's own definition, not a copy.
- **Non-goals.**
  - Title, type, epic, feature, `also`, `cx`, `pts`, `created`, `deps`, `pr`
    and `est`. C8-T04 joins them from History (C4), the epic resolver (C5),
    features (C6) and estimates (C7-T03 `resolve/2`, which needs `cx`, a field
    this module does not have; D12).
  - Subscriptions and diffs. C8-T04 subscribes to `AgentPubSub` running and
    calls this function again.
  - Any drawing: logos and glows (C9-T06), cards (C9-T05), the band and its
    empty state (C9-T08), the unavailable state (C9-T13).
  - Daemon liveness and offline mode (C8-T03).
  - Any orchestrator behaviour change. The predicate in deliverable 5 only reads
    an existing list.

## Dependencies and blockers

- **Blocked by DESIGN-E8.** Two defaults below are new design gaps, S-31
  (unknown agent state, unknown progress). They follow the written
  defaults in "Decisions made without the owner"; DESIGN-E8 sign-off may change
  the copy. They do not block this ticket (tickets/README.md rules).
- **Predecessor: MP-E8-C3-T02.** It owns the v1 row schema, `Payload.row/1`
  and `Payload.validate/1`, and the regenerated `live` fixture that the parity
  test reads. This ticket adds three rules to that validator.
- **Owner questions.** S-13 (logo for a model the design lacks) is a rendering
  default for C9-T06; this ticket only sends the key. S-4 (no visible state
  glyph) is C9-T06's. OQ-E8-10 (messaging a parked agent) does not change the
  mapping: a parked agent is still `parked`.
- **Successors.** C8-T04 (joins these fields into full rows), C9-T05 (cards),
  C9-T06 (logo and glow), C9-T08 (band header counts and empty state), C9-T11
  (tree nodes, J:1210), C9-T12 (list rows, J:1160), C10-T02 (Model and Agent
  filters), C11-T01 (modal header, J:1376–1392).
- **May run concurrently with** C8-T02, C8-T03 and all of C4–C7. No shared
  files except `payload.ex` (C8-T02 and C8-T03 also add rules there; merge in
  any order, the rules are independent).

## Verified starting point (`58854d4c8`)

**Units row (the one per-ticket truth for live agents).**

- `lib/aiur_web/operator_control_center/units_presenter.ex:15-54` `load/2`
  reads membership, TicketActivity, the fleet status and decisions, calls
  `UnitsRow.snapshot/1` (`:38-44`) and returns `%{status, message, truncated?,
  snapshot}`. `message` is operator prose (`catalog_message/3`, `:370-379`,
  for example "Fleet data is unavailable."), not a code. `status` is `catalog_status/1` (`:302-321`):
  `:ready | :empty | :stale | :unavailable`. A degraded or old fleet view is
  `:stale`, never `:ready` (comment at `:316-319`).
- `units_presenter.ex:287-291` `fleet_source_freshness/2` carries
  `observed_at` and `age_seconds` from the fleet `snapshot_freshness`. The
  presenter sets `snapshot_freshness` only when the fleet view is stale
  (`presenter.ex:58`); otherwise `observed_at` is the payload `generated_at`
  string (`units_presenter.ex:280-285`). It reaches the catalog at
  `catalog.snapshot.freshness.status` (`presenter_status_source/1`, `:228-240`;
  `units_row/sources.ex:95-104` `freshness/1`), which is `:unknown` (an atom,
  not a map) when the status source has no freshness.
- Caller today: `operator_control_center/payload_loader.ex:154`.
- `operator_control_center/units_row.ex:20-32` `snapshot/1` → `%{version,
  generation, health, freshness, truncated?, rows}`.
- `units_row/projection.ex:57-93` builds each row. The fields this ticket reads:
  `identity` (`:58`), `terminal?` (`:62`), `replacement_boundary?` (`:63`),
  `backend` (`:65`), `agent_family` (`:66`), `requested_model`/`resolved_model`
  (`:67-68`), `effort` (`:69`), `reasons` (`:73`), `runtime` (`:74`),
  `timestamps` (`:78`, built at `:155-162`; `started_at` is the status-row
  value), `open_command_count` (`:79`), `progress` (`:80`).
- `units_row/fields.ex:37-51` `reasons/2`: `waiting`, `blocking`, `alert`,
  `pause`, `resume`, `stuck`. `:53-64` `runtime/2`: `bucket`, `work_state`,
  `waiting_reason`, `tracker_paused?`. `:76-80` `activity_value/2` returns the
  activity map or `%{status: :unknown}`.
- `units_row/sources.ex:169-170` indexes the status buckets
  `[:idle, :retrying, :running]`, so idle and retrying tickets are Units rows
  too (`projection.ex:19-32`).
- `operator_control_center/units_policy.ex:88-95` public `condition?/2`;
  `:97` `live?` = bucket `:running` and not a replacement boundary;
  `:101` `active?` = live and `work_state in [:allocated, :working]`;
  `:107-113` `paused?` (tracker paused, a pause reason, or `work_state in
  [:paused, :sleeping]`); `:115` `stuck?` (`reasons.stuck` or `reasons.waiting`
  in `@stuck_reasons [:tracker_unavailable, :backing_off, :unresponsive]`,
  `:12`); `:125` `finished?`. `:145-149` reads `open_command_count` with an
  `is_integer(count) and count > 0` guard: the row value can be `nil` when the
  decision source is unknown (`fields.ex:66-73` `command_count/3`), and in
  Elixir term order `nil > 0` is `true`.
- `operator_control_center/units_presentation.ex:95-102` `agent_family/1`
  (family from `agent_family`, else from `backend`, else `nil`); `:110-120`
  `agent_label/1` (the provider's display label); `:144-152`
  `model_version/1` (`%{label: "OPUS 5.1", id: ...}` or `nil`; the label is
  an upper-case chip string from `Models.label/1`, `coding_agent/models.ex:151-176`);
  `:205-208` unknown progress renders `"—"` on the Units page today.
- The fleet rows the presenter reads keep atoms: `presenter.ex:303-334`
  `running_entry_payload/1` passes `work_state`, `pause_reason` and
  `waiting_reason` through as atoms and `started_at` as an ISO 8601 string;
  `:337-362` sets `work_state: :retrying`. So the table below matches atoms.

**Orchestrator facts behind those fields.**

- `lib/aiur/orchestrator/status_report.ex:466-532` `running_snapshot/5`:
  `work_state` from `startup_work_state/1` (`:1132-1137`: `:starting` until a
  session id exists, then `:working`, or the control status `:paused`,
  `:error`, `:sleeping`, `:completed`, `:deactivated`), `pause_reason`
  (`:475`), `started_at` (`:476`), `waiting_reason` from
  `WaitingReason.for_running/1`.
- `status_report.ex:534-569` `retry_snapshot/4`: bucket `:retrying`,
  `work_state: :retrying`, `error`, no `started_at`.
- `status_report.ex:1250-1274` idle evidence: `WaitingReason.for_idle/4` gives
  `:latched_lifetime` when the lifetime dispatch latch is spent
  (`waiting_reason.ex:161-164`). That is "retries exhausted". An open
  decision wins over the latch (`waiting_reason.ex:150-151`): an exhausted
  ticket with an open Command reads `:waiting_for_human`, not
  `:latched_lifetime`.
- `waiting_reason.ex:48-64` `for_running/1`: an open decision →
  `:waiting_for_human`; a stall → `:unresponsive`. `:84` `for_retry/0` →
  `:backing_off`.
- `status_report.ex:820-839` `progress_facts/2` and `normalized_percent/1`
  (`:837-839`): a float percent is rounded, a value outside `0..100` is unknown
  (the comment at `:834-836` records the bug where 70.5 became 0).
- `ticket_activity/projection.ex:461-467, 487-491`: progress is
  `%{status: :known, percent, freshness: :fresh | :stale}` or
  `%{status: :unknown}`.
- `lib/aiur/orchestrator/state.ex:724-738` `@non_reserving_pause_reasons
  [:ci_wait, :blocker_dependency, :max_agent_duration, :usage_limit_exhausted]`,
  private. The comment calls these runners "parked". `:usage_limit_exhausted`
  is the #2742 account-limit pause (commit `b1cc394f7`, an ancestor of
  `58854d4c8`).
- `status_reason.ex:71-82` renders the pause reasons: `operator_pause`,
  `label_override`, `global_pause`, `github_budget_hold`, `agent_pause_request`,
  `input_required`, `blocker_dependency` (also in the non-reserving list
  above), `before_run_failure`, `usage_limit_exhausted` ("provider limit").
  `:github_budget_hold` is set on running entries
  (`github_budget_pause.ex:189`).

**Model families.** `lib/aiur/coding_agent.ex:292-300`
`provider_descriptor/1`. Families in the registry: `claude`
(`coding_agent/providers/claude.ex:13, 87`), `codex` (`providers/codex.ex:14`),
`muse` (`providers/muse.ex:13`), `fake` (`providers/fake.ex:9`, tests), and
`kimi`, `deepseek`, `openrouter` (`lib/aiur/open_ai_compat/registry.ex:11, 38,
70`, family set at `:110-115`). Display labels: "Claude" (`claude.ex:51`),
"Codex" (`codex.ex:53`), "Muse" (`muse.ex:37`), "Kimi", "DeepSeek",
"OpenRouter" (`registry.ex:28, 60, 98`). The four design brands match the
design's `MODELS[k].name` exactly. Efforts: `none low medium high xhigh max`
(`providers/codex.ex:47`), `low medium high xhigh max` (`providers/claude.ex:127`),
`minimal low medium high xhigh` (`providers/muse.ex:26`).

**Tracker id.** `lib/aiur/tracker_identity.ex:65-85, 267`: `identifier` is the
issue number as a string (`"123"`), the id C3-T02 uses.

**Design source (what this ticket must match).**

- `AST` (J:88–91): `active` Running/`active`; `error` Error/`stuck`;
  `retries` "Retries exhausted"/`stuck`; `command` "Awaiting command"/`stuck`;
  `paused` Paused/`idle`; `parked` Parked/`idle`.
- `MODELS` (J:82–87): `claude`, `codex`, `deepseek` (`fill`), `kimi` (`fill`),
  each with `name`, `full` and `logo`.
- Mock now rows (J:203–212, 253–257): `agent: {model, state, effort}`, `pct`,
  `start = NOW − elapsed`, `status: "running"`, `sec: "now"`. Effort is
  `low | medium | high`.
- Progress hue: `--pct: <pct>%` and `--ph: Math.round(42 + pct * 1.03)` on the
  card (J:824), the list row (J:1160) and the modal status (J:1387). CSS falls
  back to hue 60 when `--ph` is absent: `.bd-card.now .bd-in` (C:456; light
  and Gruvbox C:967, 987, 1054, 1055, 1149), `.bd-bar i` (C:457; C:968, 1011,
  1053), `.bm-st b` (C:489), and `.bm-st b, .lr-pg b` in light (C:1016).
  `.lr-pg b` in dark (C:762) and `.bd-now-strip i` (C:828) read `var(--ph)`
  with no fallback. The `.bd-in` gradient is safe without `--pct` (its height
  falls to `var(--pct, 0%)`); the bar and the `<b>` text are not. The bar fill
  is an inline `width: <pct>%` (J:833, 850, 1160).
- Places that read `AST[t.agent.state]` with no guard: J:818 card `ag` (then
  `ag.cls` at J:820 and `ag.label` at J:850, which throws), J:1152 `stClass`,
  J:1153 `stText`, J:1210 tree label, J:1211 tree node `ag`, J:1376–1380 modal
  `ag.label`/`ag.cls`. Places that read `MODELS[t.agent.model]` with no guard:
  J:828, J:833, J:1159 (list), J:1307 and J:1462 (conversation). J:1376 hides
  the whole agent block when the model is not in `MODELS`. The Agent filter
  (J:1102) lists only the six `AST` keys plus "No agent".
- Band counts (J:663–664): running = `active`; stuck = `error`, `retries`,
  `command`; paused = `paused`, `parked`. Band order (J:490): epic column order,
  then `num`. Empty band (J:669): "No agents are working right now."

**Tests to extend.** `test/aiur_web/operator_control_center/units_row_test.exs`
(helpers `identity/4` `:509`, `membership/2` `:521`, `member/2` `:525`,
`status/2` `:535`) and `units_policy_test.exs` (`active_row/1` `:133`,
`unknown_row/0` `:175`).

## Chosen design

### Interface

```elixir
@spec build(units_catalog :: map(), opts :: keyword()) ::
        %{rows: %{String.t() => now_facts()}, source: source_block()}
# opts: :repository {owner, repo} (from config, EC-29). No other options.
# A missing or malformed :repository gives no rows and
# source %{state: "unavailable", reason: "repository_unknown"}; it never raises.

@type now_facts :: %{
  id: String.t(), num: pos_integer(), sec: "now", status: "running", ord: integer(),
  start: integer() | nil, pct: 0..100 | nil,
  agent: %{model: String.t() | nil, name: String.t() | nil,
           state: String.t() | nil, effort: String.t() | nil}
}
@type source_block :: %{state: "ok" | "stale" | "unavailable",
                        observed_at: integer() | nil, reason: String.t() | nil}
```

- The input is the `UnitsPresenter.load/2` result. C8-T04 calls `load/2` with
  the dashboard payload, as `payload_loader.ex:154` does, and passes it in.
  `build/2` is pure: no process reads, no clock.
- C8-T04 merges each `now_facts` map over the ticket's other fields, puts
  `source` at `sources.agents`, and then calls `Payload.row/1`. `sources.agents`
  comes from this function and not from C8-T03's `Freshness.source/1`: it is
  computed from the same catalog as the rows, so the rows and their freshness
  cannot disagree (Interface notes 2). A ticket in
  `rows` is in the `now` section, whatever the queue says (now wins over plan;
  C7-T01's row for the same id is dropped).

### Band membership

A Units row becomes a now row when it is not `finished?` and not a replacement
boundary, its identity is joinable and in the configured repository (owner and
repository compared case-insensitively, as `tracker_identity.ex:60-62`
documents), and one of:

1. it is `live?` (bucket `:running`);
2. its bucket is `:retrying` (between attempts, still this ticket's agent);
3. its waiting reason is `:latched_lifetime` (retries exhausted).

Every other row (awaiting dispatch, dependency waits, idle) is not a now row.
An exhausted ticket that also has an open Command reads `:waiting_for_human`
on the idle row (`waiting_reason.ex:150-151`), so it is not a now row; it stays
visible as a plan or not-queued row with its Command (D16).
There is no cap: 25 agents give 25 rows (EC-05). `truncated?: true` on the
catalog is passed on as `source.reason = "membership_truncated"`.

### Agent-state table (first match wins)

| # | Units row condition (fields as in `projection.ex:57-93`) | `agent.state` | Design label (J:88–91) |
| --- | --- | --- | --- |
| 1 | `runtime.work_state == :error`, or `runtime.bucket == :retrying`, or `UnitsPolicy.condition?(:stuck, row)` (unresponsive, backing off, tracker unavailable) | `error` | Error |
| 2 | `reasons.waiting == :latched_lifetime` | `retries` | Retries exhausted |
| 3 | `is_integer(open_command_count) and open_command_count > 0`, or `reasons.waiting == :waiting_for_human` | `command` | Awaiting command |
| 4 | `UnitsPolicy.condition?(:paused, row)` and (`State.non_reserving_pause_reason?(reasons.pause)` or `reasons.pause == :github_budget_hold`) | `parked` | Parked |
| 5 | `UnitsPolicy.condition?(:paused, row)` (operator, label, run pause, sleeping, cooperative, preflight) | `paused` | Paused |
| 6 | `live?` and `runtime.work_state in [:starting, :allocated, :working]` | `active` | Running |
| 7 | anything else (for example `:deactivated`, or a control status this table does not know) | `nil` | rendered "State unknown" |

Why this order: a failure is the most urgent fact; an exhausted ticket is a
failure that will not retry; a Command needs a human even when the agent is
paused; parked and paused are both idle in the design, and parked is the more
specific cause. Row 7 is the cause-neutral collapse (AGENTS.md "A collapsed
cause names the collapse at the source"): an unknown state is `nil`, never
`active`.

Every `UnitsPolicy` condition (`units_policy.ex:88-95`) is mapped:

| Condition | Effect here |
| --- | --- |
| `:active` | row 6 (`:starting` is added, D6) |
| `:alert` | a Command is row 3; an `alert_reason` without a Command changes no state (it is an attention, not an agent state) |
| `:paused` | rows 4 and 5 |
| `:stuck` | row 1 (D4) |
| `:queued` | not a now row, except bucket `:retrying` (membership 2, row 1) |
| `:finished` | not a now row |

Row 3 uses the same `is_integer` guard as `units_policy.ex:145-149`. Without
it, a row whose decision source is unknown (`open_command_count: nil`) would
read as "Awaiting command", because `nil > 0` is `true` in Elixir.

### Other fields

| Field | Source | Unknown |
| --- | --- | --- |
| `id`, `num` | `identity.identifier` (`"123"`), its integer | row dropped if the identity is not joinable (it cannot be keyed) |
| `ord` | `num` | — (the design's array order is `num` order, J:253–256; the client sorts the band by epic column, J:490) |
| `start` | `timestamps.started_at` (ISO 8601 string or `DateTime`) → epoch ms | `nil` (retrying and latched rows have no session start) |
| `pct` | `progress` when `status: :known`: integer in `0..100`, or a float rounded into it (as `status_report.ex:838-840`) | `nil` for `:unknown`, a missing map, out of range or a non-number |
| `agent.model` | `Atom.to_string(UnitsPresentation.agent_family(row))`, when it matches `^[a-z0-9][a-z0-9._-]{0,31}$` | `nil` |
| `agent.name` | `UnitsPresentation.agent_label(family)` (the registry label, `units_presentation.ex:115-120`; not the row clause at `:111-113`, which falls back to a model id) | `nil` |
| `agent.effort` | `effort` as a lower-case string, if in `none minimal low medium high xhigh max` | `nil` |

`agent` is always a map on a now row (the design reads `t.agent.state` on every
now row, J:663). Its fields may each be `nil`.

### `sources.agents`

| `catalog.status` | `state` | `observed_at` | Rows |
| --- | --- | --- | --- |
| `:ready`, `:empty` | `"ok"` | `catalog.snapshot.freshness.status.observed_at` (ISO 8601 string or `DateTime`) → epoch ms; `nil` when absent, unparsable, or the freshness is not a map | as built |
| `:stale` | `"stale"` | the same | as built (last known) |
| `:unavailable` | `"unavailable"` | `nil` | `%{}` |
| anything else, or a catalog that is not a map | `"unavailable"` | `nil` | `%{}` |

`reason` is a code, never prose (C9-T13 owns the copy, S-9; the catalog
`message` is not copied): `"fleet_stale"` for stale, `"fleet_unavailable"` for
unavailable, `"membership_truncated"` for an ok catalog with `truncated?: true`,
`"repository_unknown"` (see Interface), else `nil`. This is what lets C9-T13
tell an empty band ("No agents are working right now.") from a band it cannot
know (EC-05, EC-07). C9-T08 and C9-T13 render the age from `observed_at`.

### Client rules (`now-state.js`)

```js
const f = Object.freeze;
export const AST = f({ /* J:88–91, copied verbatim, each entry frozen */ });
export const UNKNOWN_STATE = f({ label: "State unknown", cls: null });
// Object.hasOwn: "__proto__", "constructor" or "toString" must not find
// Object.prototype members (a plain `AST[s]` returns a truthy object with no label).
export const agentState = (s) => (typeof s === "string" && Object.hasOwn(AST, s) ? AST[s] : UNKNOWN_STATE);
const known = (p) => Number.isInteger(p) && p >= 0 && p <= 100;
export const progress = (pct) => known(pct)
  ? { known: true, text: pct + "%", style: "--pct:" + pct + "%;--ph:" + Math.round(42 + pct * 1.03) }
  : { known: false, text: "—", style: "" };
const LABELS = f({ claude: "Claude", codex: "Codex", deepseek: "DeepSeek", kimi: "Kimi" }); // J:83–86 `name`
export const modelLabel = (a) => (a && typeof a.name === "string" ? a.name
  : a && typeof a.model === "string" && Object.hasOwn(LABELS, a.model) ? LABELS[a.model] : null);
```

- Renderers use `agentState(t.agent.state)` where the design wrote
  `AST[t.agent.state]` (J:818, 1152, 1153, 1210, 1211, 1376). `cls: null`
  means no `ag-*` class and no glow: a renderer tests `ag.cls`, not `ag`, so it
  never writes `ag-null`.
- Renderers use `modelLabel(t.agent)` for the logo `title`/`alt` and the modal
  name, where the design wrote `MODELS[m].name`/`.full` (J:828, 1390). `null`
  means "Model unknown" text and the S-13 `?` letter (C9-T06). The design's
  mock `full` strings ("Claude Sonnet 4.5") are never shown (D11).
- Renderers use `progress(t.pct)`. For an unknown value they set no `--pct` and
  no `--ph`, render no `.bd-bar` element, and print `—` where the design prints
  `N%`. The `—` is a plain text node: it is **not** wrapped in the `<b>` of
  `.bm-st` (J:1387) or `.lr-pg` (J:1160), because `.bm-st b` (C:489) and
  light-theme `.lr-pg b` (C:1016) colour that `<b>` with `var(--ph, 60)`, the
  amber "early progress" hue. Without the bar element the inline
  `width: null%` (which a browser ignores, so the block `<i>` fills 100 %,
  C:245) cannot occur.
- C9-T01 may move the file inside its module layout; it keeps the five exports
  (the same rule as C3-T02's `protocol.js`).

### Interface changes to C3-T02 (added in this ticket's PR)

C3-T02 fixed `agent` as `{ model: str, state: AST key | null, effort: low |
medium | high | null }`. That shape cannot carry three facts this ticket has:

1. **Unknown model.** EC-08 lists the model. A `str`-only `model` forces a
   made-up key. Rule: `model` is a key string (same regex) or `null`. C9-T06
   draws `null` as the `.ax-mono` circle with `?` (S-13 shape, unknown letter).
2. **Real model name.** The design's logo title is `MODELS[m].full` (J:828), a
   mock constant ("Claude Sonnet 4.5"). Showing it for a real Opus session would
   be false. Rule: `name` is a required key, a string of at most 64 characters
   or `null` (C3-T02's extension table already assigns `agent.name` to this
   ticket). The client reads it through `modelLabel/1`. No `full` key is added:
   no consumer reads one (C9-T06 D-2 titles by name only; C11-T01 titles by name
   and effort), and the only model-version text the server has is an upper-case
   chip label ("OPUS 5.1"), not the design's "Sonnet 4.5" form (D11).
3. **Effort.** The product has seven effort values. Mapping `max` to `high`
   would be a false label. Rule: the enum is `none minimal low medium high xhigh
   max`. It is rendered only as text inside a `title` (J:1390), so no pixel
   changes.

Per C3-T02's extension rule ("each additive key lands in one PR together with
its validator clause, its fixture mapping and its producer"), this PR also
changes C3-T02's `mapRawToPayload` (`src/browser/scripts/build-home-fixture-map.mjs`)
to emit `agent.name = MODELS[a.model].name` for every row that has an `agent`
(`null` when the key is not in `MODELS`), and regenerates the five fixtures.
The design rows only use the four `MODELS` keys, so the fixtures stay
pixel-identical.

`Payload.validate/1` gets one clause per item. Tests: see Verification
(`payload_test.exs`). C3-T02 already rejects `effort: "<b>"` and `model: 5`;
those cases are kept as guards and not counted as coverage of this change.

## Implementation steps

1. `lib/aiur/orchestrator/state.ex`: below `:738` add
   `@spec non_reserving_pause_reason?(term()) :: boolean()` and
   `def non_reserving_pause_reason?(reason), do: reason in @non_reserving_pause_reasons`.
   No other change in that file.
2. PROPOSED `lib/aiur_web/build/now_rows.ex`, `AiurWeb.Build.NowRows`:
   - `build/2`: `catalog.snapshot.rows |> Enum.filter(&band?(&1, repo)) |> Map.new(&{id, facts(&1)})`
     and `source(catalog)`;
   - `state/1`: one `cond` in table order; the moduledoc is the table;
   - `pct/1`, `start_ms/1`, `model/1`, `effort/1`: small private clauses, each
     with a final clause that returns `nil`;
   - aliases only on the seam: `UnitsPolicy`, `UnitsPresentation`,
     `Aiur.Orchestrator.State`. Keep the module under 150 lines.
3. `lib/aiur_web/build/payload.ex` (C3-T02): the three rules above, and the
   moduledoc schema text updated in place (no second copy). In the same PR,
   `src/browser/scripts/build-home-fixture-map.mjs` (C3-T02 step 5) emits
   `agent.name`, and the five fixtures under `src/test/fixtures/build_home/`
   are regenerated (C1-T01's `--check` then passes on the new manifest).
4. PROPOSED `priv/static/build-home/now-state.js`: the code above, an ES module
   inside C2-T03's `build-home/` directory (no `layouts.ex` change).
5. Fixture: PROPOSED `test/support/build_home/units_band_fixture.ex`,
   `units_band_catalog/1`. It builds a Units catalog (with the
   `units_row_test.exs` helper shapes) for the eight design agents in the
   `live` fixture's now rows, using this inverse table: `active` → running,
   `work_state: :working`; `command` → running, `open_command_count: 1`;
   `error` → running, `work_state: :error`; `retries` → idle,
   `waiting_reason: :latched_lifetime`; `paused` → running, `:paused`,
   `pause_reason: :operator_pause`; `parked` → running, `:paused`,
   `pause_reason: :usage_limit_exhausted`. Model, effort, pct and start come
   from the fixture row.
6. Tests (Verification) and the npm script
   `test:build-home-now-state` = `node --test scripts/build-home-now-state.test.mjs`,
   added to the `test` chain in `src/browser/package.json` (next to C3-T02's
   `test:build-home-protocol`, same directory). Node's built-in test runner; no
   new dependency.
7. Docs: none. No config key, CLI flag, env var or new page. The board page docs
   ship with C12-T01.

## Non-happy paths

- **Units source unavailable** (membership or fleet provider down,
  `units_presenter.ex:152-176`): `source.state = "unavailable"`, no rows. The
  band must not say "No agents are working right now." (EC-05). C9-T13 owns the
  copy (S-9).
- **Stale fleet view:** rows are last known, `source.state = "stale"` with its
  `observed_at`. The values are not relabelled as current (EC-07).
- **Stale progress** (`freshness: :stale`): the value is kept. It is the agent's
  last report and the Units page shows it the same way today
  (`units_presentation.ex:205-206`). See decision D9.
- **Agent ends between two reads:** the row leaves `rows`; C8-T04's diff moves
  the ticket to history in one upsert (EC-10). This module keeps no state.
- **Two repositories with the same issue number:** only the configured
  repository is kept, so ids cannot collide (EC-29).
- **Hostile values:** `agent_family` comes from the registry, but the key regex
  is still checked; `name` is a registry label that the client escapes (C3-T02
  EC-30 rules). A bad effort is `nil`, not echoed.
- **Unknown Command count:** `open_command_count: nil` (decision source down) is
  not a Command (row 3 guard); the row falls through to its other facts.
- **Exceptions:** `build/2` never raises on a missing field. Every lookup has a
  `nil` clause. A catalog that is not a map, or a missing `:repository`, gives
  `source.state = "unavailable"` and no rows.
- **Concurrency, retries, idempotency:** none. Pure function over one
  snapshot; the same input gives the same output.
- **Privacy:** no new data leaves the server. Account, tokens, workspace paths
  and the error text of a retry are not copied into the row.

## Compatibility and rollout

- No config, migration or feature flag. Nothing renders these rows until C8-T04
  wires the real DataSource and C12-T01 switches `/`.
- The Payload change is additive (`null`, a wider enum and the new `name` key).
  The regenerated C3-T02 fixtures validate; a fixture without `agent.name` no
  longer does, which is why the mapping change ships in this PR.
- `State.non_reserving_pause_reason?/1` is a new read-only function.
- Rollback: revert the PR. The fixture DataSource keeps working.

## Pixel parity

This ticket changes no pixel by itself. Parity is checked in two steps.

1. **Data parity (this ticket).** For each of the eight now rows in the
   C3-T02 `live` fixture, `NowRows.build(units_band_catalog(live))` produces the
   same `id`, `sec`, `status`, `pct`, `agent.model`, `agent.name`,
   `agent.state` and `agent.effort` as the fixture row, and `start` within 1 ms
   (rows a1–a4 and a6–a8; the latched `retries` row a5 has `start: nil`, see
   D15). Six design states, four models and three efforts are covered by those
   eight rows (J:204–211).
2. **Screenshot parity (registered here, run by C9-T08).** Add the case
   `now-band-from-units` to C1-T02's matrix: the fixture BuildLive serves the
   `live` fixture with its now rows replaced by this ticket's output (merged
   over the fixture's other fields). `expectDesignParity(pair, { name:
   "now-band-from-units", region: "#bd-now" })` at 1440, 1024 and 390 px, dark
   and light, default and Gruvbox, with C1-T02's frozen clock and
   `TZ=America/Los_Angeles`. It must match the design with no allowlist entry,
   except the `retries` card in Gantt view (start unknown), which C9-T09 covers.
   Elements in the crop: `.bd-now-h` counts (J:663–667), `.bd-card.now` with
   `ag-active`/`ag-stuck`/`ag-idle`, `--pct`/`--ph` gradient and bar (C:456–459),
   `span.bd-ag` logo (C:280–281, 396–398).

The unknown-state and unknown-progress looks have no design reference. They are
not in the parity matrix; they are listed for DESIGN-E8 sign-off (D7, D8). The
renderer tickets that draw them (C9-T05, C9-T11, C9-T12, C11-T01) own a DOM
check that the computed colour of the unknown `—` and of any bar is not the
hue-60 fallback.

## Verification

ExUnit, PROPOSED `test/aiur_web/build/now_rows_test.exs`:

| Test | Input | Expected | Fails when |
| --- | --- | --- | --- |
| `state table: one case per row` | seven Units rows, one per table row 1–7 | `error`, `retries`, `command`, `parked`, `paused`, `active`, `nil` | any clause is removed or reordered |
| `unknown state is nil, not active` | running row, `work_state: :deactivated` | `agent.state == nil` | the last `cond` clause returns `"active"` |
| `command beats paused` | paused row with `open_command_count: 2` | `command` | rows 3 and 5 swap |
| `unknown command count is not a Command` | running, `work_state: :working`, `open_command_count: nil` | `active` | the `is_integer` guard is dropped (`nil > 0` is `true`, gives `command`) |
| `tracker unavailable is error` | running, `work_state: :working`, `reasons.waiting: :tracker_unavailable` | `error` | row 1 lists only `:unresponsive` instead of `UnitsPolicy.condition?(:stuck, row)` |
| `account limit is parked` | paused, `pause_reason: :usage_limit_exhausted` | `parked` | the predicate is not used (gives `paused`) |
| `operator pause is paused` | paused, `pause_reason: :operator_pause` | `paused` | `parked` matches every pause |
| `retrying is error, exhausted is retries` | bucket `:retrying`; idle with `:latched_lifetime` | `error`; `retries` | membership or rows 1–2 change |
| `queued and finished tickets are not now rows` | idle `:awaiting_dispatch`; `terminal?: true`; replacement boundary | not in `rows` | `band?/2` admits all rows |
| `unknown pct stays nil` | `progress: %{status: :unknown}`; no `progress` key | `pct: nil` (`Map.fetch!` shows the key is present) | a `|| 0` fallback, or the last known value |
| `float pct rounds, out of range is nil` | `70.5`, `140`, `"50"` | `71`, `nil`, `nil` | an `is_integer` guard (gives `nil` for 70.5) or no range check |
| `unknown model is nil` | `agent_family: nil, backend: nil, resolved_model: "claude-opus-5-1"` | `agent.model == nil`, `agent.name == nil` | a default to `"claude"` or `"unknown"`, or `name` from the row clause of `agent_label/1` (gives the model id) |
| `muse keeps its key` | `agent_family: "muse"` | `model == "muse"`, `name == "Muse"` | the model list is limited to `MODELS` |
| `effort keeps the product value` | `"max"`, `:high`, `"<b>"` | `"max"`, `"high"`, `nil` | collapse to `low/medium/high` |
| `start parses or is nil` | `"2026-10-07T21:20:00Z"`; `"garbage"`; missing | epoch ms; `nil`; `nil` | a `NOW` or `0` fallback |
| `20+ agents are all rows` | 25 running rows | 25 rows, `ord` = `num` | any cap or `Enum.take` |
| `sources: empty vs unavailable vs stale` | catalogs with status `:empty`, `:unavailable`, `:stale` (freshness `observed_at: "2026-10-07T21:14:00Z"`) | `ok` + `%{}` + `reason: nil`; `unavailable` + `%{}` + `observed_at: nil` + `reason: "fleet_unavailable"`; `stale` + rows + `observed_at` = that time in ms + `reason: "fleet_stale"` | `:unavailable` mapped to `"ok"` (the EC-05 mutation: an unknown band shown as empty), or `observed_at` replaced by `nil`/the build time |
| `bad catalog or repository is unavailable` | `nil` catalog; a good catalog with no `:repository` | `rows == %{}`, `state: "unavailable"`; no raise | a `FunctionClauseError`, or `"ok"` with `%{}` (an unknown band shown as empty) |
| `other repository is dropped` | row from `other/repo` with the same number; row from `OWNER/REPO` when config is `owner/repo` | first not in `rows`; second in `rows` | no repository filter, or a case-sensitive compare |
| `design data parity` | `units_band_catalog(live)` | the eight rows match the fixture (Pixel parity step 1) | a state, model, effort or pct mapping changes |
| `rows validate` | each output merged over a fixture row's other fields | `Payload.validate/1 == :ok` | a field type drifts from the schema |

ExUnit, `test/aiur_web/build/payload_test.exs` (C3-T02's file):

| Test | Input (a `live` now row with one change) | Expected | Fails when |
| --- | --- | --- | --- |
| `agent model may be null` | `agent.model: nil` | `:ok` | rule 1 reverted (C3-T02 requires a string) |
| `agent name is a short string or null` | `name: "Muse"`; `name: nil`; `name: 7`; `name` of 65 characters; `name` key missing | `:ok`; `:ok`; error at `agent.name`; error; error (`:missing`) | rule 2 reverted (the strict validator rejects `name` as an unknown key, so the first case fails) or made optional |
| `agent effort is the product vocabulary` | each of `none minimal xhigh max`; `"ultra"` | `:ok` each; error at `agent.effort` | rule 3 reverted (C3-T02 accepts only `low medium high`) |
| `fixtures carry agent.name` | the five regenerated fixtures | every non-null `agent` has `name` in `Claude Codex DeepSeek Kimi` | the mapping change is left out |

C3-T02's existing `effort: "<b>"` and `model: 5` cases stay as guards; they pass
before this change and are not counted as its coverage.

ExUnit, `test/aiur/orchestrator/state_test.exs`: `non_reserving_pause_reason?`
is true for the four listed reasons and false for `:operator_pause` and `nil`.

Node, PROPOSED `src/browser/scripts/build-home-now-state.test.mjs`:

| Test | Expected | Fails when |
| --- | --- | --- |
| `progress(null)` | `{known: false, text: "—", style: ""}`; `style` does not contain `--ph` or `--pct` | the null branch returns `--ph:60` (the CSS fallback hue) or `text: "0%"` |
| `progress(0)` | `text: "0%"`, `style` has `--pct:0%` and `--ph:42` | `0` is treated as unknown (`if (!pct)`) |
| `progress(64)` | `--ph:108` (`Math.round(42 + 64 * 1.03)`, J:824) | the formula differs from the design |
| `progress(70.5)`, `progress(140)`, `progress("50")`, `progress(undefined)` | `known: false` each | a `typeof === "number"` check (lets 140 and 70.5 through as `140%`/`70.5%`) |
| `agentState(null)`, `agentState("bogus")` | `UNKNOWN_STATE` (`{label: "State unknown", cls: null}`) | the fallback is `AST.active` |
| `agentState("__proto__")`, `("constructor")`, `("toString")` | `UNKNOWN_STATE` | a plain `AST[s]` lookup (returns an `Object.prototype` member with no `label`) |
| `modelLabel` | `{model: "muse", name: "Muse"}` → `"Muse"`; `{model: "kimi", name: null}` → `"Kimi"`; `{model: "muse", name: null}` → `null`; `{model: "__proto__", name: null}` → `null`; `null` → `null` | `name` ignored, a raw-key fallback (`"muse"`), or a missing `hasOwn` |
| `AST is the design constant` | deep-equal to `AST` read from the vendored `src/test/fixtures/build_home/design-source/assets/build.js` through C1-T01's `loadBuildJs({designDir, expose: ["AST"]})` | a label or class drifts |

**Mutation check (AGENTS.md).** In a worktree at the PR head, with
`git status --porcelain` empty before each step: (a) replace the row-7 clause
with `"active"`; (b) make `pct/1` return `0` for unknown; (c) map
`:unavailable` to `"ok"`; (d) return `--ph:60` from `progress(null)`; (e) drop
the predicate from row 4; (f) drop the `is_integer` guard in row 3; (g) replace
`Object.hasOwn(AST, s)` with `AST[s]`; (h) revert the `agent.name` validator
clause. Each must fail at least the named test; restore; all pass. Record the
exact commands in the PR body.

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/build/now_rows_test.exs test/aiur_web/build/payload_test.exs \
  test/aiur/orchestrator/state_test.exs \
  test/aiur_web/operator_control_center/units_policy_test.exs
env -C src/browser npm run test:build-home-now-state
env -C src/browser npm run test:build-home-protocol   # C3-T02's suite still green
```

Manual: none in this ticket (no UI yet). C9-T08 runs the band in
`scripts/aiurdev --test` and checks that a paused agent shows "Paused" and an
agent on its account limit shows "Parked".

## Completion and handoff

- [ ] `NowRows.build/2` with the table, membership, fields and `sources.agents`;
      every unknown is `nil`.
- [ ] `State.non_reserving_pause_reason?/1` added; no behaviour change.
- [ ] Payload accepts `model: null`, `name` (string ≤ 64 or `null`) and the
      seven efforts; rejects bad types; fixture mapping emits `agent.name` and
      the five fixtures are regenerated.
- [ ] `now-state.js` with `AST`, `UNKNOWN_STATE`, `agentState`, `progress`,
      `modelLabel`; Node test in `npm test`.
- [ ] Data parity passes for the eight design agents; `now-band-from-units`
      registered in the C1-T02 matrix.
- [ ] Mutations (a)–(h) fail as listed; commands in the PR body.
- **Dependents:** C8-T04 (merges `rows` and `source`), C9-T05, C9-T06, C9-T08,
  C9-T11, C9-T12, C10-T02, C11-T01 (must call `agentState`/`progress`/
  `modelLabel` and handle `agent.model == null`), C9-T09 (now rows may have
  `start: null` and, until C7-T03 joins, `est: null`; J:427 and J:493 read both
  without a guard).
- **Remaining blocker:** DESIGN-E8 sign-off of D7 and D8 (S-31).
- **Sources:** tickets/README.md row MP-E8-C8-T01; chunks.md MP-E8-C8; plan §5,
  §5.1, §8 (EC-05, EC-07, EC-08); MP-E8-C3-T02 (schema); DESIGN-E8 S-4, S-13, S-31;
  E8-D12; J:82–91, 203–212, 253–257, 427, 490–493, 663–669, 818–833, 850,
  1102, 1152–1153, 1159–1160, 1210–1211, 1307, 1376–1392, 1462; C:245,
  280–281, 396–398, 456–459, 489, 761–763, 828–831, 967–968, 987, 1011, 1016,
  1053–1055, 1149.

## Decisions made without the owner

- **D1 Band membership** is live, retrying, or retries-exhausted rows. Queued
  and dependency-waiting tickets are plan or not-queued rows. Reason: the design
  band holds only tickets that have an agent (J:203–212).
- **D2 State precedence** is error > retries > command > parked > paused >
  active > unknown. Reason: the most urgent fact wins; a Command needs a human
  even on a paused agent.
- **D3 Parked** = a pause whose reason releases the slot
  (`@non_reserving_pause_reasons`: CI wait, dependency, duration cap, account
  limit), plus the GitHub budget hold. Reason: the orchestrator already calls
  these runners parked (`state.ex:724-738`); the budget hold is the "capacity"
  case the row names. Operator, label, run-wide and cooperative pauses are
  `paused`.
- **D4 Every `UnitsPolicy` stuck reason** (unresponsive, backing off, tracker
  unavailable) maps to `error`, through `UnitsPolicy.condition?(:stuck, row)`
  so the list is the policy's, not a copy. This collapses a stall or a tracker
  outage into the design's only general stuck state; the row carries no cause
  field, so the label "Error" is less exact than "stalled". Flag for sign-off;
  a cause field would be a C3-T02 schema addition.
- **D5 A retry in backoff** is `error`: its last attempt failed and no agent is
  running. It is not `retries` (that is only the spent latch).
- **D6 `:starting`** (no session id yet) is `active`: the agent is being
  started for this ticket.
- **D7 Unknown state** is `null` and renders "State unknown" with no `ag-*`
  class, no glow and no count in the band header. New design gap (S-31).
- **D8 Unknown progress** renders `—` (the Units page's unknown glyph), no bar,
  no `--pct`, no `--ph`. New design gap (S-31).
- **D9 Stale progress** keeps its value, as the Units page does. No stale look
  exists in the design; `sources.agents` carries the fleet age.
- **D10 The logo key is the provider family**, not the model id. A missing
  family is `null` (drawn as `?`), never a default model.
- **D11 `name` and the full effort vocabulary** are added to the payload so the
  logo title and effort text are true for real sessions. `full` is not added:
  no consumer reads it (C9-T06 D-2, C11-T01), and the server's only version text
  is an upper-case chip label ("OPUS 5.1"), so a `full` string would neither
  match the design's form nor be read. The design's mock `full` strings are
  never shown. A later ticket can add `full` as an additive key.
- **D12 `est` is not computed here.** C7-T03's `resolve/2` needs `cx`, which a
  Units row does not carry; C8-T04 has `cx` after the join and calls it for now
  and plan rows (C7-T03 line "called by C8-T04 for every plan and now row").
  The README row lists `est` under this ticket; this ticket only guarantees it
  is never `0` by default (it sends no `est` key). `est` comes from the C8-T04
  join and C7-T03 (R-G12; Interface notes 1).
- **D13 `ord` = `num`.** The client already orders the band by epic column then
  `num` (J:490).
- **D14 `sources.agents`** comes from the Units catalog status, not from a new
  probe and not from C8-T03's `Freshness.source/1`. C9-T08 and C9-T13 render
  its age (AGENTS.md "a computed age is rendered").
- **D15 `start`** is the session `started_at`. Retrying and exhausted rows have
  none and send `null`; Gantt (C9-T09) must handle it.
- **D16 An exhausted ticket with an open Command is not a now row.** The
  orchestrator reports it as `:waiting_for_human` on the idle row, without the
  latch. Its Command stays reachable from its plan or not-queued row. Reading
  the latch status separately would need a new field from the status report,
  which this ticket does not add.
- **D17 `sources.agents.reason` is a code** (`fleet_stale`,
  `fleet_unavailable`, `membership_truncated`, `repository_unknown`), not the
  Units catalog's prose. The copy belongs to C9-T13 (S-9), and the same codes
  work in logs and the JSON envelope.
- **D18 One client copy of `AST`.** `now-state.js` owns `AST`,
  `UNKNOWN_STATE`, `agentState`, `progress` and `modelLabel`. C9-T06's
  `agents.js` imports them instead of declaring its own (Interface notes 3).

## Interface notes (for the coordinator)

This ticket edits only its own file. Items settled by the 2026-10-08
reconciliation are marked.

1. **`est` on now rows.** Settled 2026-10-08: `est` comes from the C8-T04 join
   and C7-T03, which lands after C8-T04 and wires it (R-G12); C8-T01 sends no
   `est` key.
2. **`sources.agents`.** Settled 2026-10-08: C8-T01 produces `sources.agents`
   (`NowRows.build/2` `source`, put there by C8-T04); C8-T03 only renders its age.
3. **`AST` copies.** Settled 2026-10-08: `AST`, `agentState`, `progress` and
   `modelLabel` live only in this ticket's `now-state.js`, with the
   `Object.hasOwn` guard (R-G9); other modules import them.
4. **`modelLabel`.** Settled 2026-10-08: shipped here only (R-G9); C9-T12
   step 5 is a no-op and C9-T06 uses `modelLabel(t.agent)`.
5. **Unknown `—` must not sit in a hue-60 `<b>`.** Settled 2026-10-08: C9-T12
   renders the amber-free `—` outside the hue-60 `<b>` (C8-T01 note); C11-T01
   does the same for `#bm-pct` (C:489). `.lr-pg b` is
   `oklch(.6 .15 var(--ph, 60))` in light theme (C:1016).
6. **C3-T02 `agent` schema.** Settled 2026-10-08: `agent.name`, nullable
   `agent.model` and the widened effort enum are in C3-T02's accepted additive
   fields table (R-G1); there is no `agent.full` (R-G10).
7. **Agent filter.** J:1102 lists only the six `AST` keys plus "No agent". A now
   row with `agent.state: null` matches none of them. C10-T02 decides whether
   it appears under all filters only (default here) or gets an "Unknown" option.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8` and the design source.

1. Row 3: `open_command_count > 0` is `true` for `nil` in Elixir; added the
   `is_integer` guard (as `units_policy.ex:145-149`), a test and mutation (f).
2. Row 1: used `UnitsPolicy.condition?(:stuck, row)` so `:tracker_unavailable`
   and `:backing_off` are covered and every `UnitsPolicy` condition is mapped
   (README row asks for this); added the coverage table and a test.
3. Client `agentState`: `AST[s]` returns `Object.prototype` members for
   `"__proto__"`/`"constructor"`; switched to `Object.hasOwn` and added a test
   and mutation (g). `progress` now accepts only integers in `0..100`.
4. Dropped `agent.full` (no consumer; the server's version text is an
   upper-case chip label). Added `modelLabel` to `now-state.js` (C9-T12 expects
   it there) and `agent.name` to data parity.
5. Added the C3-T02 fixture-mapping change that the extension rule requires for
   a new key; without it the strict validator rejects `name`.
6. Payload tests: `model: 5` and `effort: "<b>"` already fail under C3-T02, so
   they could not prove this change; replaced with tests that fail when each
   new rule is reverted.
7. Unknown progress: the `—` must not sit in `.bm-st b`/`.lr-pg b`, which fall
   back to hue 60 (C:489, 1016). Listed every `var(--ph, 60)` site.
8. Added unguarded design sites J:818/820/850 (card), J:1159, 1211, 1307, 1462.
9. `sources.agents`: `observed_at` path made exact
   (`catalog.snapshot.freshness.status`, which is fresh-only `generated_at`
   unless stale); `reason` changed from catalog prose to codes; added the
   non-map catalog and missing-repository cases and tests.
10. Exhausted-plus-Command tickets read `:waiting_for_human`
    (`waiting_reason.ex:150-151`); recorded as D16.
11. Line fixes: `startup_work_state` `:1132-1137`, `progress_facts` `:820-839`
    and comment `:834-836`, registry families `:11, 38, 70`; corrected the
    `status_reason.ex` sentence (`blocker_dependency` is parked).
12. Parity row numbering: the latched row is a5, not row 4.
13. Node test moved to `src/browser/scripts/` (C3-T02's convention); the AST
    check reuses C1-T01's `loadBuildJs`.
14. Recorded neighbour conflicts (est owner, `sources.agents` owner, two `AST`
    copies, C9-T12 amber `—`) under "Interface notes".
- Reconciliation 2026-10-08 (coordinator): unknown state/progress cited as S-31, `est` source per R-G12, Interface notes 1-6 marked settled (est, `sources.agents` owner, `AST`/`modelLabel` in `now-state.js` only, amber `—`, C3-T02 additive fields, no `agent.full`).
