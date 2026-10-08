---
ticket_id: MP-E8-C5-T03
feature_id: MP-E8
chunk_id: MP-E8-C5
bucket: 2-platform
title: Epic override registry and batch CLI
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C5-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-13]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C5-T03 — Epic override registry and batch CLI

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime`; Elixir paths are under `src/`). Paths marked
> PROPOSED do not exist yet. If MP-R1 has moved `build_order/` before this
> starts, re-resolve the symbols below (CR-E8-6 places Build Order stores in
> `build-orders`).

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C5
  (epics), ticket T03. It follows C5-T02 (the resolver) and comes before C5-T04
  (skill and prompt guidance), C12-T07 (docs), and C13-T04 (backfill run).
- **User value.** About 90 % of tickets have no epic signal (baseline §5). An
  operator or an agent must be able to put a ticket, or 200 tickets, into an
  epic with one command, and later see who did it, when, and from which
  channel (E8-D9). The board then draws that ticket in the right column.
- **Deliverables.**
  1. PROPOSED `Aiur.BuildOrder.EpicOverrides`: a durable, journaled store of
     ticket number → epic, with `actor`, `at`, `source` and `confirmed`.
  2. CLI `aiur epic set <epic> <ids…>`, `aiur epic clear <ids…>`,
     `aiur epic show [<ids…>]` and `aiur epic list`, each with `--json`,
     through the shared launcher engine. `set` also takes `--source` and `--as`.
     `list` prints the configured general epic keys (§10 decision 11).
  3. PROPOSED agent tool `aiur_set_epic` (a dynamic tool, like
     `aiur_set_ticket_state`). This is the path an agent in an issue workspace
     uses, because the CLI cannot reach the daemon from there (§3.4).
  4. A change signal on PubSub so the ticket index (C8-T04) can update the board.
  5. `website/docs-app/reference/cli.md` entry and the tool row in
     `website/docs-app/concepts/ticket-lifecycle.md`.
- **Non-goals.**
  - No GitHub writes. Overrides are local only (E8-D10). Optional label
    projection is C13-T02.
  - No resolver logic. `aiur epic show` reports the stored override, not the
    effective epic. The effective epic needs History labels and feature
    membership, and the board (C8-T04) owns that join.
  - No `confirm` operation. C13-T03 adds `aiur epic confirm` on top of this
    store; it confirms through an ordinary `set` entry with `confirmed: true`.
    There is no `confirm` journal op.
  - No feature epics as override targets (§10 decision 3).
  - No journal compaction (§10 decision 7).
  - No UI. S-8's default keeps provenance off the board and modal.

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8** (every MP-E8 ticket). S-8 is not a blocker: this
  ticket follows its default ("not on the board or modal; visible through
  `aiur epic` / `aiur feature show --json`"). If Kevin answers S-8 with a board
  treatment, C13-T03 and C11-T04 change, not this store.
- **Blocked by MP-E8-C5-T02.** This ticket uses the override input shape of
  the resolver: `override: %{epic: key, actor: actor, …} | :none | :unknown`
  (C5-T02 §4). C5-T02 reports the source `override:<actor>`, so this store's
  `Override` struct carries `actor`. C5-T02 is a pure function and gives **no**
  epic catalog function (C5-T02 hand-off note to C5-T03).
- **Uses C5-T01 directly (transitive predecessor, through C5-T02).** The
  catalog of valid keys is C5-T01's PROPOSED `settings.build_order.epics`, a
  list of `%Aiur.Config.Schema.BuildOrderEpic{key, label, …}` (C5-T01 §4.4).
  This store reads it with `Aiur.Config.settings/0`
  (`src/lib/aiur/config.ex:62-63`, returns `{:ok, schema} | {:error, term}`) at
  each write and maps `& &1.key`. This is the same read C8-T04 does (C8-T04
  "Parts", row `epics`). C5-T01 already refuses the key `unsorted`.
- **Successors.** C5-T04 (teaches agents the tool and the CLI), C12-T07 (docs
  page for build history), C13-T03 (`aiur epic confirm`), C13-T04 (backfill
  writes with source `backfill-agent`), C8-T04 (reads overrides and subscribes;
  see §11 interface notes).
- **May run concurrently with** C6-T01 (feature registry), C7-T*, C9-T*. It
  touches `aiur-engine.sh` and `agent_control_cli.ex`, which C6-T04 and C7-T03
  also touch: they add sibling `cmd_*` functions and dispatch arms, so merges
  are textual only.
- Shared contracts: none. Owner gate: DESIGN-E8.

## 3. Verified starting point (`58854d4c8`)

### 3.1 Store pattern to copy

| Need | Existing code | Use |
| --- | --- | --- |
| Atomic write with fsync and mode | `src/lib/aiur/fs.ex:19` `Fs.atomic_write/3` (temp file, optional `fsync:`, `mode:`, rename) | Every write |
| Keep evidence of a bad file | `src/lib/aiur/fs.ex:106` `Fs.quarantine/1` | Not used for this store (§10 decision 5) |
| Durable store shape | `src/lib/aiur/progress_retention.ex`: `@checkpoint_filename` `:43`, `init/1` `:109` (state dir, load, ETS mirror), `persist_checkpoint` `:244`, `load_checkpoint` `:309`, `ensure_regular_file` `:497`, `resolve_state_dir` `:507-508` | Copied shape, without the debounce (`@debounce_ms` `:47`): an override write is acknowledged only after fsync |
| State dir | `src/lib/aiur/config/paths.ex:60-66` `decision_state_dir/0` (instance- and project-scoped); `:97-110` `progress_retention_state_dir/0` (app-env override, else a leaf under the decision dir) | PROPOSED `epic_overrides_state_dir/0`, a copy with leaf `epic-overrides` |
| Health type | `src/lib/aiur/build_order/lifecycle.ex:1-62` `Aiur.BuildOrder.ProviderHealth` (`state` `:healthy/:stale/:unavailable/:structurally_invalid`, `usable?/1` `:47-51`) | Store health, so C8-T04 handles it like History (C4-T01 §10 decision 1) |
| PubSub | `Phoenix.PubSub.broadcast(Aiur.PubSub, …)` in `src/lib/aiur/build_order/pack_status.ex:228` | Change signal |
| Repository identity | `src/lib/aiur/tracker.ex:153-159` `project_identity/0`; `:162-167` `adapter/0` (`"github"` → `Aiur.GitHub.Tracker`; it calls `Config.settings!()`, which raises when config is invalid); `src/lib/aiur/github/tracker.ex:14` `project_identity/0` = `Config.repo()` | Store is GitHub only; file carries the repository. `init/1` reads these inside `try`, so a config error gives unavailable health, never a crash |
| Supervision | `src/lib/aiur.ex:426-447` children list (`Aiur.DecisionStore`, `Aiur.RecentMergeStore`, `Aiur.ProgressRetention`) under `:rest_for_one` (`:124-125`) | Add the store next to `Aiur.ProgressRetention`. Under `:rest_for_one` a crash restarts every later child (`TicketActivity`, the orchestrator), so `init/1` must never raise or return `{:stop, _}` (§5 step 3) |
| Agent issue number | `src/lib/aiur/agent_runner/tool_executor.ex:327-333` `issue_number_of/1` returns `issue.number` **or** `issue.identifier`; GitHub sets `identifier: to_string(number)` (`src/lib/aiur/github/issues.ex:988`), so the value is often a string | The tool's setter parses it to an integer (§5 step 7) |

C4-T01 (`Aiur.BuildOrder.History`) uses the same pattern, keys rows by issue
number, and scopes the file by the decision dir plus a `repository` field. This
store does the same, so C8-T04 joins the two by number.

### 3.2 CLI path

- `packaging/npm/aiur-cli/libexec/aiur-engine.sh`:
  - usage text `:455-503` (one line per command);
  - `cmd_build_orders` `:3043-3073`: option loop, `exit 64` on a bad option,
    base64 for user strings, then `run_control_rpc "Aiur.AgentControlCLI.…"`;
  - `encode_control_value` `:2861-2863`;
  - `cmd_executor_answer` `:2867-2920`: a write command, with `--executor-id`
    defaulting to `aiur-cli` as the actor (the trust model this CLI copies);
  - `run_control_rpc` `:2463-2480`: an RPC timeout reports "outcome is
    unknown" (exit 124), never success;
  - top-level dispatch: `aiur_engine_main` `:4154`, `case "$cmd" in`
    `:4159-4347` (`build-orders)` arm at `:4234-4236`).
- `src/lib/aiur/agent_control_cli.ex`: `build_orders/1` `:376-378` delegates to
  `BuildOrdersCLI.run/1` inside `guarded/2` (`:3209-3221`, turns a crash or
  `GenServer.call` timeout into an error marker); `control_error/1`
  `:3273-3277`; `exit_marker/1` `:3510-3513`.
- `src/lib/aiur/build_orders_cli.ex:21-33` `run/1`: `--json` prints
  `Jason.encode!`, else human text; returns 0 or 1.
- Tests: `src/test/aiur_engine_test.exs:484-500` stubs `run_control_rpc` and
  asserts the exact RPC expression and `exit 64` cases;
  `src/test/aiur/build_orders_cli_test.exs`.

### 3.3 Agent tool path

- `src/lib/aiur/codex/dynamic_tool.ex:15` `@handlers` list; `:36-38`
  `tool_specs/0` is sent to every harness (`codex/frames.ex:52`,
  `claude/coding_agent.ex:243`, `open_ai_compat/tool_spec.ex:109`).
- `src/lib/aiur/codex/dynamic_tool/ticket_state.ex:1-124`: a tool whose writer
  is injected through `opts` (`:ticket_state_setter`), with argument
  normalisation and `Response.failure(Errors.payload(reason))` on error. This
  is the model for `aiur_set_epic`.
- `src/lib/aiur/agent_runner/tool_executor.ex:53-145` `build/5`: binds each tool
  to the agent's `issue`; `:140-142` passes `ticket_state_setter`. The new
  `epic_setter` is bound the same way, so the daemon, not the agent, names the
  acting ticket.
- `src/lib/aiur/codex/dynamic_tool/errors.ex:10+` `payload/1` clauses;
  `response.ex:9,23` `build/2`, `failure/1`.
- Tests: `src/test/aiur/dynamic_tool_test.exs:85-100` pins the full
  `supportedTools` list (must gain `aiur_set_epic`);
  `src/test/aiur/codex/dynamic_tool/ticket_state_test.exs`.

### 3.4 Agent-workspace guard rules (checked, as the row asks)

- `scripts/aiurdev:538-560` `in_agent_workspace_tree` detects
  `AIUR_AGENT_WORKSPACE` or an `*/aiur-workspaces/*` path; `:728-739` blocks
  only `--test`/`--test3`. Nothing blocks other commands.
- But the CLI cannot be relied on from a workspace:
  - `src/lib/aiur/agent_environment.ex:18` scrubs `RELEASE_NODE`,
    `RELEASE_COOKIE`, `AIUR_RELEASE_NODE`, `AIUR_INSTANCE_KEY` and
    `AIUR_REPO_ROOT` from every agent environment;
  - `aiur-engine.sh:269-278` `aiur_instance_key` hashes the project root, and
    `:291-294` builds the node name from it. In a workspace the root is the
    workspace clone, so the CLI targets a node that does not exist.
- Result: E8-D9's "single CLI or tool call" is met by the CLI for the Executor
  and humans, and by the `aiur_set_epic` tool for agents in workspaces. The
  tool also gives truthful provenance: `agent:<ticket>` is the ticket the
  daemon bound, not a string the agent typed.

### 3.5 Design data

The store holds no pixels. The keys it accepts must be the design's epic keys:
`GENERAL = { bugs, design, infra, docs }` (J:96) and the reserved
`epics.unsorted` (J:116). `colKey = (t) => t.epic || "unsorted"` (J:332) is
what the resolver output feeds.

## 4. Chosen design

### 4.1 Record and file

PROPOSED `Aiur.BuildOrder.EpicOverrides.Override`:

| Field | Type | Meaning |
| --- | --- | --- |
| `number` | `pos_integer` | Issue number in the configured repository |
| `epic` | `String.t()` | A general epic key from the catalog at write time |
| `actor` | `String.t()` | Verified identity: `cli:<who>` or `agent:<ticket>` |
| `source` | `String.t()` | One of `cli:<who>`, `agent:<ticket>`, `backfill-agent` |
| `confirmed` | `boolean` | `false` only when `source == "backfill-agent"` |
| `at` | `DateTime` (UTC) | Write time from the injected clock |
| `seq` | `pos_integer` | Journal sequence of the entry that set it |

File `<epic_overrides_state_dir>/epic-overrides.json`, mode `0600`:

```json
{"version": 1, "repository": "owner/repo", "next_seq": 4,
 "entries": [
  {"seq": 1, "op": "set",   "number": 12, "epic": "bugs", "actor": "cli:kevin",
   "source": "cli:kevin", "confirmed": true,  "at": "2026-10-08T10:00:00Z"},
  {"seq": 2, "op": "set",   "number": 12, "epic": "infra", "actor": "agent:2790",
   "source": "backfill-agent", "confirmed": false, "at": "2026-10-08T10:01:00Z"},
  {"seq": 3, "op": "clear", "number": 12, "actor": "cli:kevin",
   "source": "cli:kevin", "at": "2026-10-08T10:02:00Z"}
 ]}
```

- The journal is the store. The current map is a fold over `entries` in `seq`
  order: `set` puts the override, `clear` removes it. There is no second copy
  that can disagree with the journal.
- Each write call rewrites the whole file with `Fs.atomic_write(path, json,
  fsync: true, mode: 0o600)`. Rename is atomic, so a crash leaves the old or
  the new file, never a torn one.
- `op` values are versioned. The only ops are `set` and `clear`; C13-T03
  confirms with an ordinary `set` entry (`confirmed: true`) and adds no op. A
  loader that sees an unknown `op` treats the file as a newer version (§4.4).

### 4.2 Write rules

- **Batch is atomic.** A call validates every id and the epic first. One bad
  input rejects the whole call and writes nothing.
- **Dedupe.** Repeated ids in one call count once.
- **No-op.** If a ticket already has the same `epic`, `source` and `confirmed`,
  it is reported `unchanged` and gets no journal entry. Anything else is a
  journal entry, including a change of source only (a human taking over a
  backfill guess: `confirmed` goes `false` → `true`).
- **Clear** of a ticket with no override is `unchanged`, no entry.
- **Last write wins (EC-13).** The GenServer serialises calls. Two writers on
  one ticket produce two entries; the later `seq` is the current value. Each
  result names the `previous` override, so a writer can see that it replaced
  someone else's.
- **Limits.** Up to 200 ids per call (`{:error, {:too_many_ids, 200}}`). The file
  is capped at 8 MiB; a write that would pass the cap is refused with
  `{:error, :epic_overrides_full}` and nothing is written.
- **Valid inputs.**
  - epic: in the catalog `settings.build_order.epics |> Enum.map(& &1.key)`,
    read with `Config.settings/0` at each write. `unsorted` is refused by an
    explicit check even if a catalog contains it (§10 decision 4); anything
    else is `{:error, {:unknown_epic, key, known}}`. If `Config.settings/0`
    returns `{:error, _}`, the write is refused with
    `{:error, :epic_config_unavailable}` and nothing is written. The store never
    falls back to the default four keys (same rule as C8-T04 row `epics`).
  - epic shape in the engine: `^[a-z0-9][a-z0-9_-]{0,63}$` (C5-T01's key
    rule), else exit 64. The catalog check is server-side only.
  - id: `^#?[1-9][0-9]{0,9}$` (engine and server both check).
  - who (`--as`): `^[A-Za-z0-9._-]{1,64}$`; default `$USER`. An empty or
    invalid `$USER` with no `--as` is exit 64, never `cli:` (same rule as
    C6-T04 V-E3).
  - source from the CLI: `cli` (default, becomes `cli:<who>`) or
    `backfill-agent`. `agent:<n>` is refused from the CLI: only the tool can
    claim an agent identity.

### 4.3 Public API (PROPOSED)

```elixir
# Writes: GenServer.call, synchronous, acknowledged after fsync
@spec set(String.t(), [pos_integer()], %{actor: String.t(), source: String.t()}, keyword()) ::
        {:ok, %{generation: non_neg_integer(), results: [result()]}} | {:error, term()}
@spec clear([pos_integer()], %{actor: String.t(), source: String.t()}, keyword()) ::
        {:ok, %{generation: non_neg_integer(), results: [result()]}} | {:error, term()}
#   result :: %{number: n, status: :changed | :unchanged, previous: Override.t() | nil}
#   (C13-T04 later adds status :kept_existing; consumers must not assume two values)
#   generation = the highest seq in the journal (0 when empty), so it is persisted
#   and never goes backwards across a restart
#   opts: :server, :now (clock, tests)
@spec catalog(keyword()) :: {:ok, [%{key: String.t(), label: String.t()}]} | {:error, :epic_config_unavailable}
#   configured general epics in config order; used by `aiur epic list`
#   start opts (tests): :state_dir, :repository, :settings_fun (default &Aiur.Config.settings/0),
#   :writer (default &Aiur.Fs.atomic_write/3), :max_bytes, :name

# Reads: ETS mirror, lock-free
@spec get_many([pos_integer()], keyword()) ::
        {:ok, %{pos_integer() => Override.t()}, ProviderHealth.t()} | {:error, ProviderHealth.t()}
@spec all(keyword()) :: {:ok, %{pos_integer() => Override.t()}, ProviderHealth.t()} | {:error, ProviderHealth.t()}
@spec journal([pos_integer()], keyword()) :: {:ok, [map()]} | {:error, ProviderHealth.t()}
@spec health(keyword()) :: ProviderHealth.t()

# Signal
@spec subscribe() :: :ok
# topic "build-order-epic-overrides:changed"
# message {:epic_overrides_changed, %{generation: g, changed: [n], health: ProviderHealth.t()}}
```

`get_many` returns only tickets that have an override. A missing key means
"no override", and that is only true when the result is `{:ok, …}`. A
consumer that gets `{:error, health}` must not treat it as "no overrides"
(§6).

### 4.4 Health states

| Load result | Health | Reads | Writes |
| --- | --- | --- | --- |
| No file (new install) | `:healthy`, `complete?: true` | `{:ok, %{}, h}` (truthfully empty) | allowed; first write creates the file |
| Valid file | `:healthy`, `complete?: true` | `{:ok, map, h}` | allowed |
| JSON or entry fails to decode | `:unavailable`, failure `:epic_overrides_corrupt` | `{:error, h}` | refused `{:error, :epic_overrides_unavailable}` |
| `version` > 1 or unknown `op` | `:unavailable`, `:epic_overrides_version_unsupported` | `{:error, h}` | refused |
| `repository` differs from the configured one | `:unavailable`, `:epic_overrides_repository_mismatch` | `{:error, h}` | refused |
| Symlink, non-regular file, or over 8 MiB | `:unavailable`, `:epic_overrides_unsafe_path` | `{:error, h}` | refused |
| Tracker is not GitHub, or no repository | `:unavailable`, `:epic_overrides_unsupported_tracker` | `{:error, h}` | refused |
| State dir cannot be resolved (`decision_state_dir/0` returns `{:error, _}`) or `mkdir_p` fails | `:unavailable`, `:epic_overrides_state_dir_unavailable` | `{:error, h}` | refused |
| Store not running | `:unavailable`, `:epic_overrides_not_running` | `{:error, h}` | `{:error, :epic_overrides_not_running}` |

An unavailable file is never rewritten, renamed or deleted by the store
(§10 decision 5).

### 4.5 CLI

```text
aiur epic set <epic> <ids…> [--source cli|backfill-agent] [--as <who>] [--json]
aiur epic clear <ids…> [--as <who>] [--json]
aiur epic show [<ids…>] [--json]
aiur epic list [--json]
```

- Engine `cmd_epic` parses and validates, base64-encodes `epic` and `who`, and
  calls `run_control_rpc "Aiur.AgentControlCLI.epic([action: :set, …])"`.
- PROPOSED `Aiur.EpicCLI.run/1` formats output, called through
  `AgentControlCLI.epic/1` inside `guarded("epic", …)`, with
  `Keyword.put(:error_fun, &control_error/1)` and `exit_marker/1`, exactly as
  `build_orders/1` (`agent_control_cli.ex:376-378`).
- `list` prints `bugs  Bugs` one line per configured general epic, in config
  order (JSON `{"ok": true, "epics": [{"key": "bugs", "label": "Bugs"}]}`). If
  config cannot be read it prints
  `aiur: epic list: epic config unavailable` and exits 1; it never prints the
  default four as a fallback. Feature epics are not listed: they are not
  override targets (§10 decision 3).
- Human output:
  - `set bugs: #12 #14 changed, #13 unchanged (source cli:kevin)`. A replaced
    override from someone else adds `#12 was infra by agent:2790 (backfill-agent, unconfirmed)`.
  - `show` prints one line per ticket: `#12  bugs  cli:kevin  confirmed  2026-10-08T10:00:00Z`.
    A ticket with no override prints `#13  no override`. A stored key no longer
    in the catalog prints `#12  docs (not a configured epic; ignored)`.
  - `show` with an unavailable store prints
    `aiur: epic show: epic overrides unavailable (epic_overrides_corrupt)` and
    exits 1. It never prints "no override" in that case.
- JSON: `{"ok": true, "generation": 7, "results": [{"number": 12, "status":
  "changed", "epic": "bugs", "previous": {…} | null}]}`; `show` gives
  `{"ok": true, "health": {…}, "overrides": [{…, "epic_known": true}]}`, and
  `{"ok": false, "health": {…}}` with exit 1 when unavailable.
- Exit codes: 0 done; 1 refused or unavailable (message on stderr through the
  error marker); 64 usage; 124 RPC timeout (engine, outcome unknown).

### 4.6 Agent tool `aiur_set_epic`

Input schema (`additionalProperties: false`):

| Field | Type | Rule |
| --- | --- | --- |
| `epic` | string | required unless `clear` is true |
| `ids` | array of integers, 1..200 | optional; default is the agent's own ticket |
| `clear` | boolean | optional; removes overrides instead |
| `backfill` | boolean | optional; source becomes `backfill-agent`, `confirmed: false` |

There is no `source` or `actor` field. `ToolExecutor` binds the setter to the
agent's issue, so `actor` is always `agent:<issue number>`, and `source` is that
same string unless `backfill` is true. `clear: true` together with `epic` is
refused (`{:error, :invalid_epic_arguments}`); so is `clear` with `backfill`.
An unknown epic returns the `{:unknown_epic, key, known}` error with the list of
known keys, so an agent (which cannot run `aiur epic list`, §3.4) can read the
valid keys from the error. The handler implements
`@behaviour Aiur.Codex.DynamicTool.Handler` (`tools/0`, `specs/0`,
`execute/3`) like `ticket_state.ex:23,58-93`. Description (short, it goes to every
agent): "Put tickets into a general epic (or clear it). Records you as the
actor. Use for categorising tickets; batch up to 200 ids."

## 5. Implementation steps

1. `src/lib/aiur/config/paths.ex`: add `epic_overrides_state_dir/0` next to
   `progress_retention_state_dir/0` (`:97-110`): app-env
   `:epic_overrides_state_dir`, else `Path.join(decision_state_dir, "epic-overrides")`.
   Add a case to `src/test/aiur/config_paths_test.exs`.
2. PROPOSED `src/lib/aiur/build_order/epic_overrides/override.ex`: struct,
   `from_entry/1` and `to_entry/1` with strict decoding (every field present and
   typed, `op in ["set", "clear"]`).
3. PROPOSED `src/lib/aiur/build_order/epic_overrides.ex` (GenServer):
   - `init/1`: `Process.flag(:trap_exit, true)`; protected ETS mirror named from
     the server name (as `progress_retention.ex:510-513` `mirror_table/1`;
     `progress_retention.ex:112` makes its table `:public`, this one is
     `:protected` because only the server writes); resolve dir
     and repository (`opts[:repository]`, else `Aiur.Tracker.project_identity/0`
     when `Tracker.adapter/0` is `Aiur.GitHub.Tracker`, both inside `try`);
     `File.mkdir_p` with its result checked (not `:ok =` as
     `progress_retention.ex:117`); `lstat` + regular-file + size check, then
     load and fold; insert the map and `{:__health__, h}`. Every failure here
     is an unavailable health row (§4.4); `init/1` always returns `{:ok, _}`.
   - Reads go to ETS from the caller. A missing table (`ArgumentError` from
     `:ets.lookup`) is rescued and returned as `:epic_overrides_not_running`.
   - `handle_call({:write, op, epic, numbers, provenance})`: refuse unless
     healthy; validate (catalog from `opts[:settings_fun]`, default
     `Config.settings/0`, mapped to keys; ids; limits);
     compute results; if nothing changed reply without a file write; else
     append entries, encode, check the size cap, `Fs.atomic_write/3`; only on
     `:ok` update state, ETS, generation, and broadcast. On a write error,
     state is unchanged and the caller gets `{:error, {:write_failed, reason}}`.
4. `src/lib/aiur.ex`: add `Aiur.BuildOrder.EpicOverrides` to the children list
   next to `Aiur.ProgressRetention` (`:447`).
5. PROPOSED `src/lib/aiur/epic_cli.ex` (`Aiur.EpicCLI.run/1`) and
   `AgentControlCLI.epic/1` (next to `build_orders/1`, `:376`).
6. `aiur-engine.sh`: `cmd_epic` (after `cmd_build_orders`) with actions
   `set|clear|show|list`, the `epic)` arm in the top-level dispatch, and four
   usage lines in `:455-503`.
7. PROPOSED `src/lib/aiur/codex/dynamic_tool/epic.ex` (`aiur_set_epic`); add it
   to `@handlers` (`dynamic_tool.ex:15`); add `epic_setter` in
   `tool_executor.ex` `build/5` (next to `:140-142`). The setter takes the
   number from `issue_number_of/1` (`:327-333`), which may be an integer or a
   string such as `"2790"`. It parses a string with `Integer.parse/1` and
   accepts only a whole positive integer; otherwise it returns
   `{:error, :no_issue_number}` and writes nothing. It then calls
   `EpicOverrides.set/4` or `clear/3` with `actor: "agent:#{number}"`. Add
   error clauses to `errors.ex` for the new reasons (`:invalid_epic_arguments`,
   `{:unknown_epic, _, _}`, `:epic_overrides_unavailable`,
   `:epic_config_unavailable`); others fall to the generic `payload/1` at
   `errors.ex:417`.
8. Docs: `website/docs-app/reference/cli.md` (a row per subcommand, in a new
   "Build history commands" table next to "Dashboard page commands" `:197`);
   `website/docs-app/concepts/ticket-lifecycle.md` (one line for the tool next
   to `aiur_set_ticket_state`).

## 6. Non-happy paths

- **Store unavailable.** Reads return `{:error, health}`. C8-T04 must show the
  epic column assignment as degraded (it already handles `ProviderHealth`), and
  must not draw tickets as if no override existed. `aiur epic show` exits 1 with
  the failure atom. Writes are refused, so an agent sees an error, not a lost
  write.
- **Corrupt file recovery.** The store never resets it. The operator moves the
  file aside and restarts; the store then starts empty and healthy. This is in
  the `cli.md` entry. Overrides cannot be rebuilt from GitHub, so silent reset
  would be data loss.
- **Write failure** (disk full, permission). `Fs.atomic_write/3` returns an
  error; state, ETS and generation stay unchanged; the caller gets
  `{:error, {:write_failed, reason}}` and the CLI exits 1.
- **RPC timeout.** The engine prints "outcome is unknown" (exit 124,
  `aiur-engine.sh:2470-2471`). Retrying the same `set` is safe: an applied
  write shows as `unchanged` on retry.
- **Concurrency (EC-13).** Two agents, or an agent and the CLI, writing one
  ticket: serialised, both journaled, later `seq` wins, `previous` names the
  loser. A label added on GitHub at the same time does not conflict: the
  resolver ranks the override above labels (C5-T02).
- **Config drops an epic key.** Stored overrides with that key stay in the
  journal. `show` marks them `epic_known: false`. The resolver must skip them
  (interface note for C5-T02, §11). New writes with that key are refused.
- **Config cannot be read** (`Config.settings/0` returns `{:error, _}`, for
  example a bad edit to `.aiur/config`). Writes and `aiur epic list` are
  refused with `:epic_config_unavailable` (exit 1). Reads of stored overrides
  still work, because they do not need the catalog; `show` then reports
  `"epic_known": null` (text: `(epic config unavailable)`) rather than `false`
  or `true`. Never fall back to the default keys (V-31, V-22b).
- **Ticket has an owning feature.** The override is stored, but the resolver
  returns the feature epic first (C5-T02 order). `set` does not check
  features; C6 does not exist yet when this lands.
- **Number not a real ticket.** Stored as given (§10 decision 6).
- **Non-GitHub tracker.** Store unavailable with
  `:epic_overrides_unsupported_tracker`; the tool returns that error. Build
  history is GitHub only (C4-T01).
- **Trust.** The CLI user holds the distribution cookie, so `--as` is trusted the
  same way `executor-answer --executor-id` is (`aiur-engine.sh:2868`). An agent
  cannot claim a CLI identity through the tool, and cannot claim an agent
  identity through the CLI. All inputs are keys, numbers and identities checked
  by regex; there is no free text, so there is nothing to sanitise for display.
- **Privacy.** File is `0600` in the daemon-private decision dir.

## 7. Compatibility and rollout

- New store, new file, new CLI verb, new tool. No migration. No config key (the
  epic list is C5-T01's).
- Older releases ignore the file. A newer file is refused, not rewritten
  (§4.4), so a roll-back then roll-forward loses nothing.
- Adding a tool changes the tool list every agent receives; the description is
  kept to one short paragraph.
- Rollback: revert the PR. The file stays on disk unused.

## 8. Verification

PROPOSED `src/test/aiur/build_order/epic_overrides_test.exs` (`async: false`,
store started per test with `state_dir:` from `tmp_root!/1`
(`test/support/test_support.exs:167`), `repository: "acme/app"`, `settings_fun:`
stub returning `{:ok, %{build_order: %{epics: [%{key: "bugs", label: "Bugs"}, …]}}}`
with the default four keys, `now:` fixed clock).
No test reads `~/.aiur` or the live dir.

| ID | Test | Input → expected | Fails when (mutation) |
| --- | --- | --- | --- |
| V-1 | "set records actor, source, at, confirmed" | `set("bugs", [12], cli:kevin)` → `get_many([12])` has all fields; file decodes to one `set` entry | drop any field from the entry |
| V-2 | "unknown epic is rejected and nothing is written" | `set("bugz", [12], …)` → `{:error, {:unknown_epic, "bugz", [...]}}`; file absent | remove the catalog check |
| V-3 | "unsorted is not a settable epic, even if a catalog lists it" | `settings_fun` whose epics include a `unsorted` entry; `set("unsorted", …)` → `{:error, {:unknown_epic, …}}`; file absent | remove the explicit `unsorted` check (the catalog alone would accept it) |
| V-4 | "a batch with one bad id writes nothing" | `set("bugs", [12, 0], …)` → error; `get_many([12])` empty | validate per id inside the write loop |
| V-5 | "concurrent writers: last seq wins, both journaled" (EC-13) | two `Task`s set 12 to `bugs` and `infra`; then `journal([12])` has 2 entries and current epic equals the higher-`seq` entry's epic | replace journal append with overwrite of the ticket's entry |
| V-6 | "same write twice is unchanged and not journaled" | set twice → second result `:unchanged`; journal length 1; generation unchanged | always append |
| V-7 | "source change is journaled and confirms" | backfill set then cli set same epic → `:changed`, `confirmed: true`, journal 2 | compare epic only for no-op |
| V-8 | "backfill-agent is unconfirmed" | `set(…, source: "backfill-agent")` → `confirmed: false` | hard-code `confirmed: true` |
| V-9 | "clear removes and is journaled" | set then clear → `get_many` empty; journal has `clear` | clear by deleting entries |
| V-10 | "reload folds the journal, including clears" | set 12 `bugs`, set 13 `infra`, clear 13; stop; start → `all/1` is exactly `%{12 => bugs}`, generation 3 | fold ignores `clear`; generation recomputed from 0 |
| V-11 | "corrupt file is unavailable, not empty" | write `{bad` → `get_many` returns `{:error, %{state: :unavailable, failure: :epic_overrides_corrupt}}`; file bytes unchanged | return `{:ok, %{}, h}` on decode failure |
| V-12 | "newer version is refused and untouched" | `version: 2` → unavailable; `set` refused; bytes unchanged | accept any version |
| V-13 | "repository mismatch is unavailable" | file for `other/app` → unavailable | skip repository check |
| V-14 | "symlink path is refused" | symlink at path → `:epic_overrides_unsafe_path` | read through symlink |
| V-15 | "not running reads are unavailable" | `get_many([1], server: :missing)` → `{:error, %{failure: :epic_overrides_not_running}}` | return `{:ok, %{}, _}` |
| V-16 | "write failure leaves state unchanged" | inject a failing writer (opt `:writer`) → `{:error, {:write_failed, _}}`; `get_many` empty; generation unchanged | update state before the write |
| V-17 | "file is owner-only" | `File.stat!(path).mode &&& 0o777 == 0o600` | drop `mode:` |
| V-18 | "size cap refuses the write" | `max_bytes: 300` opt; second write → `{:error, :epic_overrides_full}`; file is the first write | skip the cap |
| V-19 | "change broadcast names changed numbers" | `subscribe/0`; set 12,13 → `{:epic_overrides_changed, %{changed: [12, 13]}}`; unchanged write sends nothing | broadcast on every call |
| V-20 | "id limit" | 201 ids → `{:error, {:too_many_ids, 200}}`; 200 ids → `:ok` | remove the limit |
| V-30 | "catalog comes from config, not a built-in list" | `settings_fun` with only `ops`: `set("ops", [12])` → `:ok`; `set("bugs", [12])` → `{:error, {:unknown_epic, "bugs", ["ops"]}}` | hard-code the default four keys |
| V-31 | "config error refuses the write, never falls back to defaults" | `settings_fun` returns `{:error, :boom}` → `set("bugs", [12])` is `{:error, :epic_config_unavailable}`; file absent; `catalog/1` is `{:error, :epic_config_unavailable}` | fall back to the default keys on error |
| V-32 | "init never crashes the supervisor" | `state_dir:` points at a regular file (so `mkdir_p` fails) → `start_supervised` returns `{:ok, _}`; `health/1` is `:epic_overrides_state_dir_unavailable`; `set` refused | `:ok = File.mkdir_p(dir)` as in `progress_retention.ex:117` (start fails) |

PROPOSED `src/test/aiur/epic_cli_test.exs` (store started per test, injected
by `server:`):

| ID | Test | Expected | Fails when |
| --- | --- | --- | --- |
| V-21 | "show on an unavailable store exits 1 and never says no override" | corrupt fixture → exit 1; output `=~ "unavailable (epic_overrides_corrupt)"`; `refute =~ "no override"` | `show` maps `{:error, _}` to an empty list |
| V-22 | "show marks a key no longer configured" | entry `docs`, catalog without `docs` → `"docs (not a configured epic; ignored)"`, JSON `epic_known: false` | print the key as normal |
| V-22b | "show with unreadable config marks epic_known null" | stored `bugs`; `settings_fun` error → exit 0, JSON `epic_known == nil`, text `=~ "epic config unavailable"` | report `epic_known: true` (or `false`) when the catalog is unknown |
| V-23 | "set JSON lists changed, unchanged and previous" | JSON has `results` with `previous.actor == "agent:2790"` | omit `previous` |
| V-24 | "cli refuses an agent source" | `source: "agent:5"` → exit 1 | accept any source |
| V-33 | "list prints configured epics and refuses a fallback" | `settings_fun` with `ops`/`Ops` → text `ops  Ops`, JSON `epics == [%{"key" => "ops", "label" => "Ops"}]`; `settings_fun` error → exit 1, output `=~ "epic config unavailable"`, `refute =~ "bugs"` | print the default four keys |

`src/test/aiur_engine_test.exs` (stub `run_control_rpc` as at `:484-500`):

- V-25: `cmd_epic set bugs 12 '#13' --as kevin --json` → RPC
  `Aiur.AgentControlCLI.epic([action: :set, epic: Base.decode64!("YnVncw=="), ids: [12, 13], who: Base.decode64!("a2V2aW4="), source: :cli, json: true])`.
- V-26: exit 64 for: no epic; no ids; id `abc`; id `0`; epic `Bugs`
  (uppercase); `--as 'a b'`; `USER=` with no `--as`; `--source agent:3`;
  unknown option; `show --source x`; `list 12`; unknown action `epic move`.
- V-25b: `cmd_epic list --json` → RPC `Aiur.AgentControlCLI.epic([action: :list, json: true])`.

PROPOSED `src/test/aiur/codex/dynamic_tool/epic_test.exs` and
`src/test/aiur/agent_runner/tool_executor_test.exs` additions:

- V-27: tool with `ids` omitted calls the setter with the bound issue's
  number. Fixture issue has `identifier: "77"` and no `number` (the GitHub
  shape, `issues.ex:988`) → setter gets `[77]` and `actor: "agent:77"`; an
  issue with `identifier: "ENG-7"` → `{:error, :no_issue_number}`, no write.
  Mutation: read `issue.number` only → fails.
- V-28: tool records `actor: "agent:<bound number>"`; an argument `source` or
  `actor` is rejected by the schema (`additionalProperties: false`) and by
  normalisation (`{:error, :invalid_epic_arguments}`). Mutation: take `actor`
  from arguments → fails.
- V-29: `backfill: true` → source `backfill-agent`, `confirmed: false`.
- V-29b: `clear: true` with `epic` → `{:error, :invalid_epic_arguments}`, setter
  not called. Mutation: ignore `epic` when `clear` is set → fails.
- `src/test/aiur/dynamic_tool_test.exs:85-100`: add `"aiur_set_epic"` to the list.

**Mutation check (AGENTS.md).** In a worktree, for each row above, revert the
named production hunk, run
`mise exec -- mix test test/aiur/build_order/epic_overrides_test.exs test/aiur/epic_cli_test.exs test/aiur_engine_test.exs test/aiur/codex/dynamic_tool/epic_test.exs test/aiur/agent_runner/tool_executor_test.exs test/aiur/dynamic_tool_test.exs test/aiur/config_paths_test.exs`
from `src/`, confirm the test fails, restore, confirm it passes. Before each run,
`git status --porcelain` shows only that revert. Record the commands in the PR.

**Validation commands.** `cd src && mise exec -- mix test` for the files above,
then `mise exec -- mix format --check-formatted`, `mix credo`, and the CI
`lint` job. Isolate `HOME` and unset `GITHUB_TOKEN`/`GH_TOKEN` for local runs
(memory note: `mix test` can overwrite the live agent token).

**Manual.** With `aiurdev --bg` from the Executor root: `aiurdev epic set bugs 12
13`, `aiurdev epic show 12 13 --json`, `aiurdev epic clear 13`, `aiurdev epic list`; check the file
mode and the journal. The tool path is covered by C13-T04's first real run.
This ticket has no TUI or dashboard surface, so the AGENTS.md TUI recipe does
not apply.

## 9. Pixel parity

This ticket draws nothing, so the C1-T02 side-by-side harness has nothing to
compare for it. Parity depends on it in one way: the keys it accepts must be
the design's keys, so a ticket set to `bugs` lands in the design's Bugs column
(`GENERAL`, J:96) and a ticket with no override and no label lands in
`unsorted` (J:116, `colKey` J:332). V-2/V-3 with the default catalog
(`bugs`, `design`, `infra`, `docs`) check this. Hue and icon come from C5-T01
config, not from this store.

## 10. Decisions made without the owner

1. **Agents use a tool, not the CLI.** The row asks for a CLI "callable from
   agent workspaces". The workspace environment cannot reach the daemon
   (§3.4), and a CLI string cannot prove which agent called it. The tool
   `aiur_set_epic` is the agent path; the CLI is the Executor and human path.
   Both call the same store function. E8-D9 allows "a CLI or tool call".
2. **`clear` and `show` are added** to the row's `set`. Without `clear`, a wrong
   override can only be replaced, never removed. Without `show`, S-8's default
   ("visible through `aiur epic`") has no command.
3. **Overrides accept general epic keys only.** C5-T02 ranks the feature epic
   above the override, so an override to a feature epic would never take
   effect. Feature epic choice belongs to C6-T04 (`feature add`).
4. **`unsorted` is not settable.** Unsorted means "no signal". To remove a guess,
   use `clear`.
5. **A bad file is never reset or quarantined by the store.** Overrides are the
   only copy (no GitHub rebuild, unlike C4-T01). The store reports unavailable
   and refuses writes until the operator moves the file aside.
6. **Ticket numbers are not checked against GitHub or History.** Checking needs
   a read per id or a dependency on C4-T01 completeness. An override for a
   number that is not a ticket is never drawn (C8-T04 joins by number).
7. **No compaction, 8 MiB cap.** About 150 bytes an entry gives about 55,000
   entries; the full history backfill is a few thousand. The cap refuses loudly
   rather than dropping journal entries. `ponytail:` comment at the cap names
   the upgrade (compact to the latest entry per ticket plus a count).
8. **Synchronous fsync write per call, no debounce.** An agent's acknowledged
   write must survive a crash. Writes are rare (classification), so the cost is
   small.
9. **`--as` defaults to `$USER`**, mirroring `executor-answer --executor-id`'s
   trust model. No new authentication.
10. **No `--reason`.** E8-D9 asks for who and when. Estimate overrides (C7-T03)
    need a reason; epic overrides do not.
11. **`aiur epic list` is added** (C5-T04 request 2, C13-T00 runbook step 2).
    A repository can replace the default keys (C5-T01), and a human or the
    Executor cannot pick a key it cannot see. It lists configured general
    epics only, because only those are override targets (decision 3). Agents
    get the same list from the tool's unknown-epic error, since they cannot
    run the CLI (§3.4). Cost: one read action, one test row (V-33).
12. **No separate Elixir argv parser** (C5-T04 request 1 asks for
    `parse_args/1`). Parsing lives in the engine, as for every other command
    (`cmd_build_orders`, `cmd_executor_answer`). A second parser in Elixir would
    be a second copy of the rules. C5-T04's T2 can check documented commands
    against the real rules without a daemon by sourcing the engine with a stub
    `run_control_rpc`, as `aiur_engine_test.exs:484-500` does and V-25/V-26 do.
13. **The catalog is read from config at each write**, not cached at start.
    A config reload then takes effect without a store restart, and the store
    never holds a second copy of the key list that could disagree with C8-T04.
14. **Source vocabulary follows the README row (`cli:<who>`).** Settled
    2026-10-08: C6-T04 also records the CLI source string `cli:<who>`, so both
    stores use the same source string and both carry the actor.

## 11. Completion and handoff

**Acceptance checklist.**

- [ ] `aiur epic set|clear|show|list` work through the shared engine with `--json`;
      every exit-64 case in V-26 holds.
- [ ] An unknown epic is rejected with the list of known keys; nothing is written.
- [ ] Every write is journaled with actor, at, source and confirmed; last write wins.
- [ ] `aiur_set_epic` records `agent:<bound ticket>`; it cannot be told another actor.
- [ ] `backfill-agent` writes are `confirmed: false`.
- [ ] An unavailable store never reads as "no overrides" in the API, the CLI
      text, or the CLI JSON (V-11, V-15, V-21).
- [ ] Unknown epic keys come from config, never a built-in list; a config
      error refuses writes and `list` (V-30, V-31, V-33).
- [ ] V-1..V-33 (with V-25b, V-29b) pass, and each fails with its production hunk reverted
      (commands recorded in the PR).
- [ ] `reference/cli.md` and `concepts/ticket-lifecycle.md` updated in the same PR.

**Interface notes for neighbour rows.**

- **C8-T04** (ticket index assembler). Settled 2026-10-08: C8-T04 reads with
  `EpicOverrides.all/1` or `get_many/2`, subscribes with
  `EpicOverrides.subscribe/0` to `"build-order-epic-overrides:changed"`, and
  maps a failure to `override: :unknown`.
- **C13-T04** already uses `aiur_set_epic` with `backfill: true` (its §3.1). It
  adds a guard to `EpicOverrides.set/4` with a new result status
  `:kept_existing`; §4.3 leaves the status set open for it.
- **C6-T04** already adds its own agent tool `aiur_feature`. Settled
  2026-10-08: its CLI source string is `cli:<who>`, as here (§10 decision 14).
- **C5-T02** already skips an override whose key is not a general key
  (`:override_unknown_epic`) and takes `:unknown` for an unreadable store; C8-T04
  maps this store's `{:error, health}` to `:unknown`. It does not provide a
  catalog function; settled 2026-10-08: this ticket reads the configured keys
  from `settings.build_order.epics` itself (no `Epics.general_keys/1`).
- **C5-T04** request 1 (Elixir `parse_args/1`) is declined (§10 decision 12);
  request 2 (`aiur epic list`) is met (§10 decision 11).
- **C13-T00** runbook step 2 can use `aiur epic list --json`.
- **C13-T03.** Settled 2026-10-08: `aiur epic confirm` writes an ordinary
  `set` entry with `confirmed: true`; there is no `confirm` journal op (§4.1).
- **C5-T04** teaches agents `aiur_set_epic` and the Executor `aiur epic set`.

**Docs.** `website/docs-app/reference/cli.md`,
`website/docs-app/concepts/ticket-lifecycle.md`. C12-T07 later links them from
the build history concepts page.

**Sources.** tickets/README.md row C5-T03; chunks.md C5; plan.md §8 (EC-13), §10
items 14, 15, 27; decisions.md E8-D1, E8-D9, E8-D10; DESIGN-E8 item 10, S-8;
`design-source/assets/build.js` J:96, J:116, J:332; the code in §3.

**Remaining blocker.** DESIGN-E8 sign-off; MP-E8-C5-T02 merged.

## Review log

Adversarial review, 2026-10-08 (feasibility, coherence, design, scope lenses;
every cited path re-opened at `58854d4c8`).

1. **Catalog source fixed.** The ticket called PROPOSED
   `Aiur.BuildOrder.Epics.general_keys/1` from C5-T02 and named C5-T01's schema
   `BuildHistory`. C5-T02 says it provides no catalog function, and C5-T01 names
   `settings.build_order.epics` / `Aiur.Config.Schema.BuildOrderEpic`. Now read
   with `Config.settings/0` (`config.ex:62-63`) at each write, injected as
   `settings_fun:` in tests; a config error refuses writes (V-30, V-31, V-22b).
2. **`unsorted` test made non-vacuous.** V-3 now uses a catalog that contains
   `unsorted`, so removing the explicit check fails it.
3. **Agent issue number.** `issue_number_of/1` returns a string for GitHub
   issues (`identifier: to_string(number)`, `issues.ex:988`); the setter now
   parses it, and V-27 uses that fixture shape.
4. **Supervision safety.** Under `:rest_for_one`, a crashing `init/1` would
   restart every later child. `init/1` now never raises; `mkdir_p` and config
   failures become health rows (new §4.4 row, V-32).
5. **Line citation fixed.** Engine top-level dispatch is `:4159-4347`
   (`aiur_engine_main` `:4154`), not `:4166-4342`.
6. **`aiur epic list` added** (C5-T04 and C13-T00 depend on it); C5-T04's
   `parse_args/1` request declined with a reason (§10 decisions 11, 12).
7. **Engine checks added**: epic key shape, empty `$USER`, `list` arguments,
   unknown action (V-26, V-25b); tool refuses `clear` with `epic` (V-29b).
8. **V-10 strengthened** to include a `clear` and check generation after restart;
   `generation` defined as the highest journal seq (persisted).
9. **Mutation-check command** now lists every test file the ticket touches.
10. **Interface notes refreshed.** C8-T04, C13-T04 and C6-T04 ticket files
    already carry the predecessor, signal and agent-tool fixes the notes asked
    for; the remaining gap is the README row for C8-T04. Added C13-T04's
    `:kept_existing` status and the C6-T04 source-string difference.
11. §3 table: added `github/tracker.ex:14`, `tool_executor.ex:327-333`,
    and the `ticket_state.ex` behaviour lines (`:23`, `:58-93`).

All other cited paths, symbols and lines were checked and match. Design keys
(`GENERAL` J:96, `epics.unsorted` J:116, `colKey` J:332) match `build.js`.
All nine brief §9 sections are present.
- Reconciliation 2026-10-08 (coordinator): C13-T03 confirms through an ordinary `set` entry with `confirmed: true` (no `confirm` journal op; §1, §4.1, §11), C6-T04 source string now `cli:<who>` (§10 decision 14, §11), C8-T04 subscription and C5-T02 catalog hand-offs marked settled (no `general_keys/1`), README-row request removed.
