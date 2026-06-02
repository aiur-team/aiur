---
date: 2026-05-31
status: active
topic: aiurconfig-replaces-workflow
origin: elixir/docs/brainstorms/2026-05-31-aiurconfig-replaces-workflow-requirements.md
---

# Plan: `.aiurconfig` Replaces `WORKFLOW.md` as the Single Config File

## Problem Frame

aiur loads run config through two formats. `WORKFLOW.md` carries YAML front-matter
**plus** a Liquid prompt body; `.aiurconfig` is pure YAML with no body. `Aiur.Workflow`
prefers `.aiurconfig` in cwd, falls back to `WORKFLOW.md`, and `parse/2` branches on the
basename. The goal is one canonical format: `.aiurconfig` becomes **the** aiur config file
for every run. `WORKFLOW.md` parsing is removed entirely (hard cutover). The only thing the
`WORKFLOW.md` body did that pure YAML does not — carry a custom agent prompt — moves to an
optional `prompt_file:` key pointing at a standalone markdown Liquid template.

This plan builds from the requirements doc (see origin). All Requirements (R1–R13) and
Acceptance Examples (AE1–AE5) are carried forward as constraints.

## Scope Boundaries (carried from origin)

- No migration tool / auto-converter for external repos. Hard cutover.
- No change to agent prompt **content** — relocation is byte-for-byte verbatim (R11).
- No change to `shared-agent-instructions.md` or the complexity-suffix mechanism.
- No rename of the `Aiur.Workflow` module or "workflow" domain vocabulary. **Decision
  (resolves origin Deferred-to-Planning question `[Affects R2]` — module renaming):** keep the
  module name and the `:workflow_file_path`
  app-env key. Renaming would balloon the diff across ~13 files for zero behavior gain.
  Moduledoc text is updated to say `.aiurconfig`; the term "workflow" stays as the internal
  domain noun.

## Key Technical Findings (from Phase 1 investigation)

1. **The config schema already ignores unknown top-level keys.** `Aiur.Config.Schema.changeset/1`
   (`elixir/lib/aiur/config/schema.ex:516`) uses Ecto `cast` with an explicit field list plus
   `cast_embed`. Ecto drops unrecognized keys silently. A top-level `prompt_file:` key therefore
   needs **no schema change** and is harmless if it flows through `Config.prepare_config/1`.
   `prompt_file` is handled entirely inside `Aiur.Workflow` before config is consumed.

2. **Parsing must stop keying on basename.** Tests set arbitrary-named explicit config paths
   (`THIRD_WORKFLOW.md`, `MANUAL_WORKFLOW.md`) via `set_workflow_file_path`. Per R3, once
   front-matter parsing is gone, `load/1` always parses pure YAML regardless of basename. An
   explicit path is honored; only its **content** must be `.aiurconfig`-format YAML.

3. **`prompt_file:` resolves relative to the config file's directory** (R5). Resolved with
   `Path.expand(prompt_file, Path.dirname(config_path))`.

4. **Largest single conversion is the test helper.** `elixir/test/support/test_support.exs`
   `write_workflow_file!/2` + `workflow_content/1` emit front-matter+body (with `---` fences)
   and a `prompt:` override. It feeds ~6 test files. It must be rewritten to emit pure-YAML
   `.aiurconfig` and, when a `prompt:` override is given, a sibling prompt file + `prompt_file:`.

5. **R9 reconciliation: no `elixir/WORKFLOW.md` or root `WORKFLOW.md` exists.** The root
   `AGENTS.md` "Layout" line claiming `elixir/WORKFLOW.md — generic template` is **stale**.
   Real conversions: two `elixir/local-workflows/WORKFLOW.*.local.md`, three
   `elixir/examples/workflows/*.md`, `elixir/test/fixtures/test_workflow.md`, and the test
   helper. The AGENTS.md line is corrected, not honored.

## Design: Loading + `prompt_file`

New `Aiur.Workflow` behavior:

```
load(path):
  read file → decoded = pure-YAML map        # no basename branch, no front-matter split
  case Map.get(decoded, "prompt_file"):
    nil / "" →
      {:ok, %{config: decoded, prompt: "", prompt_template: ""}}   # R7: default fallback
    rel_path →
      resolved = Path.expand(rel_path, Path.dirname(path))
      case File.read(resolved):
        {:ok, body} →
          tmpl = String.trim(body)
          {:ok, %{config: decoded, prompt: tmpl, prompt_template: tmpl}}
        {:error, reason} →
          {:error, {:missing_prompt_file, resolved, reason}}        # R8: clear error
```

- `config` keeps the `prompt_file` key (Ecto ignores it; introspection-friendly).
- `detect_run_folder_config/0` returns `Path.join(cwd, ".aiurconfig")` only — no
  `WORKFLOW.md` fallback (R2, R4). When that file is absent, the existing
  `{:error, {:missing_workflow_file, path, :enoent}}` surfaces; the error message in CLI/boot
  paths is updated to name `.aiurconfig` and `aiur init` (R4).
- `parse_front_matter/1`, `split_front_matter/1`, and the basename branch in `parse/2` are
  deleted. `@workflow_file_name "WORKFLOW.md"` module attr is removed.

This is directional. The implementer owns exact function arity and error-tuple shape, but the
error atom `:missing_prompt_file` and the no-basename-branch invariant are fixed by AE4/R3.

## File Naming After Cutover (resolves origin Deferred-to-Planning question `[Affects R3]` — operator file naming)

Operator profiles need distinct names (multiple profiles, one repo). Since basename no longer
drives loading:

| Old | New config | New prompt file |
|-----|-----------|-----------------|
| `elixir/local-workflows/WORKFLOW.aiur.local.md` | `elixir/local-workflows/aiur.local.aiurconfig` | `elixir/local-workflows/aiur.local.prompt.md` |
| `elixir/local-workflows/WORKFLOW.actions.local.md` | `elixir/local-workflows/actions.local.aiurconfig` | `elixir/local-workflows/actions.local.prompt.md` |
| `elixir/examples/workflows/github-claude.md` | `elixir/examples/workflows/github-claude.aiurconfig` | `elixir/examples/workflows/github-claude.prompt.md` |
| `elixir/examples/workflows/github-codex.md` | `elixir/examples/workflows/github-codex.aiurconfig` | `elixir/examples/workflows/github-codex.prompt.md` |
| `elixir/examples/workflows/linear-codex.md` | `elixir/examples/workflows/linear-codex.aiurconfig` | `elixir/examples/workflows/linear-codex.prompt.md` |
| `elixir/test/fixtures/test_workflow.md` | `elixir/test/fixtures/test.aiurconfig` | (none — body is disposable doc-prose, see below) |

Each `.aiurconfig` is the front-matter block verbatim (minus the `---` fences) plus a
`prompt_file:` key pointing at its sibling prompt. Each prompt file is the old body **verbatim**
(R11). The test fixture's body is **not** empty — it carries a `# Test Workflow` heading plus a
descriptive paragraph (no `{{ issue.* }}` template, no agent instructions). That body is
intentionally **dropped** during conversion: no test asserts a non-empty prompt for the fixture
(the "examples parse" test scopes to `examples/` + `local-workflows/` only), so `test.aiurconfig`
gets no `prompt_file:` key and the prompt defaults to the built-in template. This is a deliberate
discard, not a verbatim relocation.

## Implementation Units

### U1: Rewrite `Aiur.Workflow` loader (config-format core)
- **Goal:** `.aiurconfig` is the only format; pure-YAML always; `prompt_file:` support; no
  `WORKFLOW.md` fallback. Covers R1, R2, R3, R4, R5, R6, R7, R8.
- **Files:**
  - Modify: `elixir/lib/aiur/workflow.ex`
  - Test: `elixir/test/aiur/workflow_test.exs`
- **Approach:** Implement the design above. Delete `parse_front_matter/1`,
  `split_front_matter/1`, the `parse/2` basename branch, and `@workflow_file_name`. Update
  moduledoc to reference `.aiurconfig`. Keep `set_workflow_file_path/1`,
  `clear_workflow_file_path/0`, `current/0`, and the `WorkflowStore` reload path unchanged.
- **Patterns to follow:** existing `parse_pure_yaml/1` and `front_matter_yaml_to_map/1`
  (reuse for the always-pure-YAML path); existing error tuple
  `{:error, {:missing_workflow_file, path, reason}}` shape for the new `:missing_prompt_file`.
- **Test scenarios (rewrite `workflow_test.exs`):**
  - Happy: a pure-YAML `.aiurconfig` with no `prompt_file:` → `config` populated,
    `prompt == ""`, `prompt_template == ""` (AE3).
  - Happy: `.aiurconfig` with `prompt_file: prompt.md` and the sibling present → `prompt` is
    the trimmed template contents, `config` populated (AE2 loader half).
  - Edge: `prompt_file:` resolves relative to the **config file's directory**, not cwd (write
    config in a subdir, prompt alongside it, `File.cd!` elsewhere, assert it still loads).
  - Edge: empty-string `prompt_file: ""` → treated as absent (default fallback).
  - Error: `prompt_file:` points at a missing file →
    `{:error, {:missing_prompt_file, resolved, :enoent}}` (AE4).
  - Error: `.aiurconfig` decodes to a non-map → `{:error, :workflow_front_matter_not_a_map}`
    (preserve existing behavior).
  - **Delete** the two `characterization: legacy WORKFLOW.md` tests and the
    `prefers .aiurconfig over WORKFLOW.md` / `falls back to WORKFLOW.md` tests — the behavior
    they assert is being removed. Replace the "explicit override wins" test so the override
    file is a pure-YAML file with a non-`.aiurconfig` basename (proves R3: arbitrary basename,
    pure-YAML content).

### U2: Update `detect_run_folder_config` + CLI no-arg default + error messaging
- **Goal:** cwd resolution returns only `.aiurconfig`; the bare-`aiur` (no positional arg)
  default targets `.aiurconfig`; missing-config error names `.aiurconfig` and `aiur init` (R4).
- **Files:**
  - Modify: `elixir/lib/aiur/workflow.ex` (folded into U1 commit if small).
  - Modify: `elixir/lib/aiur/cli.ex` — **three sites** (verified via grep):
    - **line 109** `run(Path.expand("WORKFLOW.md"), deps)` — the no-positional-arg default. This
      is a config-reading path independent of `detect_run_folder_config/0`; change to
      `Path.expand(".aiurconfig")` (or call `Aiur.Workflow.detect_run_folder_config/0`). **This
      is the highest-risk site — three reviewers independently flagged it.** A bare `aiur`
      invocation breaks without it.
    - **line 141** the `"Workflow file not found: #{expanded_path}"` banner — update to name
      `.aiurconfig` + `aiur init` (R4). This is a *distinct* string from the
      `:missing_workflow_file` tuple; both must be reworded.
    - **line 3** moduledoc and **line 147** `usage_message` (`[path-to-WORKFLOW.md]`) → `.aiurconfig`.
  - Modify: any boot path that renders `:missing_workflow_file` (grep for it).
  - Test: `elixir/test/aiur/cli_test.exs`, `elixir/test/aiur/core_test.exs`
- **Approach:** `detect_run_folder_config/0` → `Path.join(cwd, @config_file_name)`. Grep
  `WORKFLOW.md` in `cli.ex` first — do not assume the no-arg default lives behind the cwd helper.
- **Test scenarios:**
  - `core_test` "defaults to ... in cwd when app env unset" → assert the path ends in
    `.aiurconfig` (was `WORKFLOW.md`).
  - `cli_test` "defaults to WORKFLOW.md when workflow path is missing" (lines ~62–64, mocks
    `file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end`) → flip to `.aiurconfig`.
  - `cli_test` cases passing `"WORKFLOW.md"` as the explicit path arg still work (explicit path
    honored regardless of name) — keep at least one arbitrary-name case to prove explicit override.
  - AE1: cwd has only a `WORKFLOW.md`, no `.aiurconfig` → resolution targets `.aiurconfig`,
    load errors with a message naming `.aiurconfig`; it does **not** read the `WORKFLOW.md`.

### U3: Convert operator + example + fixture files (verbatim relocation)
- **Goal:** every shipped `WORKFLOW*.md` → `.aiurconfig` + sibling prompt; content byte-identical
  (R9, R11).
- **Files (create the new pairs, delete the old `.md`):** the six rows in the naming table above.
  - `elixir/local-workflows/aiur.local.aiurconfig` + `aiur.local.prompt.md`
  - `elixir/local-workflows/actions.local.aiurconfig` + `actions.local.prompt.md`
  - three `elixir/examples/workflows/*.aiurconfig` + `*.prompt.md`
  - `elixir/test/fixtures/test.aiurconfig` (no prompt file)
- **Approach:** for each old file: split at the `---` fences; the front-matter block (between
  fences) becomes the `.aiurconfig` body; append `prompt_file: <sibling>.prompt.md`; the body
  (after the closing fence) becomes the sibling prompt file **verbatim** (preserve trailing
  newline; allow only trailing-whitespace normalization). The operator file
  (`WORKFLOW.aiur.local.md`) currently has uncommitted local edits — **convert from the working
  tree as-is** (the user has been editing it); do not revert.
- **Verbatim exception (R11 vs R13 collision):** the operator prompt body contains a line that
  itself names the file — `mix run -e ... fails in agent workspaces (no local WORKFLOW.md)`.
  Strict byte-for-byte relocation (R11) would carry that string into `aiur.local.prompt.md`,
  where it (a) is now factually wrong and (b) makes the success grep
  `grep -rn "WORKFLOW.md" elixir scripts` fail. **Resolution: this one line is updated to
  `.aiurconfig` as part of the relocation.** R11's "verbatim" intent is "do not rewrite the
  agent's instructions"; correcting a self-referential filename is not a content rewrite. Apply
  the same correction to any analogous self-reference in the example prompt bodies.
- **Verification:** `diff` old-body vs new prompt file shows only the WORKFLOW.md→.aiurconfig
  self-reference change (and trailing-whitespace normalization). `YamlElixir.read_from_string/1`
  on each `.aiurconfig` returns a map equal to the old front-matter map.
- **Note:** the operator `.aiurconfig` files contain machine-local data (IPs, home paths) and
  stay matched by `core_test`'s `machine_local_pattern` **exclusion** (only `examples/` are
  checked for portability — keep that distinction; see U4).

### U4: Repoint `core_test` workflow inventory + portability checks
- **Goal:** the checked-in-config tests target the new filenames and the new format.
- **Files:** Modify `elixir/test/aiur/core_test.exs`
- **Approach:**
  - "current WORKFLOW.md file is valid and complete" → point at
    `local-workflows/aiur.local.aiurconfig`; assert `prompt =~ "{{ issue.identifier }}"` still
    holds (prompt now comes via `prompt_file`). Rename the test ("current operator config ...").
  - "checked-in workflow examples parse" → wildcard `examples/workflows/*.aiurconfig` ++
    `local-workflows/*.local.aiurconfig`; assert `Schema.parse(config)` ok and the prompt
    (resolved via `prompt_file`) is non-empty.
  - "Codex GitHub workflows preserve ... handoff" → repoint the three paths; assertions on
    `prompt` unchanged (prompt now resolved through `prompt_file`).
  - Portability check stays scoped to `examples/workflows/*` (those prompt files +
    `.aiurconfig` must contain no machine-local pattern).
- **Format-specific tests that assert removed behavior (must be re-dispositioned — assign to U1
  or U4):** `core_test.exs` has tests that pin `WORKFLOW.md` front-matter semantics U1 deletes:
  - "workflow load accepts prompt-only files without front matter" (~line 233, writes
    `PROMPT_ONLY_WORKFLOW.md` = bare body, expects `prompt: "Prompt only"`) — **delete**;
    body-only is no longer a supported format.
  - "workflow load accepts unterminated front matter with an empty prompt" (~line 241) —
    **delete or replace** with a pure-YAML equivalent; there are no front-matter fences anymore.
  - "workflow load rejects non-map front matter" (~line 249) — **keep**, but change the input to
    a pure-YAML non-map (e.g. `- not-a-map`); already covered by U1's non-map test, so this may
    fold in.
  Make the disposition of each explicit; do not leave them to fail silently against new code.

### U5: Rewrite the test helper `write_workflow_file!`
- **Goal:** the shared helper emits pure-YAML `.aiurconfig`; a `prompt:` override emits a
  sibling prompt file + `prompt_file:` key.
- **Files:** Modify `elixir/test/support/test_support.exs`
- **Approach:** `workflow_content/1` drops the `---` fences and the trailing body. When
  `overrides[:prompt]` is set, write `<path>.prompt.md` next to the config and add
  `prompt_file: <basename>.prompt.md` to the YAML. Default (no `:prompt`) writes config-only.
  Keep the `overrides` surface (tracker_kind, codex_command, agent_kind, etc.) identical so
  dependent tests don't change call sites.
- **Dependent tests (verify green, adjust only if they assert removed behavior):**
  `core_test.exs`, `extensions_test.exs`, `cli_test.exs`, `coding_agent_test.exs`,
  `opencode/config_test.exs`, `dynamic_tool_test.exs`, `live_e2e_test.exs`.
- **Test scenarios:** the helper has no dedicated test; its correctness is proven by the
  dependent suites passing. Spot-check `extensions_test` "Third prompt"/"Second prompt" cases
  (they rely on `prompt:` override → must now produce a `prompt_file`-backed prompt) and the
  `THIRD_WORKFLOW.md` / `MANUAL_WORKFLOW.md` arbitrary-name cases (must load as pure YAML).

### U6: Repoint config + scripts (operator wiring)
- **Goal:** test env and operator launcher point at the converted files (R10).
- **Files:**
  - Modify: `elixir/config/config.exs` (lines ~26–36):
    `["../local-workflows/aiur.local.aiurconfig", "../test/fixtures/test.aiurconfig"]`.
  - Modify: `elixir/test/test_helper.exs` (lines ~26–37): same two paths.
  - Modify: `scripts/aiur` (lines 477–479): `add_profile` workflow args →
    `local-workflows/aiur.local.aiurconfig` (default+aiur) and
    `local-workflows/actions.local.aiurconfig` (actions). Update the help text at line ~405–410
    and the `WORKFLOW` column header (line 639) only if it reads cleaner; not required.
- **Test scenarios:** `scripts_aiur_test.exs` asserts the literal workflow paths in the launched
  command — update its expected strings to the new `.aiurconfig` names. `actions` profile in
  that test uses `WORKFLOW.actions.md` as an ad-hoc arg; update to `actions.local.aiurconfig`
  consistently.

### U7: `aiur init` stops treating `WORKFLOW.md` as legacy (R12)
- **Goal:** `existing_config_path/0` no longer checks for `WORKFLOW.md`.
- **Files:**
  - Modify: `elixir/lib/aiur/init.ex` — remove `@legacy_file_name "WORKFLOW.md"` (line 19) and
    the `WORKFLOW.md` branch in `existing_config_path/0` (lines ~519–525).
  - Test: `elixir/test/aiur/init_test.exs` (if it asserts the legacy guard — grep and adjust).
- **Approach:** the guard checks only `.aiurconfig`. `write_config/1` already writes
  `.aiurconfig`; unchanged.

### U8: Docs + moduledocs + operator-visible error strings (R13) + AGENTS.md staleness fix
- **Goal:** no doc, moduledoc, or operator-visible error/log string references `WORKFLOW.md` as
  the config file; the stale "generic template" layout line is corrected. The success-criteria
  grep (`grep -rn "WORKFLOW.md" elixir scripts`) must come back empty for `lib/` config-name
  references — so U8 must cover **all** of them, not a representative sample.
- **Full `lib/` inventory (verified via grep — 33 occurrences across 13 files):** most are
  carried by U1 (`workflow.ex` ×4), U2 (`cli.ex` ×3), and U7 (`init.ex` ×1). **The remaining
  operator-visible error/log strings U8 must convert:**
  - `elixir/lib/aiur/orchestrator.ex` (×8 — `Logger.error` strings: "Linear API token missing
    in WORKFLOW.md", "Missing WORKFLOW.md at ...", "Failed to parse WORKFLOW.md", etc.)
  - `elixir/lib/aiur/codex/config.ex` (×6), `elixir/lib/aiur/github/config.ex` (×2),
    `elixir/lib/aiur/linear/config.ex` (×2), `elixir/lib/aiur/opencode/config.ex` (×2),
    `elixir/lib/aiur/claude/config.ex` (×1) — `{:error, "... set X in WORKFLOW.md"}` tuples.
  - `elixir/lib/aiur/codex/dynamic_tool.ex` (×1), `elixir/lib/aiur/config.ex` (×1 moduledoc),
    `elixir/lib/aiur/workflow_store.ex` (×1), `elixir/lib/aiur/test_reset.ex` (×1).
  - Docs: root `AGENTS.md` (Layout line — see R9 reconciliation, it is stale), `elixir/README.md`.
- **Tests asserting those literals (must update in lockstep):** `dynamic_tool_test.exs:308`
  (`"Set ... in WORKFLOW.md"`) and any other test asserting an error string converted above —
  grep `WORKFLOW.md` in `elixir/test` after the source change and fix every assertion that breaks.
- **Approach:** mechanical find/replace of `WORKFLOW.md` → `.aiurconfig` inside error/log/doc
  strings. Leave the word "workflow" as the domain noun where it isn't naming the file. Run the
  success grep at the end of U8 and confirm zero config-name hits remain in `lib/` and `scripts/`.

## Dependencies / Sequencing

```
U1 (loader)  ──┬─→ U2 (cwd + errors)
               ├─→ U4 (core_test inventory)   ← needs U3 files to exist
               └─→ U5 (test helper)            ← needs U1 format
U3 (convert files) ──→ U4, U6
U6 (config/scripts) ← needs U3 files
U7 (init), U8 (docs) independent
```

Recommended order: **U1 → U3 → U2 → U5 → U4 → U6 → U7 → U8**, committing per unit (small 3–7
word messages, no AI footer).

**Test-run timing — do NOT expect green after U1 alone.** U1 changes the loader to pure-YAML
only, but the checked-in fixtures and test helper are still front-matter format until U3 and U5
land, so a full `mix test` after U1 *will* show failures (old fixtures vs new loader) — that is
expected, not a regression. Run the loader's own unit file in isolation after U1
(`mise exec -- mix test test/aiur/workflow_test.exs`), then run the full suite only after **U5**
(fixtures + helper converted) and a final full pass after **U6** (config/scripts repointed).

## Verification / Success Criteria (from origin)

- `grep -rn "WORKFLOW.md" elixir scripts` returns only converted/removed references; no code
  path reads or parses it as config.
- `mise exec -- mix compile` (warnings-as-errors), `mise exec -- mix test`, and the linter pass.
- Manual end-to-end (the goal's gate, tracked as task #63): move
  `local-workflows/aiur.local.aiurconfig`'s backing... — i.e. move the operator config to
  `.bak`, confirm aiur fails with the `.aiurconfig`/`aiur init` error; restore, confirm aiur
  boots and dispatches an agent using only `.aiurconfig` + its `prompt_file`.

## Deferred to Implementation

- Exact arity/signature of the `prompt_file` read helper inside `Aiur.Workflow` — implementer's
  call; the `{:error, {:missing_prompt_file, resolved, reason}}` shape and the no-basename-branch
  invariant are fixed.
- Whether to drop the `prompt_file` key from `config` before returning — leaving it is fine
  (Ecto ignores it); only drop it if a test asserts an exact config map equality and trips.
- Final wording of the CLI missing-config banner (must name `.aiurconfig` + `aiur init`).
- Whether `scripts/aiur` help text / column header rewording is worth the churn.
- **`prompt_file:` path-resolution policy (FYI from review).** `Path.expand(rel, dir)` will
  happily resolve an absolute path, `..` traversal, or a symlink. For operator-authored config
  this is benign (no external trust boundary), so the plan does **not** add a containment guard.
  If the implementer wants a pinned behavior, add one test asserting absolute/`..` inputs resolve
  as `Path.expand` yields — but this is optional, not a blocker.
- **`prompt_file` typo is a silent-default (FYI).** Because the schema ignores unknown keys, a
  misspelled `prmpt_file:` is swallowed and the agent silently runs the built-in default prompt
  (the `:missing_prompt_file` error only fires when the key is spelled right and the target is
  absent). Acceptable by design; noted so it isn't a debugging surprise.

## Pre-U3 Confirmation Required (raised by adversarial review)

The operator file `elixir/local-workflows/WORKFLOW.aiur.local.md` has **uncommitted working-tree
edits** (notably `agent.kind: codex` → `claude`, and a removed comment about branching
`after_create` off `kevin/e2e-pubsub-test` instead of `origin/main`). U3 says "convert from the
working tree as-is," which would freeze that transient local state into the new checked-in
`aiur.local.aiurconfig` inside the same PR that deletes the original — with no diff against the
committed baseline to show what changed. **Before executing U3, surface this diff to the operator
and confirm the working-tree state is the intended canonical content, not a local experiment.**
This is a content decision, not a mechanical relocation.
