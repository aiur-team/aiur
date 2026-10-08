---
ticket_id: MP-E8-C6-T04
feature_id: MP-E8
chunk_id: MP-E8-C6
bucket: 2-platform
title: "`aiur feature` CLI and the agent `aiur_feature` tool"
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C6-T01, MP-E8-C6-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-13]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C6-T04 — `aiur feature` CLI and the agent `aiur_feature` tool

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C6 (features).
- **User value.** An operator or an agent can create a feature, put tickets in
  it in one batch call, mark "also affects" links, set the original-scope
  baseline, and read the result. Every change records who made it, how, and
  when (E8-D9, E8-D11). Without this ticket the registry from C6-T01 has no
  writer except labels (C6-T02) and the Build Order import (C6-T03).
- **Deliverables.**
  1. `aiur feature create|add|remove|also|baseline|edit|show` in the shared
     launcher engine, so `aiur` and `aiurdev` both get it. (`edit` is one
     verb beyond the README row; see "Decisions" 10.)
  2. PROPOSED `Aiur.FeatureCLI` (Elixir): argument validation, the calls into
     the C6-T01 registry, human and `--json` output. One code path
     (`apply_op/2`) for both callers below.
  3. PROPOSED dynamic tool `aiur_feature` (`Aiur.Codex.DynamicTool.Feature`),
     so a daemon agent makes the same change with one tool call. The daemon
     fixes the actor to `agent:<issue number>`.
  4. `website/docs-app/reference/cli.md` rows and section, and the `usage()`
     lines.
- **Non-goals.** Feature statistics and progress (C6-T05). Label writes (C6-T02
  does them, paced). Feature delete and feature-epic removal (C6-T01 decision 8
  gives no store API for them). Feature suggestions (plan §10 item 14). Epic
  commands (C5-T03). Skill and prompt guidance (C5-T04). A `confirm` verb and a
  `--unconfirmed` filter (C13-T03 adds both to this CLI, waits on S-8). A
  "retry failed labels" verb (C6-T02 `retry/1` exists; failed items also retry
  once per daemon boot; see "Decisions" 11). No GitHub reads or writes from
  this ticket (EC-32).

## Dependencies and blockers

- **DESIGN-E8** (every MP-E8 ticket). This ticket has no visual element; the
  gate matters because S-8 says unconfirmed classifications are visible only
  "through `aiur epic` / `aiur feature show --json`" (DESIGN-E8 line 108). If
  Kevin's S-8 answer adds a board treatment, this ticket's JSON fields stay the
  source for it.
- **MP-E8-C6-T01** gives the registry this ticket writes. Its §4.4 API
  (PROPOSED, `Aiur.BuildOrder.Features`) is what this ticket calls; names below
  are C6-T01's, not new ones:
  - writes: `create(slug, %{label, hue | nil, epics | nil, …}, meta)`,
    `update_feature(slug, %{label?, hue?, to?, public_ref?}, meta)`,
    `add_epic(slug, %{key, label}, meta)`,
    `add(slug, ns, meta ++ [epic: key, move: bool])`, `remove(slug, ns, meta)`,
    `also(slug, ns, meta ++ [remove: bool])`, `set_baseline(slug, meta)`; each
    returns `{:ok, %{generation, changed: [n], slugs}}` or `{:error, reason}`;
    a call that changes nothing appends nothing. **One record per call**, so a
    batch is all-or-nothing (C6-T01 §4.2).
  - errors used here: `{:owned_elsewhere, [{n, slug}]}`, `{:not_member, [n]}`,
    `{:owner_cannot_also, [n]}`, `{:unknown_feature, slug}`,
    `{:unknown_epic, key}`, `{:feature_exists, slug}`, `:batch_too_large`
    (> 1,000), `:features_not_running`, `:version_unsupported`,
    `:state_dir_unavailable`, `:unsafe_path`, `{:journal_append_failed, r}`.
  - reads: `snapshot(opts)` → `{:ok, %{features, owners, also, generation,
    health}}` | `{:error, %ProviderHealth{}}`; `journal(slug, opts)`.
  - `meta` is `[source:, actor:]` plus optional `confirmed:`. `source` must
    match `^(cli|agent|label|inherited|import):[A-Za-z0-9._\-\[\]]{1,64}$|^backfill-agent$`;
    `confirmed` defaults to `true`, and to `false` for `backfill-agent`
    (C6-T01 §4.3). This ticket never passes `confirmed`.
  - `set_baseline/2` refuses an existing baseline with
    `{:error, {:baseline_exists, at}}` unless `replace: true` is passed
    (C6-T01 V-24); `--replace` passes it.
- **MP-E8-C6-T02** writes the `feature:<slug>` label after a registry join. Its
  per-member state lives in C6-T02's own file and is read with
  `LabelProjection.label_states([n])` (`state: :pending_label | :labelled |
  :exempt | :held_backfill | :pending_unlabel | :unlabelled | :failed`, C6-T02
  §4.2), and `LabelProjection.status/0` gives the totals or
  `{:error, :registry_unavailable}` (C6-T02 §4.5). This ticket reads those two;
  it adds no read to C6-T02.
- **Owner questions followed with their default** (not blockers):
  OQ-E8-6 (hue: C6-T01's auto hue, `--hue` override; this ticket validates the
  flag); PQ-11 (baseline: explicit `aiur feature baseline` is option (b),
  always available).
- **Can run concurrently with** C6-T03, C6-T05 and C7. **Merge hazard with
  C5-T03:** both edit `aiur-engine.sh` (`usage()`, dispatch), `agent_control_cli.ex`,
  `dynamic_tool.ex` `@handlers`, `tool_executor.ex`, `errors.ex` and the exact
  `supportedTools` list in `dynamic_tool_test.exs`. The second to merge rebases
  and keeps both entries; C13-T04 already assumes C5-T03 and C6-T04 land
  before it.
- **Dependents:** C5-T04 (skill guidance teaches this CLI and tool), C12-T07
  (docs cross-link), C13-T03 (adds `confirm` and `--unconfirmed` to
  `Aiur.FeatureCLI` and `AgentControlCLI.feature/1`), C13-T04 (backfill agent
  calls `aiur_feature` with `"backfill": true`).

## Verified starting point (`58854d4c8`)

Paths are under `src/` unless they start with `packaging/` or `website/`.
Everything named `Features`, `LabelProjection`, `FeatureCLI` or `Feature` below
is PROPOSED; every other symbol exists at `58854d4c8`.

- **Engine.** `packaging/npm/aiur-cli/libexec/aiur-engine.sh`:
  - `usage()` `:448-500` lists every command; `aiur build-orders` is `:466`.
  - `cmd_build_orders` `:3043-3073` is the model for a positional selector,
    `--json`, and base64-encoded values passed to
    `run_control_rpc "Aiur.AgentControlCLI.build_orders([$opts])"`.
  - `cmd_executor_answer` `:2867-2920` is the model for a write with flags,
    usage errors on exit 64, a default identity (`executor_id="aiur-cli"`,
    `:2868`), and `local AIUR_CONTROL_ATTEMPT_CONTEXT=…` (`:2918`) for an
    "outcome is unknown" message.
  - `encode_control_value` `:2861-2863`.
  - `run_control_rpc` `:2463-2480`: a timeout exits 124 and says "outcome is
    unknown"; transport failures are diagnosed there. The budget is
    `control_rpc_timeout_seconds` `:2317-2323` (default 10 s,
    `AIUR_CONTROL_RPC_TIMEOUT_SECONDS`). This ticket reuses both as is.
  - `aiur_engine_main` `:4154` onward; `build-orders)` dispatch `:4234-4236`.
- **Control side.** `lib/aiur/agent_control_cli.ex`:
  - `build_orders/1` `:375-378` = `guarded(name, fn -> … |> exit_marker() end)`
    with `error_fun: &control_error/1`.
  - `guarded/2` `:3209-3224` turns a crash or a GenServer timeout into a
    reported error with an exit marker. `control_error/1` `:3273-3277`.
    `exit_marker/1` `:3510-3513`.
- **Write CLI model.** `lib/aiur/executor_command_cli.ex:9-28`: `answer/2`
  returns `0 | 1 | 64`, prints one result line, and routes `{:usage, msg}` and
  `{:error, reason}` separately. `Aiur.BuildOrdersCLI.run/1`
  (`lib/aiur/build_orders_cli.ex:22-34`) is the `--json` versus human split.
- **Agent tool path.** Agents do not run the `aiur` CLI; they call dynamic tools.
  - `lib/aiur/codex/dynamic_tool.ex:15` `@handlers` list; `execute/3` `:18-33`
    dispatches by name and **does not validate arguments against
    `inputSchema`**; `tool_specs/0` `:36-38`.
  - `lib/aiur/codex/dynamic_tool/handler.ex:6-8` behaviour (`tools/0`,
    `specs/0`, `execute/3`).
  - `lib/aiur/codex/dynamic_tool/ticket_state.ex` is the model: schema with
    `additionalProperties: false` (`:44-56`), an injected setter in `opts`
    (`:76-93`), argument normalisation (`:98-123`), refusal of values an agent
    may not set (`:28-32`). Its normaliser ignores unknown keys, so the schema
    alone does not refuse them.
  - `lib/aiur/codex/dynamic_tool/args.ex` has `string/3` (`:7`) and
    `boolean/3` (`:50`) argument helpers to reuse.
  - `lib/aiur/codex/dynamic_tool/response.ex`: `build/2` `:9`, `failure/1`
    `:23`. `lib/aiur/codex/dynamic_tool/errors.ex`: `payload/1` clauses, e.g.
    `:ticket_state_setter_unavailable` `:265`, fallback `payload(reason)` `:417`.
  - `lib/aiur/agent_runner/tool_executor.ex:103-143` builds the per-ticket
    `opts` (`ticket_state_setter` at `:140-142`). The daemon knows the agent's
    `issue` here, so the actor cannot be forged by the agent.
    `issue_identifier/1` `:353-359` prefers `issue.id` (a tracker node id such
    as `"gid-te-state"` in `test/aiur/agent_runner/tool_executor_test.exs:50-56`),
    so it is **not** the issue number. `issue_number_of/1` `:327-333` returns
    `issue.identifier` as given (a binary); a GitHub issue's identifier is
    `to_string(number)` (`lib/aiur/github/issues.ex:988`). `Aiur.Issue`
    (`lib/aiur/issue.ex:8-30`) has no `number` field.
  - `lib/aiur/app_server/adapter.ex:61-63` default executor passes no opts; a
    tool that needs a writer then returns its "unavailable" error, as
    `TicketState` does (`:89-91`).
- **Docs.** `website/docs-app/reference/cli.md`: the "What the CLI does" table
  `:24-30`; "Dashboard page commands" `:197` (C5-T03 adds a "Build history
  commands" table next to it); the output contract rule "never becomes `0`,
  `[]`, or `{}`" `:237`; "Decisions, Executor events, and findings" `:241`.
- **Tests that exist.**
  - `test/aiur_engine_test.exs:1388-1401` engine routing tests for
    `cmd_build_orders` with a stubbed `run_control_rpc`;
    `run_sourced_engine/2` `:1737-1754` pins a fake node name.
  - `test/aiur/dynamic_tool_test.exs:80-99` asserts the exact
    `supportedTools` list; it must gain `"aiur_feature"`.
  - `test/aiur/codex/dynamic_tool/ticket_state_test.exs` (handler unit tests
    with an injected setter) and `test/aiur/agent_runner/tool_executor_test.exs:50-110`
    (tool calls through the real executor) are the test models.

## Chosen design

### Command surface

```text
aiur feature create   <slug> --label <text> [--hue <0-359>] [--epic <key>=<label>]... [--as <who>] [--json]
aiur feature add      <slug> <ids…> [--epic <key>] [--move] [--source backfill-agent] [--as <who>] [--json]
aiur feature remove   <slug> <ids…> [--as <who>] [--json]
aiur feature also     <slug> <ids…> [--remove] [--as <who>] [--json]
aiur feature baseline <slug> [--replace] [--as <who>] [--json]
aiur feature edit     <slug> [--label <text>] [--hue <0-359>] [--end now|<ISO-8601>] [--add-epic <key>=<label>]... [--as <who>] [--json]
aiur feature show     [<slug>] [--json]
```

- `<ids…>` are GitHub issue numbers, `^#?[1-9][0-9]{0,9}$` (as C5-T03), below
  2^31 (C6-T01's rule, checked again in `FeatureCLI`), 1 to 200 per call,
  duplicates collapsed. More than 200 is a usage error (exit 64).
- **Identity** (same model as C5-T03 §4.2): `--as <who>` defaults to `$USER`;
  `<who>` must match `^[A-Za-z0-9._-]{1,64}$`, else exit 64 (an empty `$USER`
  and no `--as` is exit 64, never `cli:`). There is no `--source agent:<n>`:
  only the tool can claim an agent identity.
- **Source and actor** (C6-T01 §4.3 values):

  | Caller | `actor` | `source` |
  | --- | --- | --- |
  | CLI | `cli:<who>` | `cli:<who>`, or `backfill-agent` with `--source backfill-agent` |
  | Tool | `agent:<issue number>` | `agent:<issue number>`, or `backfill-agent` with `"backfill": true` (same flag as `aiur_set_epic`) |

  `confirmed` is not passed; C6-T01 stores `true`, or `false` for
  `backfill-agent` (C13-T04, S-8). The tool schema has no `actor` property.
- **Exit codes** as `ExecutorCommandCLI`: 0 success (including "unchanged"),
  1 domain refusal or registry unavailable, 64 usage error, and the engine's
  own 124 on timeout.

### Behaviour per verb

Every write verb first reads `snapshot/1` once (to derive per-id outcomes,
which C6-T01's result does not carry, and to make retries idempotent), then
makes **one** C6-T01 write call.

| Verb | Behaviour |
| --- | --- |
| `create` | New slug → `create/3` → `created`. Existing slug whose label and epics equal the request, and whose hue equals `--hue` (or `--hue` absent) → `unchanged`, exit 0, no write (re-runnable; an absent `--hue` never compares against the stored auto hue). Otherwise C6-T01 returns `{:feature_exists, slug}` → exit 1 "feature exists with different values; use `aiur feature edit`". `--epic` absent → C6-T01's single `f-<slug>` epic. |
| `add` | `add/3` makes `<slug>` the owning feature of each id, in `--epic` (default: the feature's first epic). Outcome per id: `added` (no previous owner), `moved` (`--move`, `previous_feature` from the snapshot), `updated` (same owner, different epic or confirmed; C6-T01 §4.2 keeps `joined_at`), `unchanged` (not in `changed`). `{:owned_elsewhere, …}` → exit 1, the whole batch refused, every conflict listed with its owner. Unknown slug → exit 1 "unknown feature; create it first" (no implicit create). |
| `remove` | Ids not owned by `<slug>` in the snapshot are reported `unchanged` and dropped from the call; the rest go to `remove/3` (`removed`). If all ids are dropped, no write. A `{:not_member, ns}` from a race since the snapshot → exit 1 listing `ns`; a re-run is clean. |
| `also` | `also/3`; `--remove` drops links. `{:owner_cannot_also, ns}` → exit 1 (E8-D11: a ticket never counts twice). |
| `baseline` | Snapshot shows a baseline and no `--replace` → exit 1 "baseline set <age> ago with N members; pass --replace". Else `set_baseline/2`; the human line names the previous time and count when one is replaced (the journal keeps the old record). **CLI only:** the tool refuses it, because an agent resetting "original scope" would hide added scope. |
| `edit` | `update_feature/3` for `--label`, `--hue`, `--end` (sets `to`; `now` is the daemon's clock), then one `add_epic/3` per `--add-epic`. At least one flag, else exit 64. **CLI only** (the tool refuses it). This is the operator path for EC-24 "renamed" and for ending a feature. |
| `show` | With a slug: feature fields, owning members, also-affects ids, per-member `epic`/`source`/`actor`/`joined_at`/`confirmed`/`label`, baseline. Without a slug: one line per feature (slug, label, members, open or ended). No progress figures (C6-T05 owns them). |

### `--json` envelope (schema version 1)

Write verbs:

```json
{
  "schema_version": 1,
  "command": "feature add",
  "feature": "khala-srv",
  "generation": 43,
  "results": [
    {"id": 412, "outcome": "added", "previous_feature": null,
     "source": "cli:kevin", "actor": "cli:kevin", "confirmed": true, "label": "pending"},
    {"id": 413, "outcome": "unchanged", "label": "labelled"}
  ]
}
```

`outcome` is one of `added | moved | updated | removed | unchanged`, plus
`kept_existing`, which C13-T04 adds to C6-T01 for backfill writes and which this
envelope passes through unchanged. `label` per id is read with C6-T02
`label_states/1` after the write:
`:pending_label` → `"pending"`, `:labelled` → `"labelled"`, `:exempt` →
`"exempt"`, `:held_backfill` → `"held"`, `:failed` → `"failed"`; a number
with no entry, an `{:error, _}`, C6-T02 not running, or any other value →
`"unknown"`. A removed id has no `label`.

`show --json` returns `{schema_version, observed_at, feature: {key, label,
hue, epics: [{key, label}], from, to, baseline: {at, age_ms, members} | null,
public_ref}, members: [...], also: [...], labels: {pending, failed} | null}`.
The `feature` key names match the design's `features` object built by `addF`
(J:117-121: `key, label, hue, epics, from, to`) so C8-T04 can map it without
a rename. Two shape notes: the design's `epics` is a list of keys
(`eps.map((e) => e[0])`, J:119), this one carries `{key, label}` (C8-T04 takes
`key`); `to` is an ISO-8601 string or `null` for an open feature
(C6-T01 `to: :none`). `baseline` is `null` (not `{}`) when none exists, and
human output then says "no baseline: all N members count as original"
(C6-T01 rule). `labels` comes from `LabelProjection.status/0`; it is `null`
when that call returns `{:error, _}` or C6-T02 is not running, and human
output then says "label status unknown", never "0 pending".

When the registry is unavailable, `--json` prints
`{"schema_version": 1, "ok": false, "health": {"state", "failure", "observed_at"}}`
and exits 1 (same shape as C5-T03 §4.5).

### Invariants

- One registry write call per command (two or more only for `edit` with
  `--add-epic`), through C6-T01's single writer. The CLI never writes labels
  and never calls GitHub.
- Unknown is never success or zero: `{:error, %ProviderHealth{}}` from a read,
  or `:features_not_running`, `:version_unsupported`, `:state_dir_unavailable`,
  `:unsafe_path`, `{:journal_append_failed, _}` from a write, is exit 1 with
  "feature registry unavailable (<failure>)", never "no features"; a missing
  label state prints "label unknown", never "labelled".
- A computed age is rendered: `show` prints the baseline age ("baseline set
  3d ago, 18 members") and `--json` carries `age_ms`.

## Implementation steps

1. **Engine** (`aiur-engine.sh`): add `cmd_feature` after `cmd_build_orders`
   (`:3073`). Parse the verb, slug, ids and flags; reject unknown verbs and
   flags, flags on the wrong verb (`--hue` on `add`, `--move` on `also`,
   `--source` on any verb but `add`), ids that fail the id
   rule, more than 200 ids, `--hue` outside 0..359 or non-integer,
   `--source` other than `backfill-agent`, empty `--label` on create, a
   `<who>` that fails its rule, `edit` with no flag. Strip a leading `#` from
   ids. Pass `slug`, `who` and text values with `encode_control_value`; pass
   ids as an integer list. Set `local AIUR_CONTROL_ATTEMPT_CONTEXT="feature <verb> <slug> for N tickets"`
   so a timeout names the attempt. Call
   `run_control_rpc "Aiur.AgentControlCLI.feature([$opts])"`. Add the
   `feature)` case beside `build-orders)` (`:4234`) and seven `usage()` lines.
2. **`Aiur.AgentControlCLI.feature/1`** beside `build_orders/1` (`:375`):
   `guarded("feature", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> FeatureCLI.run() |> exit_marker() end)`.
3. **PROPOSED `lib/aiur/feature_cli.ex`**: `run/1` returns `0 | 1 | 64`.
   It builds `actor: "cli:" <> who` and the source from `who`/`--source`,
   re-checks the id and `who` rules (the RPC is a second entry point), then
   calls `apply_op/2`. `apply_op(op_args, identity)` (shared with the tool)
   reads the snapshot, calls the one C6-T01 write, reads label states with
   C6-T02 `label_states/1`, and returns `{:ok, envelope} | {:error, reason}`. `run/1`
   prints JSON or one human line per id plus a summary ("2 added, 1
   unchanged; labels pending for 2").
4. **PROPOSED `lib/aiur/codex/dynamic_tool/feature.ex`** (`aiur_feature`):
   input `{op: create|add|remove|also|show, slug, ids?, epic?, move?, remove?,
   label?, hue?, epics?, backfill?}` with `additionalProperties: false`
   (`backfill: true` maps to source `backfill-agent`). Because
   `DynamicTool.execute/3` does not enforce the schema, the normaliser itself
   refuses any key outside that list with `{:error, :invalid_feature_arguments}`
   (this is how `actor` is refused). `baseline` and `edit` are refused with
   `{:error, {:agent_cannot_use_feature_op, op}}`; `op: create` and `op: also`
   with `backfill: true` are refused with
   `{:error, {:backfill_cannot_use_feature_op, op}}`. Calls the injected
   `feature_writer` (`opts`) and returns `Response.build/2` with the same JSON
   envelope. Add `Errors.payload/1` clauses for `:feature_writer_unavailable`,
   `:invalid_feature_arguments`, `{:agent_cannot_use_feature_op, _}`,
   `{:backfill_cannot_use_feature_op, _}` and
   `:feature_tool_needs_github_issue` next to `:265`.
5. Register `Feature` in `@handlers` (`dynamic_tool.ex:15`); inject
   `feature_writer: fn args -> feature_write_for_issue(issue, args) end` in
   `tool_executor.ex` next to `ticket_state_setter` (`:140`).
   `feature_write_for_issue/2` takes `issue.identifier` and accepts it only
   when it matches `^[1-9][0-9]{0,9}$` (a GitHub number); it then calls
   `FeatureCLI.apply_op(args, actor: "agent:" <> n, source: …)`. Any other
   identifier (nil, a Linear key such as `ABC-12`) gives
   `{:error, :feature_tool_needs_github_issue}`, never `agent:` or
   `agent:gid-…`. Do not use `issue_identifier/1` (it returns `issue.id`).
6. **Docs** (`reference/cli.md`): add the seven `aiur feature` rows to the
   "Build history commands" table that C5-T03 adds next to `:197` (create that
   table with the same heading if this ticket lands first), add `feature` to
   the "Act on durable records" row at `:30`, and a short "Features" section
   with the actor/source/confirmed rules, exit codes, the "timeout: re-run and
   read the outcomes" rule, and one example.

## Non-happy paths

- **Daemon down or RPC timeout.** Reuses `run_control_rpc`: down → the
  "start aiur" message; timeout (10 s default) → exit 124 "outcome is
  unknown". Every verb is idempotent on re-run (`add`/`also`/`create` give
  `unchanged`; `remove` drops non-members; `baseline` refuses without
  `--replace`, which tells the caller the first attempt landed), so the docs
  tell the caller to re-run and read the outcomes. A C6-T01 call (60 s budget)
  that outlives the engine's 10 s still completes or fails in the daemon.
- **Registry unavailable** (C6-T01 health not usable, store not running, or a
  write refused for a store reason): exit 1, "feature registry unavailable
  (<failure>)"; `show` never prints an empty list for it.
- **EC-13 concurrent writers.**
  - Two CLI calls adding the same id to two features: C6-T01 serialises them;
    the second sees the first as owner and is refused without `--move`.
  - A `feature:` label added on GitHub while a CLI join runs: C6-T02
    reconciles; the registry (system of record) wins, and the CLI reports the
    label as `pending` until C6-T02 has seen it.
  - Agent tool and operator CLI on the same ticket: last settled write wins;
    both are journaled with their actors, so the operator can see and reverse
    an agent's `move`.
  - A write between this command's snapshot and its write: the store result
    is still correct (it validates under its own lock); only the derived
    `outcome`/`previous_feature` text can be stale. The journal is the truth.
- **Partial batch.** Never written: C6-T01 writes one record per call, so a
  conflict anywhere refuses the whole batch, and a re-run after fixing the
  conflict is a clean retry.
- **Unknown or closed issue numbers.** Not checked against GitHub (EC-32: no
  new reads). The registry stores the number; C6-T02 reports a failed label
  write (`label: "failed"`).
- **Security.** An agent cannot claim a human actor (no `actor` input, unknown
  keys refused in code, the daemon sets it from the bound issue). An agent
  cannot set the baseline or edit a feature. The CLI cannot claim `agent:<n>`.
  Slug and label text are validated by C6-T01 before any write and passed
  base64-encoded through the RPC expression, as every other engine command
  does; ids reach the RPC only as digits.
- **Tool without a writer** (`app_server/adapter.ex:61-63` default path):
  returns `feature_writer_unavailable`, as `TicketState` does.
- **Linear or non-numeric ticket identity:** the tool returns
  `feature_tool_needs_github_issue`; features key on GitHub numbers.

## Compatibility and rollout

New command and new tool only. No config key, no migration. The registry file
format belongs to C6-T01. Rollback: remove the command and the tool; registry
data stays valid. Agents on an older daemon see no `aiur_feature` tool, so the
skill guidance (C5-T04) must not ship before this ticket. C13-T03 later adds
`confirm` and `--unconfirmed`; the `schema_version` stays 1 because those add
fields, they do not change existing ones.

## Pixel parity

No pixels. This ticket renders nothing on the page, so it has no C1-T02
side-by-side screenshot check and no C1-T03 motion script. The only design
link is data shape: `show --json` uses the `features` field names from `addF`
(J:117-121). The check is a unit test (V-F9 below), not a screenshot.

## Verification

Command (isolated HOME per the memory note "mix test clobbers agent-token"):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_engine_test.exs test/aiur/feature_cli_test.exs \
  test/aiur/codex/dynamic_tool/feature_test.exs test/aiur/dynamic_tool_test.exs \
  test/aiur/agent_runner/tool_executor_test.exs
```

Registry tests start a C6-T01 store on a temp directory
(`:build_features_state_dir`), never `~/.aiur`.

| # | Test (file) | Input → expected | Fails without |
| --- | --- | --- | --- |
| V-E1 | engine: "feature add routes slug, ids, who and json" (`aiur_engine_test.exs`) | `USER=tester`, stub `run_control_rpc`, `cmd_feature add khala-srv 12 '#13' 12 --json` → `RPC:Aiur.AgentControlCLI.feature([op: :add, slug: Base.decode64!("a2hhbGEtc3J2"), ids: [12, 13], who: Base.decode64!("dGVzdGVy"), json: true])` | `cmd_feature` (unknown command), the `#` strip and the duplicate collapse |
| V-E2 | engine: "feature rejects bad ids, hue, source and batch size" | `add s 12a`, `add s 0`, `create s --label x --hue 400`, `add s --hue 3 1`, 201 ids, `--source human`, `--source agent:3`, `also s 1 --source backfill-agent`, `edit s` (no flag) → each exit 64 with a named message; stub RPC not called | each validation branch (mutate one at a time) |
| V-E3 | engine: "feature refuses an empty or unsafe identity" | `USER= cmd_feature add s 1` → exit 64; `--as 'a b'` → exit 64; `USER= … --as kevin` → RPC called with `who` for `kevin` | the identity checks |
| V-F1 | `feature_cli_test.exs` "add is idempotent" | add 12 twice → second result `unchanged`, `journal/2` has one `member.added` | the outcome derivation (a second `added` would be printed) |
| V-F2 | "a conflict refuses the whole batch" | 12 owned by `a`; `add b 11 12` → exit 1, conflict lists `12 (a)`, 11 is not a member of `b`; with `move: true` → 12 `moved`, `previous_feature: "a"` | the `{:owned_elsewhere, _}` mapping (exit 0 would be returned) and the `previous_feature` lookup |
| V-F3 | "also on the owning feature is refused" | 12 owned by `a`; `also a 12` → exit 1, message names 12 | the `{:owner_cannot_also, _}` mapping |
| V-F4 | "registry unavailable is not an empty list" | store stopped (`:features_not_running`); `show` → exit 1, stderr "feature registry unavailable", stdout has no "no features"; `show --json` → `"ok": false` | **mutation:** map the error to `{:ok, %{features: %{}}}` → test must fail |
| V-F5 | "label state is read, never assumed" | `label_states/1` stub with no entry for the owner → JSON `"label": "unknown"`, human "label unknown"; stub `:exempt` → `"exempt"`; stub `:held_backfill` → `"held"` | **mutation:** default a missing state to `"labelled"` → test must fail |
| V-F6 | "backfill source records unconfirmed" | `add a 12 source: backfill-agent` → member `source: "backfill-agent"`, `actor: "cli:tester"`, `confirmed: false`; without it `source: "cli:tester"`, `confirmed: true` | the source mapping |
| V-F7 | "baseline needs --replace" | baseline twice → second exit 1 and the store's baseline `at` unchanged; with `replace: true` → new `at`, human line names the previous time and count | the replace guard (C6-T01 would replace silently) |
| V-F8 | "create is re-runnable, not a rename" | create same label twice with no `--hue` (auto hue stored) → `unchanged`, exit 0, journal has one `feature.created`; same label with a different `--hue` → exit 1 naming `edit` | the identical-values comparison, including the absent-hue rule |
| V-F9 | "show renders the baseline age and the addF field names" | fixed clock, baseline 3 days old → human contains "baseline set 3d ago"; JSON `baseline.age_ms == 259_200_000` and `feature` has keys `key label hue epics from to`; no baseline → `"baseline": null` and "no baseline: all 2 members count as original" | **mutation:** drop the age from the human line, or render `{}` for no baseline → test must fail |
| V-F10 | "remove is idempotent" | 12 owned by `a`, 13 not; `remove a 12 13` → 12 `removed`, 13 `unchanged`, exit 0; again → both `unchanged`, no new journal record | the snapshot pre-filter (C6-T01 would return `{:not_member, [13]}`, exit 1) |
| V-F11 | "edit renames and ends a feature" | `edit a --label "New" --end now` → `snapshot` shows the new label and `to` set; `show` lists `a` as ended | the `update_feature/3` call |
| V-F12 | "label status unknown is not zero" | `LabelProjection.status/0` stub returns `{:error, :registry_unavailable}` → `show --json` `"labels": null`, human "label status unknown" | **mutation:** render `%{pending: 0}` → test must fail |
| V-T1 | `codex/dynamic_tool/feature_test.exs` "actor cannot be supplied" | call `add` with an extra `"actor": "cli:kevin"` → failure `invalid_feature_arguments`, writer not called | the unknown-key check in the normaliser (the schema alone does not refuse it) |
| V-T2 | "agents cannot set a baseline or edit; backfill cannot create or also" | `op: "baseline"` and `op: "edit"` → failure `agent_cannot_use_feature_op`; `op: "create"` and `op: "also"` with `backfill: true` → failure `backfill_cannot_use_feature_op`; writer not called; `op: "add"` with `backfill: true` → writer called with source `backfill-agent` | the refusal clauses and the `backfill` mapping |
| V-T3 | "no writer is an error" | no `feature_writer` in opts → failure `feature_writer_unavailable` | the unavailable branch |
| V-T4 | `tool_executor_test.exs` "aiur_feature records the bound issue number" | real executor, `%Issue{id: "gid-te-feat", identifier: "77"}`, temp store; `add` → registry owner with `actor: "agent:77"`, `source: "agent:77"`; with `%Issue{id: "gid-x", identifier: "ABC-12"}` → failure `feature_tool_needs_github_issue`, no journal record | the `feature_writer` injection; **mutation:** use `issue_identifier/1` → actor `agent:gid-te-feat` → test must fail |

`dynamic_tool_test.exs:87-98` gains `"aiur_feature"` in the expected list; that
edit keeps an existing test green and is not counted as coverage.

**Mutation run** (AGENTS.md): in a worktree, `git status --porcelain` must show
only the reverted hunk; for each row above revert the named production hunk,
run that one test (`mix test path:line`), confirm it fails, restore, confirm it
passes. Name each result and the exact command in the PR body.

**Manual:** with `aiurdev --bg` running, `aiurdev feature create e8-test
--label "E8 test"`, `add e8-test <two real ids>`, `show e8-test --json`
(expect `label: "pending"`, then `"labelled"` after C6-T02's next paced
write), `edit e8-test --end now`; then stop the daemon and confirm `show`
gives the down message, not an empty list. This is a CLI check; the TUI recipe
does not apply (no TUI change).

## Completion and handoff

- [ ] `aiur feature` seven verbs routed by the engine, `usage()` updated.
- [ ] `Aiur.FeatureCLI` and `aiur_feature` share one `apply_op/2`.
- [ ] Actor and source recorded as in the table; `confirmed` comes from
      C6-T01's default; agents cannot forge an actor, set a baseline or edit a
      feature; the CLI cannot claim `agent:<n>`.
- [ ] V-E1..V-T4 pass, and each fails with its hunk reverted.
- [ ] `reference/cli.md` rows and "Features" section in the same PR.
- Dependents: C5-T04, C12-T07, C13-T03, C13-T04.
- Sources: tickets/README.md C6-T04 row; chunks.md C6; plan §8 EC-13, EC-32,
  §10 items 14 and 22; decisions E8-D9, E8-D11; questions OQ-E8-6, PQ-11;
  DESIGN-E8 S-8; MP-E8-C6-T01 §4.2-§4.4 and §9 note 2; MP-E8-C6-T02 §4.2,
  §4.5; MP-E8-C5-T03 §4.2, §4.6; MP-E8-C13-T04 §4.4.

## Decisions made without the owner

1. **Agents use a dynamic tool, not the CLI.** E8-D9 asks for "a single CLI or
   tool call". Daemon agents reach Aiur through dynamic tools
   (`tool_executor.ex:103-143`), and the daemon then sets a trustworthy actor.
2. **Batches are all-or-nothing** (C6-T01's one record per call), so a retry
   after a conflict is clean.
3. **Batch cap 200 ids** per call (C6-T01 allows 1,000), the same cap as
   C5-T03, to stay inside the 10 s control-RPC budget.
4. **No implicit create** on `add`; a typo in a slug must not make a feature.
5. **Baseline and edit are CLI-only** (not agents), and replacing a baseline
   needs `--replace`.
6. **`--source` accepts only `backfill-agent`, on `add` only**, and C6-T01
   then stores `confirmed: false`; there is no separate `--unconfirmed` flag.
   The tool takes `backfill: true` (same flag as `aiur_set_epic`, C5-T03) and
   refuses it with `op: create` or `also` (no backfill features or also-links).
7. **Issue numbers are not checked against GitHub** (EC-32); C6-T02 reports
   failed label writes.
8. **Identity follows C5-T03:** `--as <who>`, default `$USER`; actor
   `cli:<who>` or `agent:<n>`. The tool takes the number from
   `issue.identifier`, not `issue_identifier/1`.
9. **`show` prints no progress figures**; C6-T05 owns them, and printing them
   here would make two sources of the same number.
10. **An `edit` verb is added** beyond the README row. C6-T01 §9 note 2 says its
    `update_feature/3` and `add_epic/3` are otherwise unreachable, so EC-24
    "renamed" and ending a feature (`to`) would have no operator path. It is a
    thin call into existing store functions. No delete verb (C6-T01
    decision 8).
11. **No label-retry verb.** C6-T02 retries failed items once per boot, and
    `show` reports `failed` so the operator sees them; a verb can be added when
    a failed label is seen in practice.
12. **Outcomes are derived from a snapshot before the write**, because
    C6-T01's result carries only `changed`. A concurrent write can make the
    derived text stale, never the stored state.

## Interface notes for neighbour rows

- **README row C6-T04** lists six verbs; this ticket adds `edit` (Decision 10).
  Settled 2026-10-08: the `edit` verb stays.
- **C6-T01** stores `confirmed` per membership (§4.3); each owner in
  `snapshot/1` carries `epic`, `source`, `actor`, `joined_at`, `confirmed`, and
  `update_feature/3` accepts `to:` (§4.4). Settled 2026-10-08: no projection map
  on the owner record.
- **C6-T02.** Settled 2026-10-08: label state is read with `label_states/1`;
  totals with `status/0`.
- **C5-T03** and this ticket edit the same files and the same
  `supportedTools` test list (merge hazard above).
- **C12-T07** also lists the feature commands for `cli.md`; this ticket writes
  those rows and section (AGENTS.md "Docs ship with the change"), and C12-T07
  only links to them.

## Review log

Adversarial review 2026-10-08, checked against `58854d4c8` and the neighbour
ticket files.

1. Replaced the invented registry API (`Features.apply/4`, `get/1`, `list/0`,
   `{:error, :unavailable}`) with C6-T01 §4.4's real names, errors and
   `{:error, %ProviderHealth{}}` reads.
2. Fixed source and actor values: `source: "cli"`/`"agent"` fail C6-T01's
   source rule; now `cli:<who>`/`agent:<n>`/`backfill-agent`, matching C5-T03
   and C13-T04. `confirmed` now comes from C6-T01's default.
3. Fixed the agent actor: `issue_identifier/1` returns `issue.id` (a node id),
   not the number; the tool now parses `issue.identifier`
   (`github/issues.ex:988`) and refuses non-GitHub identifiers. V-T4 now
   catches that mutation.
4. V-T1 was vacuous against the code: `DynamicTool.execute/3` does not apply
   the schema. The normaliser now refuses unknown keys, and V-T1 tests that.
5. `remove` on a non-member was "unchanged", but C6-T01 returns
   `{:not_member, _}`; added the snapshot pre-filter and V-F10.
6. `baseline --replace` guard: C6-T01 replaces silently, so the guard is a
   snapshot check here; V-F7 now asserts the stored `at` is unchanged.
7. `create` "unchanged" with an absent `--hue` would compare against the stored
   auto hue; rule made explicit, V-F8 covers it.
8. Removed the invented `FeatureLabels.projection_status/2`; label states now
   come from C6-T02's `projection` map and `status/0`, with C6-T02's names
   (`labelled`, `exempt`, `failed`). Added V-F12 for unknown totals.
9. Added `--epic` on `add` (C5-T03 says feature-epic choice belongs here),
   `--as` (C5-T03 identity model), the `#`-prefixed id rule, and the
   `kept_existing` outcome C13-T04 passes through.
10. Added the `edit` verb that C6-T01 §9 note 2 asks for, flagged as beyond
    the README row.
11. Corrected the stale interface note (C6-T01 already stores `confirmed`),
    the "concurrent with all of C5" claim (C5-T03 edits the same files), the
    docs location (C5-T03's "Build history commands" table), the JSON
    unavailable shape and the `epics`/`to` shape notes versus `addF`.
12. Verified every cited path and line at `58854d4c8`; added the RPC timeout
    (`:2317-2323`), `args.ex`, `response.ex`, `errors.ex` and `issue.ex`
    citations used by the new steps.
- Reconciliation 2026-10-08 (coordinator): label state read through C6-T02 `label_states/1` (not a `projection` map; adds `"held"` for `:held_backfill`); tool `source` field replaced by `backfill: true` (maps to `backfill-agent`), refused with `op: create`/`also`; CLI `--source` only on `add`; V-E2, V-F5, V-T2 updated; interface notes marked settled; `edit` verb kept.
- Reconciliation 2026-10-08 (coordinator, second pass): `set_baseline/2` refusal per C6-T01.
