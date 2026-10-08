---
ticket_id: MP-E8-C5-T01
feature_id: MP-E8
chunk_id: MP-E8-C5
bucket: 2-platform
title: Epics config section and docs
status: blocked
blocked_by: [DESIGN-E8]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: [EC-21]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C5-T01 — Epics config section and docs

> Cites code at `origin/main` `58854d4c8` (runtime worktree
> `aiur-worktrees/runtime`). Paths marked PROPOSED do not exist yet. Design
> citations use `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`. If MP-R1 has moved `config/schema/` before
> this starts, re-resolve the symbols below.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C5
  (epics), ticket T01. Level 0 after DESIGN-E8 (tickets/README.md "What may run
  concurrently"). It touches only config files, so it runs in parallel with
  C1-T01, C2-T03 and C4-T01.
- **User value.** Every ticket on the home page sits in exactly one epic column
  (E8-D1). The four general columns, Bugs, Design, Infra and Docs, are aiur's
  default (E8-D9). A project can replace them in its own `.aiur/config`
  ("a default-epics key, per repository", E8-D9). This ticket gives that list
  one home in config, with the design's colours and icons as defaults. It also
  validates the list, so a bad entry fails at config load and not on the page.
- **Deliverable.**
  - A new `build_order.epics` list in the existing `build_order:` config section.
    Each entry has `key`, `label`, `labels` (the GitHub label names that place a
    ticket in this epic), `hue` and `icon`.
  - PROPOSED `src/lib/aiur/config/schema/build_order_epic.ex`
    (`Aiur.Config.Schema.BuildOrderEpic`): one entry and its validation.
  - Defaults equal to the design's `GENERAL` (J:96), plus label matchers.
  - A fix in `src/lib/aiur/config/schema/errors.ex` so that an error inside one
    list entry is reported as `build_order.epics.<n>.<field> ...` instead of
    raising (§3 "Error text", step 3a). Without it the validation cannot report.
  - Docs rows in `website/docs-app/reference/configuration.md`, and commented
    examples in `.aiur/examples/config.example` and the three GitHub workflow
    templates.
- **Non-goals.**
  - No resolver. Choosing a ticket's one epic (feature → override → first
    matching general epic → Unsorted) is C5-T02.
  - No override store or CLI (C5-T03), no feature epics (C6-T01), no rendering
    (C9), no payload field (C3-T02, C8-T04).
  - No GitHub label writes, and no new label family. The matchers read the
    existing type labels.
  - No `Aiur.Config` accessor function. Consumers read
    `settings.build_order.epics` from `Aiur.Config.settings/0`, as the struct
    already gives it (see §4.4).

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8** only (row: "Predecessors. DESIGN-E8"). The hues and
  icons come from the design's `GENERAL` (J:96). If Kevin changes them at
  sign-off, only the four default entries in §4.2 change.
- **No owner question blocks it.** E8-D9 settled the four names. The label
  matchers are a planner default (§10, item 2).
- **Successors.**
  - C5-T02 (epic resolver) reads `settings.build_order.epics` in list order.
    That order is the "first general matcher in config order" rule.
  - C6-T01 (feature registry) chooses feature hues "in the design's hue range
    that the general epics leave free". It must read the configured hues from
    this list, not the four design constants (§11, handoff note 3).
  - C8-T04 (ticket index assembler) builds the payload's epic catalogue from
    this list plus the `unsorted` column.
  - C12-T07 (documentation) links the concepts page to the reference rows this
    ticket adds.
- **Shared contracts.** None. CONTRACT-REQUESTS.md has no C5 entry.
- **Concurrency.** It edits `config/schema.ex`, `config/schema/build_order.ex`,
  `config/schema/errors.ex` (and its test), the configuration reference and the
  templates. No other level-0 ticket edits
  these files. Any later config ticket in MP-E8 that edits `build_order.ex`
  rebases over this one.

## 3. Verified starting point (`58854d4c8`)

| Need | Where it is today |
| --- | --- |
| Root config schema | `src/lib/aiur/config/schema.ex:41-72` `embedded_schema`. `:68` `embeds_one(:build_order, BuildOrder, on_replace: :update, defaults_to_struct: true)`. `:142-184` `changeset/1`. `:180` `cast_embed(:build_order, with: &BuildOrder.changeset/2)`. `:74-90` `parse/1` normalizes keys to strings and drops nils before the changeset |
| Existing section to extend | `src/lib/aiur/config/schema/build_order.ex:10-41` (eleven integer fields), `:43-75` `changeset/2` (`cast` with `empty_values: []`, number bounds, `validate_labels_cadence/1`) |
| A list-of-maps config pattern | `src/lib/aiur/config/schema/tracker.ex:71` `embeds_many(:credentials, GithubCredential, on_replace: :delete)`; `src/lib/aiur/config/schema/github_credential.ex:28-50` (fields, `validate_required`, `validate_inclusion`, `validate_format` for a lowercase id at `:52-54`) |
| `embeds_many` default | `src/deps/ecto/lib/ecto/schema.ex:2216-2219`: `__embeds_many__` forces `default: []`. Defaults for a list must therefore be put into the attrs; the struct cannot carry them |
| `cast_embed` and absent sections | When `build_order` is absent from the config, `cast_embed` does not call `BuildOrder.changeset/2`, and the struct default applies (`defaults_to_struct: true`, `schema.ex:68`). So a default injected only in `BuildOrder.changeset/2` would not reach a config without a `build_order:` key |
| Null handling | `src/lib/aiur/config/schema/attrs.ex:22-43` `drop_nil_values`: `epics: null` in YAML is dropped before the changeset, so it behaves as "absent" |
| Error text | `src/lib/aiur/config/schema/errors.ex:6-31` `format_errors/1` → `flatten_errors/2`. It handles a map (dotted keys, `:17-27`) and a list of **strings** (`:29-31`, `prefix <> " " <> &1`). **It has no clause for a list of maps**, which is what `traverse_errors/2` returns for an `embeds_many` with an invalid child (`deps/ecto/lib/ecto/changeset.ex:4264-4275`: `[%{}, %{icon: ["is invalid"]}]`). Reproduced 2026-10-08 by running a copy of `:14-31` under Elixir 1.19.5: `ArgumentError "construction of binary failed ... expected a binary but got: %{}"`. So today an invalid `embeds_many` entry makes `Schema.parse/1` **raise** instead of returning `{:error, {:invalid_workflow_config, msg}}`. `tracker.github.credentials` has the same latent bug; no test reaches it (`test/aiur/config/schema/errors_test.exs:36-56` covers maps and string lists only). Step 3a fixes it |
| The `epic:` hazard | `src/lib/aiur/orchestrator/issue_sync.ex:479-493` `parked_marker_label?/1`: a label starting with `epic:` (after trim and downcase) marks deliberate parking. Such a ticket is never healed to `agent:todo` (options §1.2). Its trim-and-downcase normalization is the precedent this ticket reuses |
| Config reads at run time | `src/lib/aiur/config.ex:184-192` `settings!/0` raises on a config error; `settings/0` returns `{:ok, _} \| {:error, _}`. `src/lib/aiur/workflow_store.ex:1-22` polls the file once a second and caches the loaded workflow in ETS, so an edit to `epics` reaches readers within about 1 s |
| Docs checker | `scripts/check-config-docs.py:69-70` (`FIELD_RE`, `EMBEDS_RE`, which also matches `embeds_many`), `:108-127` `collect/5` (walks embeds from the root and records every field as a dotted key). A field of an `embeds_many` module becomes `build_order.epics.<field>` |
| Docs default test | `src/test/aiur/configuration_reference_test.exs:10-31` `@schema_sections` (includes `{"build_order", Schema.BuildOrder}`), `:65-69` compares documented defaults for `fields -- embeds` only. `epics` is an embed, so its row's default is not parsed. `tracker.github.credentials` is documented the same way and is not in `@schema_sections` |
| Reference page | `website/docs-app/reference/configuration.md:733-747` the `build_order` table. `:94-100` the `tracker.github.credentials.*` rows: the pattern for documenting a list's fields |
| Templates | `.aiur/examples/config.example:184-201` commented `# build_order:` block (embedded by `src/lib/aiur/init/templates.ex:26`). `src/examples/workflows/github-claude.yaml:53-71`, `github-codex.yaml:58-`, `github-muse.yaml:58-` each have an active `build_order:` block. `linear-codex.yaml` has none |
| Template parse test | `src/test/aiur/core_test.exs:305-333` parses every `examples/workflows/*.yaml` and the repo's `.aiur/config` with `Schema.parse/1` |
| Existing section tests | `src/test/aiur/config/build_order_test.exs` (143 lines), for example `:14-20` defaults and `:30-43` "deleted keys stay inert" |
| Only reader of `build_order` settings | `src/lib/aiur/config.ex:603-665` (three option builders). Nothing else reads `settings.build_order`, and nothing encodes the settings struct to JSON |

**Label census (aiur-team/aiur, read 2026-10-08 with `gh label list` and
`gh issue list -l <label> --state all`; earlier counts from baseline §5,
2026-10-06):**

| Label | Exists | Issues | Default epic |
| --- | --- | --- | --- |
| `bug` | yes | 411 | Bugs |
| `design` | **no** | 0 | Design |
| `refactor` | yes | 94 | Infra |
| `chore` | **no** | 0 | Infra |
| `documentation` | yes | 5 | Docs |
| `enhancement` | yes | 194 | none (Unsorted) |
| `cleanup` | yes | 1 | none |
| `security` | yes | 1 | none |
| none of `bug`/`enhancement`/`refactor`/`documentation` | — | 659 (49 %) | none |

No label in the repository starts with `epic:`.

**Design elements** (the values this ticket copies, not renders):

- `GENERAL` (J:96): `bugs` {label "Bugs", hue 38, icon "bug"}, `design`
  {"Design", 312, "pen"}, `infra` {"Infra", 200, "server"}, `docs` {"Docs", 100,
  "docs"}. The comment above it (J:95): "general epics on 4 well-separated hues;
  features take the rest".
- `epics.unsorted` (J:116): {key "unsorted", label "Unsorted", hue 0, icon
  "unsorted", unsorted: true}. It is not configurable.
- Feature epics use icon `layers` (J:120).
- Column order (J:289-292): the general epics in `GENERAL` order, then feature
  epics by feature start, then `unsorted`.
- The icons `I.bug`, `I.pen`, `I.server`, `I.docs` (J:34, 38, 39, 37) are inline
  SVGs drawn through `I[e.icon]` (for example `.bm-ep`, J:1385).
- The hue becomes `--h` on cards and lanes (J:786, 822) and feeds
  `oklch(.68 .14 var(--h))` (C:227-229), with light and Gruvbox variants
  (C:228, C:1051-1052).

## 4. Chosen design

### 4.1 Shape

```yaml
build_order:
  epics:                       # order matters: the first epic whose labels match wins (C5-T02)
    - key: bugs                # lowercase id; used in URLs (?epic=), payloads and the override CLI
      label: Bugs              # column header text
      labels: [bug]            # GitHub label names, matched without regard to case
      hue: 38                  # oklch hue 0..359 for the column and its cards
      icon: bug                # one of bug, pen, server, docs
    - { key: design, label: Design, labels: [design],          hue: 312, icon: pen }
    - { key: infra,  label: Infra,  labels: [refactor, chore], hue: 200, icon: server }
    - { key: docs,   label: Docs,   labels: [documentation],   hue: 100, icon: docs }
```

- **Absent** (no `build_order:` section, no `epics:` key, or `epics: null`) →
  the four defaults above.
- **A list** → that list replaces the defaults entirely, in the given order.
  There is no merging with defaults: a merge would make the order and the
  "first match wins" rule hard to predict.
- **`epics: []`** → no general epics. Every ticket without a feature or an
  override goes to Unsorted. This is a valid choice for a repository that uses
  only feature epics.
- **"Per repository"** is the existing config discovery
  (`./.aiur/config` → `~/.aiur/config`, AGENTS.md "Layout"). One config names one
  `tracker.github.repo`, so no repository-keyed map is needed.

### 4.2 Defaults

```elixir
@default_epics [
  %{"key" => "bugs",   "label" => "Bugs",   "labels" => ["bug"],               "hue" => 38,  "icon" => "bug"},
  %{"key" => "design", "label" => "Design", "labels" => ["design"],            "hue" => 312, "icon" => "pen"},
  %{"key" => "infra",  "label" => "Infra",  "labels" => ["refactor", "chore"], "hue" => 200, "icon" => "server"},
  %{"key" => "docs",   "label" => "Docs",   "labels" => ["documentation"],     "hue" => 100, "icon" => "docs"}
]
```

Keys, labels, hues and icons are byte-equal to `GENERAL` (J:96), in the same
order (J:290). The matchers are the row's list, checked against the census in §3.

### 4.3 Validation (all at config load)

Per entry (`BuildOrderEpic.changeset/2`):

| Rule | Error text (after `build_order.epics.<n>.`) |
| --- | --- |
| `key`, `label`, `hue`, `icon` required | `key can't be blank` (Ecto default) |
| `key` matches `\A[a-z0-9][a-z0-9_-]*\z` | `key must be a lowercase identifier (letters, digits, dash, underscore)` (same text as `github_credential.ex:53`) |
| `key` is not `unsorted` | `key is reserved for the column of tickets with no epic` |
| `label` has no control characters | `label must not contain control characters` |
| `hue` is an integer, `0 <= hue < 360` | `hue must be greater than or equal to 0` / `must be less than 360` |
| `icon` in `~w(bug pen server docs)` | `icon is invalid` (Ecto default for `validate_inclusion`) |
| each `labels` entry, after trim, is not empty | `labels must not contain a blank label` |
| no `labels` entry starts with `epic:` (after trim and downcase) | `labels must not use the epic: prefix; IssueSync treats epic:* labels as deliberate parking and stops healing those tickets` |

`labels` is normalized: each entry trimmed and downcased, then duplicates inside
one entry removed (`Enum.uniq/1`, order kept). This is the same normalization as
`issue_sync.ex:490`.

Across the list (`BuildOrder.changeset/2`, run only when every entry is valid, so
that Ecto's error merge keeps the list-level error):

| Rule | Error text (after `build_order.epics `) |
| --- | --- |
| keys are unique | `key "bugs" is used by more than one epic` |
| a normalized label belongs to at most one epic | `label "bug" is in both bugs and infra; a label can place a ticket in one epic only` |

A label in two epics is rejected rather than resolved by order. "First match
wins" in C5-T02 then only decides between *different* labels on one ticket
(for example `bug` and `refactor`), which is the EC-21 case "several type
labels, one epic still". The operator can see that case from the ticket. A
label listed twice would only be a typo.

### 4.4 Interface for consumers

- `Aiur.Config.settings/0` → `{:ok, %Aiur.Config.Schema{build_order: %{epics: [%Aiur.Config.Schema.BuildOrderEpic{}]}}}`.
- Each `%BuildOrderEpic{key, label, labels, hue, icon}` is already normalized.
  `labels` is a list of lowercase strings and may be empty (an epic reached only
  through an override, C5-T03).
- List order is the configured order. C5-T02 and C8-T04 must keep it.
- `unsorted` is never in the list. C5-T02 owns the constant
  `%{key: "unsorted", label: "Unsorted", hue: 0, icon: "unsorted"}` (J:116).
- `BuildOrderEpic.icons/0` returns the allowed icon names, so C9's icon lookup and
  this validation share one list.
- A struct built by hand (`%Aiur.Config.Schema{}` in a test) has `epics: []`,
  because Ecto forces that default. Only `Schema.parse/1` applies the four
  defaults. Tests in later tickets that need the defaults must parse a config.

## 5. Implementation steps

1. **PROPOSED `src/lib/aiur/config/schema/build_order_epic.ex`.**
   ```elixir
   defmodule Aiur.Config.Schema.BuildOrderEpic do
     @moduledoc "One general epic in `build_order.epics`: a fixed home-page column and the labels that place a ticket in it."
     use Ecto.Schema
     import Ecto.Changeset

     # The design's general-epic icons (build.js GENERAL). `layers` marks feature
     # epics and `unsorted` the fallback column, so neither is offered here.
     @icons ~w(bug pen server docs)

     @primary_key false
     embedded_schema do
       field(:key, :string)
       field(:label, :string)
       field(:labels, {:array, :string}, default: [])
       field(:hue, :integer)
       field(:icon, :string)
     end

     @spec icons() :: [String.t()]
     def icons, do: @icons

     def changeset(epic, attrs) do
       epic
       |> cast(attrs, [:key, :label, :labels, :hue, :icon], empty_values: [])
       |> validate_required([:key, :label, :hue, :icon])
       |> validate_format(:key, ~r/\A[a-z0-9][a-z0-9_-]*\z/, message: "must be a lowercase identifier (letters, digits, dash, underscore)")
       |> validate_exclusion(:key, ["unsorted"], message: "is reserved for the column of tickets with no epic")
       |> validate_change(:label, &no_control_chars/2)
       |> validate_number(:hue, greater_than_or_equal_to: 0, less_than: 360)
       |> validate_inclusion(:icon, @icons)
       |> validate_change(:labels, &validate_labels/2)
       |> update_change(:labels, &normalize_labels/1)
     end
     # validate_labels: blank → error; String.starts_with?(normalized, "epic:") → error
     # normalize_labels: Enum.map(&(&1 |> String.trim() |> String.downcase())) |> Enum.uniq()
     # no_control_chars: same codepoint test as the private
     # Aiur.Config.Schema.Decisions.unsafe_control_chars?/1
     # (src/lib/aiur/config/schema/decisions.ex:57-61): any codepoint < 0x20 or == 0x7F
   end
   ```
   Add `@spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()` above
   `changeset/2`: `mix lint` runs `specs.check`, which fails on a public `def`
   without an adjacent `@spec` (CONTRIBUTING.md "Enforcement").
   `@primary_key false` is required, not style: without it Ecto gives each
   embedded entry an autogenerated `id`, so two parses of the same config would
   no longer be equal and `build_order_test.exs:30-43` would fail.
   Validate before normalizing, so the blank and `epic:` checks see the trimmed,
   downcased value inside `validate_labels/2` (it normalizes each entry itself).

2. **`src/lib/aiur/config/schema/build_order.ex`.**
   - Add `alias Aiur.Config.Schema.BuildOrderEpic`, the `@default_epics` attribute
     (§4.2), and `embeds_many(:epics, BuildOrderEpic, on_replace: :delete)` inside
     `embedded_schema` (after `:40`).
   - In `changeset/2`: first `attrs = Map.put_new(attrs, "epics", @default_epics)`;
     then the existing pipeline; then `|> cast_embed(:epics, with: &BuildOrderEpic.changeset/2)`
     and `|> validate_unique_epics()` (§4.3, both rules). Sketch:
     ```elixir
     defp validate_unique_epics(changeset) do
       case get_change(changeset, :epics) do
         children when is_list(children) ->
           if Enum.all?(children, & &1.valid?),
             do: check_unique(changeset, Enum.map(children, &apply_changes/1)),
             else: changeset
         _no_change -> changeset   # `epics: []` on the [] struct default is no change
       end
     end
     # check_unique/2: add_error(changeset, :epics, ...) for the first duplicate key,
     # then for the first normalized label held by two epics (§4.3 texts).
     ```
     Skipping the check while a child is invalid matters: `traverse_errors/2`
     replaces a field's own errors with the child list when any child has errors
     (`deps/ecto/lib/ecto/changeset.ex:4272-4275`), so the list-level error
     would be lost anyway, and the child data is not normalized yet.
   - Keep the comment short: one line on why defaults go into the attrs (Ecto
     forces `default: []` on `embeds_many`).

3. **`src/lib/aiur/config/schema.ex` `changeset/1` (`:142`).** Before the cast:
   `attrs = Map.put_new(attrs, "build_order", %{})`, with a one-line comment: the
   section's changeset must run so that the `build_order.epics` defaults apply
   when the section is absent. `parse/1` already passes string keys (`:76`).

3a. **`src/lib/aiur/config/schema/errors.ex` `flatten_errors/2` (`:29-31`).**
   Replace the list clause so that it also flattens a list of child maps with the
   entry index (0-based) in the path. Without this, every per-entry error in
   §4.3 raises `ArgumentError` inside `Schema.parse/1` (§3, "Error text"):
   ```elixir
   def flatten_errors(errors, prefix) when is_list(errors) and is_binary(prefix) do
     errors
     |> Enum.with_index()
     |> Enum.flat_map(fn
       {message, _index} when is_binary(message) -> [prefix <> " " <> message]
       {nested, index} when is_map(nested) -> flatten_errors(nested, "#{prefix}.#{index}")
     end)
   end
   ```
   Valid children are `%{}` and add nothing. Checked 2026-10-08 on a copy under
   Elixir 1.19.5: `%{build_order: %{epics: [%{}, %{icon: ["is invalid"]}]}}` →
   `["build_order.epics.1.icon is invalid"]`, and a string list still gives
   `["build_order.epics key \"bugs\" is used by more than one epic"]`. This also
   fixes the same crash for `tracker.github.credentials`. It is a bug fix with no
   interface change, so it needs no docs.

4. **Docs: `website/docs-app/reference/configuration.md`.** In the `build_order`
   table (`:735-747`) add, following the credentials pattern (`:94-100`):
   - `build_order.epics` | array | Bugs, Design, Infra, Docs (below) | The general
     epic columns of the home page, in order. A ticket goes to the first epic whose
     `labels` it carries; a feature epic or an override (`aiur epic set`) comes
     first. A list replaces the defaults; `[]` turns general epics off.
   - `build_order.epics.key` | string | required | Lowercase id. `unsorted` is
     reserved.
   - `build_order.epics.label` | string | required | Column header text.
   - `build_order.epics.labels` | array | `[]` | GitHub label names, matched without
     regard to case. A label may appear in one epic only. `epic:` labels are
     refused, because `epic:*` marks parked tickets.
   - `build_order.epics.hue` | integer | required | Colour hue, 0–359.
   - `build_order.epics.icon` | string | required | One of `bug`, `pen`, `server`,
     `docs`.
   Then a short `### General epics` subsection with the §4.1 YAML as the default
   block, and one sentence on `enhancement`: it is not in any default epic, so a
   repository that uses it for most work adds it to an epic itself.
   Do **not** mention `aiur epic set` as working until C5-T03 merges; if this
   ticket merges first, word it as "an override (MP-E8 C5-T03)" or leave the clause
   out and let C5-T03 add it. The implementer picks by checking whether
   `aiur epic` exists on main.

5. **Templates.**
   - `.aiur/examples/config.example`: inside the commented `# build_order:` block
     (`:184-201`), after `ticket_history_stale_after_ms`, add the commented §4.1
     list with a one-line comment: "General epic columns; order matters; omit for
     these defaults, [] for none."
   - `src/examples/workflows/github-claude.yaml`, `github-codex.yaml`,
     `github-muse.yaml`: the same block, **commented**, at the end of each
     `build_order:` block. Commented, so a project that copies a template keeps
     following aiur's defaults.
   - `linear-codex.yaml`: unchanged. It has no `build_order:` block, and the home
     page's history store (C4-T01) indexes the configured GitHub repository.

6. **Tests** (§8) in `src/test/aiur/config/build_order_test.exs`, plus V-17 in
   `src/test/aiur/config/schema/errors_test.exs`.

7. Run `scripts/check-config-docs.py`, `mix format --check-formatted`, the touched
   tests, `mix lint` (`specs.check` + `credo --strict`, CONTRIBUTING.md:264-274).

## 6. Non-happy paths

- **Invalid entry at boot.** `Schema.parse/1` returns
  `{:error, {:invalid_workflow_config, "build_order.epics.1.icon is invalid"}}`;
  startup fails with that text, like every other config error. No partial list is
  used. This text exists only with step 3a; on `58854d4c8` the same input raises
  `ArgumentError` from `Errors.flatten_errors/2`, and a raise inside
  `Config.settings/0` would hit every reader instead of returning `{:error, _}`.
- **Invalid edit while running.** `WorkflowStore` reloads the file within about
  1 s; `Config.settings/0` then returns `{:error, _}`, and `settings!/0` raises
  for every reader, as it does for any config error today. This ticket adds no
  fallback. **A consumer must not substitute the defaults on `{:error, _}`:** the
  page would then show columns the operator did not configure as if they were
  current. C8-T04 renders the epic catalogue as unavailable instead (handoff note 4).
- **`epic:` matcher.** Rejected with the reason in the message (§4.3), because
  following it would lead operators to put `epic:*` labels on ordinary tickets
  and silently turn off strand recovery for them (`issue_sync.ex:479-493`).
- **Label in two epics; duplicate key; `unsorted` as a key.** Rejected (§4.3).
  These are the config half of EC-21: the resolver can then return exactly one
  epic without a tie-break that depends on label order on GitHub.
- **Case and spaces.** `" Bug "` and `"BUG"` are stored as `"bug"`, so a matcher
  never misses a label because of case.
- **Epic with no labels.** Valid. It is an empty column until overrides
  (C5-T03) or features fill it. The page does not show an empty general column
  as a count of 0 for a source it cannot see: column visibility is C9-T04's.
- **Unknown future keys inside an entry** (for example a typo `colour:`).
  `cast/3` ignores them, as for every other section (`build_order.ex:28-37`
  comment). Not changed here, to keep config behaviour uniform.
- **Security and privacy.** Labels and keys are operator-written config. They
  are rendered later as text and are escaped there (EC-30, C9). No secrets, no
  network calls, no GitHub reads or writes.
- **Concurrency, retries, idempotency.** Not applicable: parsing is a pure
  function of the file.

## 7. Compatibility and rollout

- **Existing configs** load unchanged and gain the four defaults. No key is
  renamed or removed.
- **The repo's own `.aiur/config`** needs no change. Its effective epics are the
  defaults. `core_test.exs:318-325` parses it, so a break there fails CI.
- **Nothing reads `epics` until C5-T02/C8-T04 merge**, so this ticket changes no
  runtime behaviour on its own. It can ship and be reverted alone.
- **Packaging.** No new dependency, no release config, no migration.
- **Rollback.** Revert the commit. A config that already sets `epics` keeps
  loading after the revert, because `cast/3` ignores unknown keys.

## 8. Verification

V-1..V-16 go in `src/test/aiur/config/build_order_test.exs` and V-17 in
`src/test/aiur/config/schema/errors_test.exs` (`async: true`; no HOME, ledger or
live path is read: `Schema.parse/1` is pure). Every error-path test (V-6, V-8..V-16)
asserts the returned `{:error, {:invalid_workflow_config, msg}}` tuple, so each one
also fails (with `ArgumentError`) when step 3a is reverted. For each, the
"fails without" column names the production hunk whose revert makes it fail
(AGENTS.md "Tests must fail without the production change they guard").

| # | Test | Input | Expected | Fails without |
| --- | --- | --- | --- | --- |
| V-1 | "defaults are the design's four general epics, in design order" | `Schema.parse(%{})` | `Enum.map(epics, &{&1.key, &1.label, &1.hue, &1.icon}) == [{"bugs","Bugs",38,"bug"}, {"design","Design",312,"pen"}, {"infra","Infra",200,"server"}, {"docs","Docs",100,"docs"}]` and `labels` == `[["bug"],["design"],["refactor","chore"],["documentation"]]` | step 3 (root `put_new`): the section changeset never runs and `epics == []` |
| V-2 | "defaults apply when the section exists without epics" | `%{"build_order" => %{"graph_max_inflight" => 2}}` | same four keys | step 2 `Map.put_new(attrs, "epics", ...)` |
| V-3 | "`epics: null` means the defaults" | `%{"build_order" => %{"epics" => nil}}` | same four keys | step 2 (`drop_nil_values` removes the null, so without the `put_new` the list is `[]`) |
| V-4 | "guard: an empty list turns general epics off" | `%{"build_order" => %{"epics" => []}}` | `epics == []` | **Guard, not coverage.** With step 2 reverted the list is also `[]`, so it passes. It catches a future change of step 2 to "empty → defaults"; name it as a guard in the test and do not count it (AGENTS.md) |
| V-5 | "a configured list replaces the defaults and keeps its order" | two entries `runtime` then `bugs` | keys `["runtime","bugs"]`; no `design` | catches a merge-with-defaults mutation |
| V-6 | "an epic: matcher is refused with the parking reason" | `labels: ["  Epic:Bugs "]` | `{:error, {:invalid_workflow_config, msg}}`, `msg =~ "build_order.epics.0.labels must not use the epic: prefix"` | the `epic:` check in `validate_labels/2`; also step 3a (raises instead) |
| V-7 | "labels are trimmed, downcased and deduplicated" | `labels: [" Bug ", "bug", "BUG"]` | `labels == ["bug"]` | `normalize_labels/1` |
| V-8 | "a label in two epics is refused" | `bug` in `bugs` and `infra` | error message contains `build_order.epics`, `"bug"`, `bugs` and `infra` | `validate_unique_epics/1` label rule. The fixture uses two labels that differ only by case (`bug`, `Bug`), so it also proves the check runs after normalization |
| V-9 | "duplicate keys are refused" | two `bugs` entries | error `key "bugs" is used by more than one epic` | `validate_unique_epics/1` key rule |
| V-10 | "unsorted is reserved" | `key: "unsorted"` | error `is reserved` | `validate_exclusion` |
| V-11 | "key format" | `key: "Bugs"`, `key: "-x"` | both refused | `validate_format` |
| V-12 | "hue bounds" | `hue: 360`, `hue: -1` refused; `hue: 0`, `hue: 359` accepted | as stated | `validate_number` |
| V-13 | "icon must be a design general-epic icon" | `icon: "layers"`, `"unsorted"`, `"rocket"` refused; each of `bug pen server docs` accepted | as stated | `validate_inclusion(:icon, @icons)` |
| V-14 | "required fields" | an entry missing each of `key`, `label`, `hue`, `icon` in turn | each refused naming the field | `validate_required` |
| V-15 | "a blank label is refused" | `labels: ["  "]` | refused | blank check |
| V-16 | "label control characters are refused" | `label: "Bugs\u0007"` | refused | `no_control_chars/2` |
| V-17 | "flattens a list of child error maps with the entry index" (errors_test.exs) | `%{build_order: %{epics: [%{}, %{icon: ["is invalid"]}]}}`; and `%{a: ["x"]}` | `["build_order.epics.1.icon is invalid"]`; `["a x"]` unchanged | step 3a (the old clause raises `ArgumentError` on `%{}`) |

V-1 is the value-parity test (§9). Its literal values cite J:96 in a comment.

**Existing tests that must stay green:** `build_order_test.exs` (the struct
equality at `:42` compares two parsed configs, and both now carry the same
defaults), `configuration_reference_test.exs`, `core_test.exs:305-333` (the
templates still parse, including the commented blocks), and
`scripts/test-check-config-docs.sh`.

**Commands** (from the repository root; the runtime suite boots the app, so
follow the workspace's `mix test` isolation rules):

```bash
env -C src mise exec -- mix test test/aiur/config/build_order_test.exs test/aiur/configuration_reference_test.exs test/aiur/core_test.exs
python3 scripts/check-config-docs.py      # must print "all N config keys are documented"
bash scripts/test-check-config-docs.sh
env -C src mise exec -- mix format --check-formatted
env -C src mise exec -- mix lint
```

**Mutation check (author side, AGENTS.md):** in a worktree, revert each production
hunk named in the "fails without" column one at a time; `git status --porcelain`
must show only that file; run V-n; it must fail; restore; it must pass. Report the
exact commands in the PR body, one line per test.

**Docs check:** delete the new `build_order.epics.hue` row locally and confirm
`scripts/check-config-docs.py` exits 1 naming `build_order.epics.hue`. This proves
the checker reaches the `embeds_many` module (`EMBEDS_RE`, `check-config-docs.py:70`).

**Manual check.** Not a UI change, so the AGENTS.md TUI recipe does not apply.
`aiurdev status` is not a config check: it is a control RPC to the running node
(`aiur-engine.sh:2656-2659` `cmd_status` → `run_control_rpc`), so it never parses a
scratch config. Instead, copy the repo's `.aiur/config` and its prompt file into a
temp directory, append
`build_order: { epics: [{ key: x, label: X, labels: ["epic:x"], hue: 1, icon: bug }] }`
(merge into the existing `build_order:` block), and run, without starting the app:
`env -C src mise exec -- mix run --no-start -e 'path = "<tmp>/config"; {:ok, %{config: c}} = Aiur.Workflow.load(path); IO.inspect(Aiur.Config.Schema.parse(c))'`.
It must print `{:error, {:invalid_workflow_config, "build_order.epics.0.labels must not use the epic: prefix; ..."}}`.
Remove the block and confirm `{:ok, _}` with four default epics.
(`Aiur.Workflow.load/1` is `src/lib/aiur/workflow.ex:212`; `core_test.exs:322-324`
uses the same two calls.)

## 9. Pixel parity

This ticket draws nothing, so the C1-T02 side-by-side harness has nothing of its
own to compare. Parity depends on it in one way: the home page on real data
(C8-T04, checked by C12-T08 with the C1-T02 runner) colours every general column,
card stripe, lane border and epic chip from `--h` (J:786, 822;
C:227-229, 478, 689-696, 751, 935-936, 1051-1052), and draws its icon through
`I[e.icon]` (J:1385). Those values come from this config.

- **What must match exactly:** for each of the four defaults, `key`, `label`,
  `hue` and `icon` equal `GENERAL` (J:96), and the list order equals J:290
  (`["bugs","design","infra","docs"]`). The column order on the page is then the
  design's (J:289-292).
- **How it is checked:**
  1. V-1 asserts the values and order literally, with J:96 cited.
  2. Handoff note 5: when the C1-T01 fixture export and C8-T04 both exist, an
     ExUnit test (owned by C8-T04, not C12-T08) compares
     the `epics` of the exported `live` fixture with the epic catalogue built
     from `Schema.parse(%{})`. Any drift between the design and the defaults then
     fails in CI, not only on screen.
  3. The C1-T02 element-level mode on `.bd-lanes` (the lane headers) with the
     real DataSource, at C12-T08.
- **No new visual.** Configured epics beyond the four reuse the same CSS through
  `--h` and one of the four icons. That is why the icon set is closed (§10, item 3).

## 10. Decisions made without the owner

1. **`build_order.epics` in the existing `build_order:` section, not a new
   `Aiur.Config.Schema.BuildHistory` section** (the row's PROPOSED name). Reuse
   first: the section exists, the resolver lives in `Aiur.BuildOrder` (C5-T02 row),
   and the store is `Aiur.BuildOrder.History` (C4-T01). A new root section would
   add a module, a root embed, a reference heading and a test-section entry for
   one key. If MP-R1 later moves or splits the `build_order` config section, the
   key moves with it. (CR-E8-6 is about module placement only and does not
   mention config.) Settled 2026-10-08: C5-T03 and C6-T01 read
   `settings.build_order.epics`; there is no `BuildHistory` schema.
2. **Default matchers:** Bugs ← `bug`, Design ← `design`, Infra ← `refactor`,
   `chore`, Docs ← `documentation` (the row's list plus `design`, which the row
   left empty). `design` and `chore` match nothing in aiur-team/aiur today (§3
   census) and are kept as portable defaults for other repositories.
   `enhancement` (194 issues) is in no default epic. E8-D9 replaced
   "Improvements" with "Design", and mapping `enhancement` to Design would put
   unrelated feature work in the Design column. Those issues show in Unsorted
   until the C13 backfill classifies them.
3. **Closed icon set `bug pen server docs`.** The design has exactly these four
   general-epic icons. `layers` and `unsorted` have fixed meanings (J:116, 120).
   The other `I` icons (`chore`, `feature`) are ticket-type icons (J:187), not
   epic icons. A new icon is a design request to Kevin.
4. **A label in two epics is a config error,** not "first wins". The resolver's
   order rule is kept for the real case: one ticket carrying two different
   matched labels.
5. **`epics: []` is allowed** and means "no general epics". Absent and `null`
   mean the defaults.
6. **A configured list replaces the defaults; it does not merge with them.**
7. **No lifecycle-label check.** A matcher such as `agent:todo` would be odd but
   harmless (matching only reads labels), so no cross-section check against
   `tracker.github.label_prefix` is added. Only `epic:` is refused, because only
   it causes harm.
8. **No count or length bound** on the list or the label text beyond the rules in
   §4.3. The design shows four general columns; a bound would be a guess. C9-T04
   owns how many columns fit.
9. **No `Aiur.Config` accessor.** Consumers read the struct from `settings/0`.
   That keeps the `{:error, _}` case visible to them (§6) instead of hiding it
   behind `settings!/0`.
10. **Templates carry the block commented,** so copying a template does not pin a
    project to today's defaults.
11. **`linear-codex.yaml` gets no block,** although the row says
    `src/examples/workflows/*`. That template has no `build_order:` section and
    the history store (C4-T01) indexes the configured GitHub repository, so a
    block there would document a setting that does nothing for Linear.
12. **The `errors.ex` fix is in scope.** It is the smallest change that lets the
    row's validation report at all (§3); without it every bad entry crashes
    config load. It also fixes `tracker.github.credentials`, with no behaviour
    change for valid configs.

## 11. Completion and handoff

**Acceptance checklist**

- [ ] `Aiur.Config.Schema.BuildOrderEpic` exists with the §4.3 validation and
      `icons/0`.
- [ ] `build_order.epics` defaults to the four design epics when the section, the
      key or its value is absent; `[]` gives `[]`; a list replaces the defaults in
      order.
- [ ] `epic:` matchers, duplicate keys, duplicate labels across epics, the
      `unsorted` key, bad hues and icons are refused with the §4.3 messages.
- [ ] `Errors.flatten_errors/2` reports per-entry errors as
      `<section>.<list>.<n>.<field> <message>` and never raises on a list of maps.
- [ ] V-1..V-17 pass, and each (except the guard V-4) fails with its production
      hunk reverted (results and commands in the PR body).
- [ ] `scripts/check-config-docs.py` passes; the six reference rows and the
      "General epics" subsection exist.
- [ ] `config.example` and the three GitHub workflow templates carry the
      commented block; `core_test.exs` still parses every template.
- [ ] `mix format --check-formatted` and `mix lint` pass.

**Handoff notes for neighbour tickets**

1. **C5-T02 (resolver).** Read `settings.build_order.epics` (§4.4). Labels are
   already lowercase and trimmed: normalize the ticket's labels the same way
   before matching. Iterate the list in order. `unsorted` is the resolver's own
   constant (J:116). The row's source tag `label:<name>` uses the normalized name.
2. **C5-T03 (override CLI).** "An unknown epic is rejected" means: not a key in
   this list, not a feature epic key, and not `unsorted` (if overriding to
   Unsorted is allowed at all, which C5-T03 decides).
3. **C6-T01 (features).** Feature epic keys must not equal a configured general
   key or `unsorted`; validate against this list at `aiur feature create` time.
   The "free hue range" must be computed from the configured hues, because a
   project can change them.
4. **C8-T04 (assembler).** On `Config.settings/0` → `{:error, _}`, mark the epic
   catalogue unavailable. Never fall back to the defaults (AGENTS.md "Unknown is
   never zero"; EC-07). Add `general: true` to each entry and append `unsorted`
   to match the design's `epics` object (J:115-116).
5. **C8-T04 (parity guard).** Settled 2026-10-08: C8-T04 owns the
   design-vs-defaults epic parity test (default config epics equal the design's
   `epics`, J:115-116; §9 item 2).
6. **C12-T07 (docs).** Link the concepts page to `reference/configuration.md`
   "General epics" rather than restating the defaults.

**Documentation updated in this ticket:** `website/docs-app/reference/configuration.md`,
`.aiur/examples/config.example`, `src/examples/workflows/github-{claude,codex,muse}.yaml`.
No CLI, skill or concepts page changes here (C5-T03, C5-T04, C12-T07).

**Residual risks (for the Executor).**
- The §9 item 2 fixture-vs-defaults parity test is owned by C8-T04. Until
  C8-T04 merges, design-vs-default drift is caught only by V-1's literals.
- If DESIGN-E8 changes the palette (DESIGN-E8 item "palette for epics and
  features"), only §4.2 and V-1 change.

**Sources:** row and chunk (tickets/README.md C5; chunks.md "MP-E8-C5"),
decisions.md E8-D1, E8-D9, E8-D13; options.md §1.1-1.4; baseline.md §2.2, §5;
plan.md §3 (E8-Q4), §8 (EC-21); design `J:33-41, 95-96, 116-120, 187, 289-293,
786, 822, 1385`, `C:227-229, 478, 1051-1052`; code paths in §3.

**Remaining blocker:** DESIGN-E8 sign-off only.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8` and the design source.

1. **Blocking: error flattening crashes on list entries.** `errors.ex:29-31`
   cannot flatten the list of child maps that `traverse_errors/2` returns for an
   invalid `embeds_many` entry; reproduced the `ArgumentError`. The ticket
   claimed `build_order.epics.<n>.<field>` messages already worked. Added step 3a
   (indexed flatten clause, checked on a copy), V-17, the §3 row, the §1
   deliverable, the §2 file list, the §6 note, §10 item 12 and a checklist line.
2. **Wrong manual check.** `aiurdev status` is a control RPC and never parses a
   scratch config. Replaced with a `mix run --no-start` parse through
   `Aiur.Workflow.load/1` and `Schema.parse/1`.
3. **Vacuous-as-coverage test.** V-4 passes with step 2 reverted; marked as a
   guard and excluded from the mutation count.
4. **Wrong path.** `decisions.ex:57-61` is
   `src/lib/aiur/config/schema/decisions.ex:57-61`, and the helper is private.
5. **Missing `@spec`** on `BuildOrderEpic.changeset/2` (would fail
   `specs.check`); added, with the reason `@primary_key false` is required.
6. **Underspecified list-level check.** Added a `validate_unique_epics/1` sketch
   and the Ecto reason (`changeset.ex:4272-4275`) for skipping it while a child
   is invalid.
7. **Wrong cite.** §10 item 1 said CR-E8-6 splits `build_order`; it does not.
   Reworded, and named the neighbour tickets that still say `BuildHistory`.
8. **Silent scope drop.** The row lists `src/examples/workflows/*`; the
   `linear-codex.yaml` exclusion is now a recorded decision (§10 item 11).
9. **Residual risks** listed in §11 (unowned parity guard, palette change).

Verified unchanged: every other cited path and line (`schema.ex:68,74-90,142-184`,
`build_order.ex`, `tracker.ex:71`, `github_credential.ex:28-54`,
`ecto/schema.ex:2216-2219`, `attrs.ex`, `issue_sync.ex:479-493`,
`config.ex:184-192,603-665`, `workflow_store.ex`, `check-config-docs.py`,
`configuration_reference_test.exs`, `configuration.md`, `config.example`,
`templates.ex:26`, the workflow templates, `core_test.exs:305-333`); the design
values `GENERAL` (J:96), J:34-41, J:116, J:120, J:290, J:786, J:822, J:1385 and
C:227-229, 478, 1051-1052; and the interface used by C5-T02 and C8-T04.
- Reconciliation 2026-10-08 (coordinator): design-vs-defaults epic parity test owned by C8-T04 (§9 item 2, handoff note 5, residual risk), `BuildHistory` neighbour note marked settled (§10 item 1).
