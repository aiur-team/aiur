---
date: 2026-05-31
topic: aiurconfig-replaces-workflow
---

# `.aiurconfig` Replaces `WORKFLOW.md` as the Single Config File

## Problem Frame

aiur currently has two config formats. `WORKFLOW.md` carries YAML front-matter
(config) **plus** a Liquid prompt body (agent instructions). `.aiurconfig` (added
by `aiur init`, PR #238) is pure YAML config with **no** prompt body. The loader
(`elixir/lib/aiur/workflow.ex` `detect_run_folder_config/0`) prefers `.aiurconfig`
in cwd, then falls back to `WORKFLOW.md`, and `parse/2` branches its parsing on the
filename. This dual-format split is confusing: there are two files that can drive a
run, two parse paths, and the "where does config live" answer is "it depends."

The goal is one canonical format. `.aiurconfig` becomes **the** aiur config file
for every run — operator orchestration and per-run-folder alike. `WORKFLOW.md`
support is removed entirely (hard cutover). The one thing `WORKFLOW.md`'s body did
that pure YAML config does not — carry a custom agent prompt — moves to an optional
`prompt_file:` key pointing at a standalone markdown Liquid template.

This affects the operator (whose `scripts/aiur` profiles and test env point at
`elixir/local-workflows/WORKFLOW.aiur.local.md`), and any agent run that resolves
config from cwd. aiur's own `WORKFLOW.md` files are converted in the same change.

---

## Actors

- A1. Operator: runs `scripts/aiur` against `aiur-team/aiur`; owns the local
  orchestration config (currently `local-workflows/WORKFLOW.aiur.local.md`).
- A2. Coding agent: receives the rendered prompt per issue; behavior is driven by
  `prompts/shared-agent-instructions.md` (always prepended) plus the per-repo
  prompt template plus the complexity suffix.
- A3. New adopter: runs `aiur init` in their own repo to scaffold a `.aiurconfig`.

---

## Requirements

**Config format and loading**
- R1. `.aiurconfig` is the only config format aiur loads. The file is pure YAML.
- R2. WORKFLOW.md detection, the `WORKFLOW.md` filename fallback, and the
  front-matter (config + body) parse path are removed. Config parsing is always
  pure-YAML; it no longer branches on filename.
- R3. An explicitly configured config path (operator profiles, test env,
  `set_workflow_file_path/1`) is honored as today, but the file it points at must
  be `.aiurconfig`-format YAML regardless of its filename.
- R4. If no config file is found where one is expected, aiur fails with a clear
  error naming `.aiurconfig` and pointing at `aiur init` (no silent WORKFLOW.md
  search to fall back on).

**Prompt template relocation**
- R5. `.aiurconfig` supports an optional `prompt_file:` key: a path to a markdown
  Liquid template, resolved relative to the config file's directory.
- R6. When `prompt_file:` is present, its contents become the per-repo prompt
  template (the same Liquid template mechanism the WORKFLOW.md body used —
  `{{ issue.* }}`, `{% if %}`, etc.).
- R7. When `prompt_file:` is absent or empty, the prompt falls back to the
  built-in default template, exactly as the empty-body case does today
  (`PromptBuilder` → `Config.workflow_prompt/0`). The always-prepended
  `shared-agent-instructions.md` prefix and complexity suffix are unchanged.
- R8. A `prompt_file:` that points at a missing or unreadable file is a clear
  load error, not a silent fall-through to the default.

**Migration of aiur's own files**
- R9. Every `WORKFLOW*.md` file aiur ships is converted to `.aiurconfig` +
  (where it carried a custom body) a sibling prompt markdown referenced via
  `prompt_file:`. This includes the operator local-workflows file(s), the generic
  template at `elixir/WORKFLOW.md`, and the portable examples in
  `elixir/examples/workflows/`.
- R10. `scripts/aiur` profiles and the test config path
  (`elixir/config/config.exs`) are repointed at the converted `.aiurconfig` files.
- R11. The agent prompt **content** is preserved verbatim through the conversion —
  the operator's workpad template, repo setup notes, and issue interpolation move
  to the prompt file unchanged. This is a relocation, not a rewrite.

**Tooling and docs**
- R12. `aiur init` continues to write `.aiurconfig` and no longer treats
  `WORKFLOW.md` as a recognized/legacy config (its existing-config guard stops
  checking for `WORKFLOW.md`).
- R13. Repo docs that reference `WORKFLOW.md` as a config file (root `AGENTS.md`,
  `elixir/README.md`, in-code moduledocs) are updated to reference `.aiurconfig`.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R4.** Given a repo containing only a `WORKFLOW.md` and no
  `.aiurconfig`, when aiur resolves config from that cwd, it errors with a message
  naming `.aiurconfig` / `aiur init` — it does **not** load the `WORKFLOW.md`.
- AE2. **Covers R5, R6.** Given a `.aiurconfig` with `prompt_file: .aiur/prompt.md`
  and that file present, when an issue prompt is built, the rendered prompt is the
  `prompt.md` template with `{{ issue.* }}` interpolated, wrapped by the shared
  prefix and complexity suffix.
- AE3. **Covers R7.** Given a `.aiurconfig` with no `prompt_file:`, when an issue
  prompt is built, the rendered prompt uses the built-in default template (current
  empty-body behavior), with the shared prefix still prepended.
- AE4. **Covers R8.** Given a `.aiurconfig` whose `prompt_file:` points at a path
  that does not exist, when aiur loads config, it returns/raises a clear error
  identifying the missing prompt file.
- AE5. **Covers R9, R11.** Given the converted operator config, when an issue
  prompt is built, the workpad template and aiur setup notes appear identically to
  the pre-conversion WORKFLOW.aiur.local.md output.

---

## Success Criteria

- aiur runs end-to-end with **no** `WORKFLOW.md` present anywhere — the operator
  can move `WORKFLOW.aiur.local.md` to `.bak` and aiur starts and dispatches an
  agent using only `.aiurconfig` (+ its `prompt_file`).
- A grep for `WORKFLOW.md` as a config path returns only converted/removed
  references; no code path still reads or parses it.
- `mix test`, `mix compile` (warnings-as-errors if configured), and the linter all
  pass on the branch; CI is green.
- A downstream implementer/reviewer can see, from this doc plus the plan, exactly
  which files convert and that prompt content is preserved verbatim.

---

## Scope Boundaries

- No migration tool or auto-converter for external repos. Hard cutover; external
  adopters run `aiur init` (or hand-write `.aiurconfig`). This is acceptable
  because aiur is early and the operator owns all current real configs.
- No change to the agent prompt **content**, tracker/agent/routing **semantics**,
  or the schema's config keys (beyond adding `prompt_file:`).
- No change to `shared-agent-instructions.md` content or the complexity-suffix
  mechanism — those layers are untouched; only the per-repo body relocates.
- Not renaming the `Aiur.Workflow` module or the "workflow" domain vocabulary
  unless it falls out naturally; the deliverable is format unification, not a
  module-naming refactor. (Flagged for planning to decide.)

---

## Key Decisions

- **Optional `prompt_file:` key (not inline `prompt:` string, not prompt-less).**
  Keeps `.aiurconfig` clean pure-YAML while preserving an editable markdown Liquid
  prompt and per-repo customization. Avoids embedding a ~100-line block scalar in
  YAML, and avoids losing per-repo prompt customization.
- **Hard cutover — remove WORKFLOW.md parsing entirely.** One format, one parse
  path, one mental model. aiur is the only real consumer today and all its files
  convert in the same PR, so the breakage surface is internal and fully addressed
  here.
- **Prompt content is relocated verbatim.** Conversion must not alter agent
  behavior; the existing operator body moves to a prompt file byte-for-byte
  (modulo trailing-whitespace normalization).

---

## Dependencies / Assumptions

- `prompts/shared-agent-instructions.md` already carries the generic agent
  guidance (alerts, ce-loop, workpad references, complexity routing); the per-repo
  body is mostly repo-specific setup + the workpad template + issue interpolation.
  (Verified in code, 2026-05-31.)
- `PromptBuilder` + `Config.workflow_prompt/0` already fall back to a built-in
  default template when the prompt body is empty. (Verified in code.)
- The config schema (`Aiur.Config.Schema`) must accept the new `prompt_file:` key
  without rejecting it — planning to confirm whether the schema is strict.
- Agent workspaces run `mix run` from a checkout that must contain a loadable
  config in cwd; `elixir/WORKFLOW.md` is that file today, so `elixir/.aiurconfig`
  must exist after conversion or the app fails to boot there. (Planning to confirm
  the exact cwd/config expectation.)

---

## Outstanding Questions

### Deferred to Planning

- [Affects R3][Technical] With front-matter parsing removed, does the loader key
  purely on "is this valid `.aiurconfig` YAML" regardless of basename, so operator
  profile files can keep arbitrary names? Confirm and pick the operator file
  naming convention (e.g. `aiur.local.aiurconfig`).
- [Affects R5, R8][Technical] Exact `prompt_file:` path resolution semantics
  (relative to config dir vs cwd) and error shape for missing files.
- [Affects R9][Technical] Full inventory of `WORKFLOW*.md` files and test fixtures
  (e.g. `test/fixtures/test_workflow.md`) that must convert, and the blast radius
  across the ~30 test files referencing `WORKFLOW`.
- [Affects R2][Technical] Whether `Aiur.Workflow` / `Config` moduledocs and any
  "WORKFLOW.md" naming should be renamed, or left as-is to keep the diff focused.

---

## Next Steps

-> /ce-plan for structured implementation planning
