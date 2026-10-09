---
title: "EXP-X2-1: Add the experiments component, spec v1 and state-node store - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
origin: docs/research/experiments/x2/brainstorm.md
date: 2026-10-09
ticket: EXP-X2-1
epic: aiur-team/aiur#3774
---

# EXP-X2-1: Add the experiments component, spec v1 and state-node store - Plan

Product Contract: [brainstorm.md](brainstorm.md) (R1-R9, R15-R18, KD4, KD5, KD9, KD11). Product Contract unchanged.
Base: `origin/main` `1c4409e43`.

## Summary

Create the `experiments` component: the spec v1 data model and validator, a single-writer store under `~/.aiur/repo/<owner>/<repo>/experiments/`, schema versioning, an append-only journal, the `experiments` config section, a capability provider, and the CLI verbs `list`, `show` and `create`.
This ticket defines the **facade** (§4) that X3, X4, X5 and X6 build on. `freeze` and metric evaluation arrive in EXP-X2-2 and EXP-X2-4; this ticket ships their facade signatures as `{:error, :not_implemented}` stubs **only if** EXP-X2-2/4 have not merged first (preferred order: this ticket first).

---

## Problem frame

No experiment object exists anywhere. Every other area needs a stable place to read and write one, and the MP-R1 checker (`scripts/check-components.py`, run in the required `lint` job) rejects a new module tree that no `components.json` entry owns.

---

## Key technical decisions

- **KTD1. Component `experiments`, layer 3, `kind: optional`** (session-settled: operator, KD4). Requires `kernel`, `config`, `event-bus`, `identity`. Optional: `telemetry` (L2, for the built-in pack), `accounting` (cost metrics), `tracker` (resolve epic and release times for X3). All are at or below L3, so rule R-down holds; `experiments` is optional, so R-optional allows optional deps. `dashboard-ui` (L4) gains `experiments` as an optional dependency in X5, not here.
- **KTD2. Paths.** `RepoBase.experiments_path/1` (`src/lib/aiur/repo_base.ex`, beside `builds_path/1` and `analytics_path/1`) is the single path function; `Aiur.Experiments.Paths` wraps it with the repo slug resolution that `Aiur.RunTelemetry.Summaries.repo_url/0` uses (`tracker.github.repo`, else `local/repo`), and honours an `Application` env override `:experiments_dir` for tests (the `Config.Paths` override precedent). Manifest `owns.state: ["experiments_path"]`.
- **KTD3. Format.** Pretty JSON for `spec.json`, `index.json` and snapshots; NDJSON for journals. Writes use `Aiur.Fs.atomic_write/3` (temp + fsync + rename). The state node is per-user, not secret; directories are created `0700` to match `executor/`.
- **KTD4. One writer.** `Aiur.Experiments.Store` is a GenServer under the daemon's supervision tree, started from a component-owned child spec `Aiur.Experiments.child/1` (MP-R1 "component-owned child specs"), placed after `Aiur.BuildQueue.child/1` in `src/lib/aiur.ex`. Reads go straight to disk (no call into the GenServer), so the page and CLI never block behind a slow write (session-settled: KD11).
- **KTD5. Schema versioning.** `schema_version: 1` in every file. `Aiur.Experiments.Schema` holds `current/0`, `migrate(map) :: {:ok, map} | {:error, {:newer_version, n}}`, and one pure upgrade function per step. A newer file is served read-only; any write to it returns `{:error, {:newer_version, n}}` (R8). The index is a cache: if missing, corrupt or newer, it is rebuilt from the experiment directories.
- **KTD6. Ids.** `<YYYY-MM-DD>-<slug>` from the creation date and title, via `Aiur.Config.Paths.sanitize/1`, lower-cased, 60 chars max; on collision append `-2`, `-3`. An explicit `id` in `create --from` is accepted if it matches `^[a-z0-9][a-z0-9._-]{2,79}$` and is unused.
- **KTD7. Pre-registration lock is a journal fact, not a refusal** (session-settled: KD9). The spec carries `registered_at` (null until the first freeze or the change time, whichever comes first). `amend/2` after `registered_at` writes an `amended` journal entry with `post_registration: true` and the field diff.
- **KTD8. Predicate language** (R3) is data, not code: a JSON tree with `all|any|not` and leaves `{attr, op, value}`, `op ∈ eq neq in prefix exists`. Attribute names are validated against the known cohort keys (`aiur_version backend model epic feature_tags config_hash complexity`) plus `tags.<key>` for consumer tags. Evaluation lives in `Aiur.Experiments.Predicate` (pure) so X4 and X5 never re-implement it.
- **KTD9. CLI is a control-RPC client.** `cmd_experiments` in `packaging/npm/aiur-cli/libexec/aiur-engine.sh` parses verbs and base64-encodes free text (the `cmd_analytics` pattern), then calls `Aiur.ExperimentsCLI.run/1`. `Aiur.AgentControlCLI` gains one `experiments/1` delegate wrapped in its existing `guarded/2`. `create --from -` reads stdin in the shell and passes it base64-encoded, so the daemon never reads a caller path it cannot see.

---

## 4. Facade (the contract other areas build on)

Public modules (manifest `facades`): `Aiur.Experiments`, `Aiur.Experiments.Spec`, `Aiur.Experiments.Predicate`, `Aiur.Experiments.Observation`, `Aiur.Experiments.MetricPack`, `Aiur.ExperimentsCLI`, `Aiur.Experiments.CapabilityProvider`. Everything else under `src/lib/aiur/experiments/**` is private.

Directional signatures (names fixed; exact typespecs are implementation detail):

| Function | Owner ticket | Used by |
|---|---|---|
| `list(filters) :: [summary]` | X2-1 | X5 index tabs, CLI |
| `get(id) :: {:ok, %Spec{}, meta} \| {:error, :not_found}` (`meta`: phase, journal tail, snapshot refs, read_only?) | X2-1 | X5, X6, CLI |
| `create(attrs, opts) :: {:ok, %Spec{}} \| {:error, errors}` (`opts[:origin]`, `opts[:freeze]` default true for before/after) | X2-1 (freeze wired in X2-4) | X3, X6, CLI |
| `amend(id, changes, actor) :: {:ok, %Spec{}} \| {:error, _}` | X2-1 | X6 |
| `set_status(id, status, reason, actor)` | X2-1 | X6, operator |
| `journal(id) :: [entry]` | X2-1 | X6 (amendments are confounders) |
| `metric_catalog() :: [metric_def]` | X2-2 | X5, X6, CLI validation |
| `arms(id, opts) :: {:ok, %{metric_id => %{arm_id => arm}}}` where `arm = %{observations: [%Observation{}], coverage, excluded: %{straddle: n, ambiguous: n, filtered: n}, source: :frozen \| :checkpoint \| :live}` | X2-4 | **X4** (only input it needs), X5 |
| `freeze(id, window, opts) :: {:ok, snapshot_ref} \| {:error, _}` | X2-4 | X3, X6, CLI |
| `report_dir(id) :: Path.t()` | X2-1 | X6 writes `report.md`, X4 writes `analysis.json` |
| `subscribe() :: :ok` — `Phoenix.PubSub` topic `"experiments"`, messages `{:experiment_changed, id}` | X2-1 | X5 live updates |

`%Observation{}`: `metric` (`"pack/metric"`), `unit_id` (e.g. `"ticket:3763"`, `"hour:2026-10-09T10"`), `value` (number), `at` (assignment timestamp, UTC ISO-8601), `finished_at` (optional), `attrs` (cohort attributes map, including `complexity`). X4 receives arms already assigned; it never reads the spec's windows or predicates (brainstorm KD10).

Assumed from other areas:

- **X1:** ticket records in the reduced dataset carry `cohort` (`aiur_version backend model epic feature_tags config_hash tags`) and a correct `pr_opened` time (brainstorm A1).
- **X3:** calls `create/2` with `origin: %{kind: :release | :epic_merge, ref: ...}`; X2 does not decide when.
- **X4:** a pure `analyze(spec, arms)` that writes nothing; X6 or X5 persist its output under `report_dir/1`.

---

## High-level technical design

```text
~/.aiur/repo/<owner>/<repo>/experiments/          (0700)
├── index.json                       cache: [{id,title,kind,status,created_at,updated_at}]
├── capture/events-YYYY-MM.ndjson    (EXP-X2-2) declared-topic event journal
└── <id>/
    ├── spec.json                    current spec, schema_version 1
    ├── journal.ndjson               created | amended | status | frozen | checkpoint
    ├── snapshots/                   (EXP-X2-4) before.r1.json, after.partial.ndjson, after.r1.json
    └── report/                      reserved: X4 analysis.json, X6 report.md
```

Spec v1 shape (directional):

```text
schema_version, id, title, hypothesis, owner{kind: human|agent, id}, status, origin{kind, ref},
design: {kind: "before_after", change: {type, ref, time}, assign_by: start|finish}
      | {kind: "ab", cohorts: [{id, label, where: <predicate>}], control: <cohort id>},
metrics: [{ref: "pack/metric", direction: decrease|increase|none, primary: bool, min_samples?}],
min_samples (default from config), windows: {before{start,end}, after{start,end|null}} | {observation{start,end|null}},
filters: <predicate over units>, stratify_by: ["complexity"], tags: [], notes,
created_at, updated_at, registered_at
```

Status machine (stored): `draft → active → concluded`, any → `abandoned`. `create` makes `active` unless `--draft`. Phase (derived, never stored): `awaiting_change` (now < change.time), `collecting`, `window_closed` (after.end or observation.end passed).

---

## Implementation units

### U1. Component entry, paths and config section

**Goal:** the checker and config know the component before any code lands.
**Requirements:** R17, KD4, KD5.
**Dependencies:** none.
**Files:** `components.json` (new `experiments` entry; add `experiments` to `control-cli.optional`), `src/lib/aiur/repo_base.ex` (`experiments_path/1`), `src/lib/aiur/config/schema/experiments.ex` (new), `src/lib/aiur/config/schema.ex` (one `embeds_one(:experiments, ...)` line), `website/docs-app/reference/configuration.md`, `src/test/aiur/repo_base_test.exs`, `src/test/aiur/config/schema/experiments_test.exs`.
**Approach:** config keys (all with defaults so an absent section is valid): `enabled` (true), `default_min_samples` (15), `default_before_days` (14), `pack_dirs` ([".aiur/experiments/packs"]), `disabled_packs` ([]), `script_timeout_ms` (60000), `checkpoint_interval_ms` (3600000), `max_snapshot_observations` (50000). The last five are consumed by EXP-X2-2/4 but are defined here so one ticket owns the section. Manifest `owns.config: ["experiments"]`, `owns.state: ["experiments_path"]`, `paths: ["src/lib/aiur/experiments.ex", "src/lib/aiur/experiments/**", "src/lib/aiur/experiments_cli.ex"]`, `forbid: ["Aiur.Orchestrator", "Aiur.Orchestrator.*", "Aiur.GitHub", "Aiur.GitHub.*"]` (the build-queue precedent: tracker-neutral, no orchestrator reach).
**Patterns to follow:** the `build-queue` manifest entry; `Config.Schema.BuildQueue`; `RepoBase.builds_path/1`.
**Test scenarios:**
- `experiments_path("aiur-team/aiur")` is `<state_root>/aiur-team/aiur/experiments`.
- Empty config gives every default above; `default_min_samples: 0` and `max_snapshot_observations: -1` are rejected with a changeset error.
- `scripts/check-components.py` passes; a fixture module under `src/lib/aiur/experiments/` that references `Aiur.Orchestrator` fails the forbid rule (add to `scripts/test-check-components.sh` fixtures).
- `scripts/check-config-docs.py` fails if the `experiments` section is missing from `configuration.md` (existing gate; verify it covers the new section).
**Verification:** lint job green with the new entry; no allowlist growth.

### U2. Spec, Predicate and Schema modules

**Goal:** a validated, versioned spec value.
**Requirements:** R1-R7, KTD5-KTD8.
**Dependencies:** U1.
**Files:** `src/lib/aiur/experiments/spec.ex`, `src/lib/aiur/experiments/predicate.ex`, `src/lib/aiur/experiments/schema.ex`, `src/priv/experiments/spec.v1.schema.json` (published JSON Schema for agents and X5), `src/test/aiur/experiments/spec_test.exs`, `src/test/aiur/experiments/predicate_test.exs`, `src/test/aiur/experiments/schema_test.exs`.
**Approach:** `Spec.new(map, defaults) :: {:ok, %Spec{}} | {:error, [%{path, message}]}` returns every error, not the first (agents fix a spec in one round trip). Window defaults are filled at validation: before = `[change.time - default_before_days, change.time)`, after = `[change.time, nil)`. `tag`/`commit` change time is resolved by an injected resolver (default: `git -C <RepoBase.base_path> log -1 --format=%cI <ref>` with a 5 s timeout); unresolvable → error naming the ref. Metric refs are checked only for syntax here (`^[a-z0-9-]+/[a-z0-9_]+$`); catalog membership is checked in EXP-X2-2.
**Test scenarios:**
- Valid before/after with `type: release, ref: v0.0.9, time` round-trips through JSON unchanged.
- Before/after without `time` and `type: manual` → error at `design.change.time`.
- `type: tag` without time → resolver called with the ref; resolver error → error naming the ref.
- A/B with one cohort → error; control id not among cohorts → error; unknown attribute `colour` → error; `tags.team` accepted.
- Predicate: `{all: [{attr: backend, op: eq, value: claude}, {not: {attr: model, op: prefix, value: "gpt-"}}]}` matches/does-not-match fixture attribute maps; `in` with a non-list → validation error; `exists` on a missing key is false.
- Three errors in one spec are all returned.
- Schema: a v1 file migrates to itself; a fabricated `schema_version: 0` fixture upgrades (seed the migration chain with a real v0→v1 step for the pre-release draft shape so the mechanism is exercised); `schema_version: 2` → `{:error, {:newer_version, 2}}`.
- `spec.v1.schema.json` validates the Elixir test fixtures (keep the two in sync with one test that loads every fixture through both).
**Verification:** the JSON Schema and `Spec.new/2` agree on every fixture.

### U3. Store, journal and index

**Goal:** durable create/amend/status with an audit trail.
**Requirements:** R8, R9, KD5, KD9, KD11, KTD3-KTD5, KTD7.
**Dependencies:** U2.
**Files:** `src/lib/aiur/experiments.ex` (facade), `src/lib/aiur/experiments/store.ex`, `src/lib/aiur/experiments/journal.ex`, `src/lib/aiur/experiments/paths.ex`, `src/lib/aiur.ex` (child spec placement), `src/test/aiur/experiments/store_test.exs`, `src/test/aiur/experiments/journal_test.exs`.
**Approach:** `Store` serialises writes; each mutation = validate → write `spec.json` atomically → append journal line (with `actor`, `at`, `kind`, diff) → rewrite `index.json` → broadcast `{:experiment_changed, id}` on `Aiur.PubSub` topic `"experiments"`. If the journal append fails after the spec write, the store re-appends on next boot by comparing `spec.updated_at` with the last journal entry (spec is truth for state; journal for history). `Aiur.Experiments.child/1` returns `:ignore`-equivalent (no child) when `experiments.enabled` is false. Reads (`list/1`, `get/1`, `journal/1`) are plain functions over files; a corrupt `spec.json` yields that experiment as `%{id, error: :unreadable}` in `list/1` rather than crashing the listing.
**Patterns to follow:** `Aiur.BuildQueue.child/1`; `Aiur.BuildProgress` PubSub broadcast; `Aiur.RunTelemetry.Summaries.decode_summary/1` fail-soft read.
**Test scenarios:**
- `create/2` writes `spec.json`, one `created` journal line, an index row; a PubSub subscriber receives `{:experiment_changed, id}`.
- Two creates with the same title on the same day → ids `...-title` and `...-title-2`.
- `amend/3` before `registered_at` → journal `amended` with `post_registration: false`; after setting `registered_at` → `post_registration: true` and the diff lists `metrics`.
- `set_status(:concluded)` then `amend` → allowed, journaled; `set_status` to an unknown status → error.
- Delete `index.json` → `list/1` rebuilds it with the same rows.
- A `spec.json` with `schema_version: 2` → `get/1` returns `read_only?: true`; `amend/3` → `{:error, {:newer_version, 2}}` and the file is unchanged (byte compare).
- Truncated `spec.json` → `list/1` returns the row with `error: :unreadable`, other experiments still listed.
- `experiments.enabled: false` → no Store process; `create/2` → `{:error, :disabled}`.
**Verification:** kill the Store mid-test between spec write and journal append (inject a failing journal writer) → next start repairs the journal.

### U4. Capability provider

**Goal:** clients can tell whether experiments work here.
**Requirements:** R18.
**Dependencies:** U3.
**Files:** `src/lib/aiur/experiments/capability_provider.ex`, `src/config/config.exs` (`:capability_providers` list), `src/test/aiur/experiments/capability_provider_test.exs`, `website/docs-app/concepts/capabilities.md` (table row).
**Approach:** `experiments`: `available` when the Store runs and the directory is writable; `unavailable/disabled`; `degraded/store_read_only` when the directory is not writable. `experiments.metric_packs` is reported by EXP-X2-2 (this ticket returns `unavailable/not_installed`).
**Patterns to follow:** `Aiur.BuildQueue.CapabilityProvider`.
**Test scenarios:** each state above from a stubbed status; a raising status function → `unknown` (rescue path).
**Verification:** `aiur capabilities --json` lists both ids.

### U5. CLI `list`, `show`, `create`

**Goal:** humans and agents drive experiments with no file editing.
**Requirements:** R15, R16 (freeze-on-create is wired in EXP-X2-4; until then `create` prints "baseline not frozen: freeze is not available in this build").
**Dependencies:** U3.
**Files:** `packaging/npm/aiur-cli/libexec/aiur-engine.sh` (`cmd_experiments`, usage text, dispatch case), `packaging/npm/aiur-cli/bin/aiur.js` (verb list, if it enumerates verbs), `src/lib/aiur/experiments_cli.ex`, `src/lib/aiur/agent_control_cli.ex` (`experiments/1` delegate), `website/docs-app/reference/cli.md`, `src/test/aiur/experiments_cli_test.exs`, `src/test/aiur_engine_test.exs`, `packaging/npm/aiur-cli/test/launcher.test.mjs`.
**Approach:** verbs: `list [--status s] [--kind before_after|ab] [--json]`; `show <id> [--json]` (spec, phase, journal tail, snapshot refs with sha256, metric coverage when EXP-X2-2 exists); `create --from <file|-> [--draft] [--no-freeze] [--json]`; quick form `create --title <t> --line <type>:<ref>[@<iso-time>] --metric <pack>/<metric>[:increase|decrease] ... [--hypothesis <h>]`. `--json` output is the exact facade data (`JSONSafe.normalize`). Exit `0` ok, `1` refused (validation errors printed one per line as `path: message`), `64` usage.
**Patterns to follow:** `cmd_analytics` and `Aiur.AnalyticsCLI`; `Aiur.BuildQueueCLI` human/JSON split; `website/docs-app/scripts/check-cli-reference.sh` gate.
**Test scenarios:**
- Engine: `aiur experiments` with no verb → usage, exit 64; `create --line release` (missing ref) → exit 64; `create --from -` with stdin → RPC expression carries base64 payload (no raw JSON in the expression).
- CLI: `create` quick form → spec with one metric `decrease`; `create --from` invalid spec → exit 1 and every error line; `list --json` parses as JSON and includes the new id; `show missing` → exit 1 "no experiment missing".
- `check-cli-reference.sh` fails until `cli.md` documents the verbs.
**Verification:** on a dev daemon, `aiur experiments create --title smoke --line manual:smoke@2026-10-09T00:00:00Z --metric delivery-speed/start_to_merge:decrease --draft` then `show` prints the spec.

### U6. Concept page

**Goal:** a consumer-repo user can learn the model.
**Requirements:** success criterion "generic".
**Dependencies:** U5.
**Files:** `website/docs-app/concepts/experiments.md` (new), `website/docs-app/.vitepress/config.ts` (sidebar, Concepts group).
**Approach:** kinds, spec fields, statuses and phases, where data lives, pre-registration amendments, CLI walk-through. Metric packs and freezing get their sections in EXP-X2-2/4 (same page).
**Test expectation:** none -- documentation; the website build and sidebar check cover it.

---

## Risks

| Risk | Mitigation |
|---|---|
| X3/X5/X6 start before this merges and invent their own shapes | Facade table above is the contract; the epic sequencing makes X2-1 the first ticket. |
| Spec fields churn after X4/X6 start | Schema versioning (U2) makes a v2 a migration, not a break. |
| Writer stalls on a slow disk block the daemon | Store is its own process; reads never call it; writes are small. |
| `git log` resolver hangs | 5 s timeout, error returned to the caller. |

## Documentation that ships

`reference/configuration.md` (`experiments` section), `reference/cli.md` (verbs), `concepts/experiments.md` (new, in the sidebar), `concepts/capabilities.md` (two ids), `components.json`.

## Definition of done

U1-U6 merged; lint (components, config docs, CLI reference) green; on a running daemon `create`, `list`, `show` work end to end and the state-node layout matches §HTD.
