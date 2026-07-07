# T-021: Unify $VAR resolution + codex validator dedup

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:2`

## Problem / context

Three config duplications (clusters 6–8 in
`docs/refactor/research-arch/dup-backends.md`) each force the same change to be
made in two places or the copies drift:

1. The `$VAR` env-reference resolution grammar (config value wins; `$NAME`
   resolves the env var; missing var → fallback env; **var set to empty string
   → nil, i.e. missing** — FI-TRK-002; blank strings normalize to nil) is
   implemented twice: `src/lib/aiur/config/schema.ex:918-982`
   (`resolve_secret_setting`/`resolve_env_value`/`env_reference_name`/`normalize_secret_value`,
   run at parse time by `finalize_settings/1`, schema.ex:834-847) and
   `src/lib/aiur/linear/config.ex:66-103` (near line-for-line identical). Worse,
   it is *applied* twice: `Aiur.Linear.Config.api_key/0` and `assignee/0` re-run
   the resolution over the already-resolved value they read back from
   `settings!()`. Any grammar change must be mirrored, and a resolved secret
   that legitimately starts with `$` would be mangled by the second pass.
2. The codex `approval_policy` enum (`untrusted on-failure on-request granular
   never`) and its trim-then-membership validator exist in
   `src/lib/aiur/config.ex:24` + `src/lib/aiur/config.ex:405-413`
   (`validate_codex_approval_policy/1`) AND in
   `src/lib/aiur/codex/config.ex:14-15` + `src/lib/aiur/codex/config.ex:72-86`
   (`validate_approval_policy/1`). FI-CFG-060 flags the sync requirement;
   updating one list but not the other yields a boot-vs-runtime split-brain.
   Security-relevant: only `"never"` flips auto-approval.
3. The codex default sandbox-policy map (the agent's blast-radius contract,
   FI-CFG-064 / FI-CDX-046) is duplicated byte-for-byte:
   `src/lib/aiur/config/codex_sandbox_policy.ex:36-45` (`default_policy/1`,
   currently private) and `src/lib/aiur/codex/config.ex:104-120`
   (`default_turn_sandbox_policy/1`, the `rescue ArgumentError` fallback).
   Tightening the canonical policy without the fallback copy silently runs
   agents under a different sandbox on exactly the least-tested path.

This ticket makes `Aiur.Config.EnvRef` the single `$VAR` implementation (Schema
uses it; `Aiur.Linear.Config` stops resolving), makes `Aiur.Codex.Config` the
single home of the approval-policy enum, and makes
`Aiur.Config.CodexSandboxPolicy.default_policy/1` the single home of the default
sandbox map. Behavior is identical, including the
$VAR-resolving-to-empty-is-missing rule.

## Scope (exact)

1. Create `src/lib/aiur/config/env_ref.ex` with EXACTLY this content (module
   name `Aiur.Config.EnvRef` is binding per dup-backends.md Cluster 6):

   ```elixir
   defmodule Aiur.Config.EnvRef do
     @moduledoc """
     Single home for the `$VAR` env-reference resolution grammar used by
     config secrets (`tracker.linear.api_key` / `tracker.linear.assignee`)
     and paths (`workspace.root`).

     Grammar: a config value of exactly `$NAME` (where NAME matches
     `^[A-Za-z_][A-Za-z0-9_]*$`) resolves to the env var NAME; a missing var
     falls back to the caller-supplied fallback; a var set to the empty
     string resolves to nil (empty-var-is-missing). Any other value is a
     literal — legacy `env:NAME` values are NOT references and pass through
     unchanged.
     """

     @env_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

     @doc """
     Resolves a secret config value against the `$VAR` grammar.

     A nil `value` resolves to the normalized `fallback`; a `$NAME`
     reference resolves to the env var (missing var → normalized `fallback`,
     empty var → nil); any other binary is a literal. Binary results are
     normalized so `""` becomes nil.
     """
     @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
     def resolve(nil, fallback), do: empty_to_nil(fallback)

     def resolve(value, fallback) when is_binary(value) do
       case resolve_env_value(value, fallback) do
         resolved when is_binary(resolved) -> empty_to_nil(resolved)
         resolved -> resolved
       end
     end

     @doc """
     Returns `{:ok, name}` when `value` is a `$NAME` env reference, `:error`
     otherwise (including legacy `env:NAME` values, which stay literal).
     """
     @spec reference_name(term()) :: {:ok, String.t()} | :error
     def reference_name("$" <> env_name) do
       if String.match?(env_name, @env_name_pattern) do
         {:ok, env_name}
       else
         :error
       end
     end

     def reference_name(_value), do: :error

     @doc """
     Trims a binary secret; blank (or non-binary) values become nil.
     """
     @spec normalize_secret(term()) :: String.t() | nil
     def normalize_secret(value) when is_binary(value) do
       case String.trim(value) do
         "" -> nil
         trimmed -> trimmed
       end
     end

     def normalize_secret(_value), do: nil

     defp resolve_env_value(value, fallback) do
       case reference_name(value) do
         {:ok, env_name} ->
           case System.get_env(env_name) do
             nil -> fallback
             "" -> nil
             env_value -> env_value
           end

         :error ->
           value
       end
     end

     defp empty_to_nil(value) when is_binary(value) do
       if value == "", do: nil, else: value
     end

     defp empty_to_nil(_value), do: nil
   end
   ```

2. Modify `src/lib/aiur/config/schema.ex`:
   - After the existing `alias Aiur.Config.CodexSandboxPolicy` (line 8), add:
     `alias Aiur.Config.EnvRef`
   - In `finalize_settings/1` (lines 834-847), replace the two
     `resolve_secret_setting(` calls with `EnvRef.resolve(` (same arguments,
     unchanged: `settings.tracker.linear.api_key` /
     `System.get_env("LINEAR_API_KEY")` and `settings.tracker.linear.assignee`
     / `System.get_env("LINEAR_ASSIGNEE")`).
   - In `normalize_path_token/1` (lines 954-959), replace the call
     `env_reference_name(value)` with `EnvRef.reference_name(value)`.
   - Delete these private functions entirely: `resolve_secret_setting/2` (both
     clauses, lines 918-925), `resolve_env_value/2` (lines 940-952),
     `env_reference_name/1` (both clauses, lines 961-969), and
     `normalize_secret_value/1` (both clauses, lines 978-982).
   - Keep `resolve_path_value/2` (lines 927-938), `normalize_path_token/1`,
     and `resolve_env_token/1` (lines 971-976) in schema.ex — only the
     reference-detection call inside `normalize_path_token/1` changes.

3. Modify `src/lib/aiur/linear/config.ex`:
   - Replace the body of `api_key/0` (lines 18-23) so the function reads
     exactly:

     ```elixir
     @spec api_key() :: String.t() | nil
     def api_key do
       Aiur.Config.EnvRef.normalize_secret(section_value("api_key"))
     end
     ```

   - Replace the body of `assignee/0` (lines 39-44) so the function reads
     exactly:

     ```elixir
     @spec assignee() :: String.t() | nil
     def assignee do
       Aiur.Config.EnvRef.normalize_secret(section_value("assignee"))
     end
     ```

   - Delete these private functions entirely: `resolve_env_value/2` (all three
     clauses, lines 66-84), `env_reference_name/1` (both clauses, lines
     86-94), and `normalize_secret/1` (both clauses, lines 96-103).
   - Do NOT touch `endpoint/0`, `project_slug/0`, `validate!/0`, or
     `section_value/1`.

4. Modify `src/lib/aiur/config.ex`:
   - Delete line 24: `@valid_codex_approval_policies ~w(untrusted on-failure on-request granular never)`.
   - Replace the two `validate_codex_approval_policy/1` clauses (lines
     405-413) with exactly this single clause, which delegates to the one
     canonical validator while preserving this module's error-tuple shape
     (FI-CFG-060):

     ```elixir
     defp validate_codex_approval_policy(value) do
       case Aiur.Codex.Config.validate_approval_policy(value) do
         {:ok, trimmed} -> {:ok, trimmed}
         {:error, _message} -> {:error, {:invalid_codex_approval_policy, value}}
       end
     end
     ```

   - Make no other change to this file. `codex_runtime_settings/2` (lines
     387-403) keeps calling `validate_codex_approval_policy/1` unchanged.

5. Modify `src/lib/aiur/codex/config.ex`:
   - Immediately after the public `validate_approval_policy/1` clauses (after
     line 81, before `defp invalid_approval_policy`), add:

     ```elixir
     @doc false
     @spec valid_policies() :: [String.t()]
     def valid_policies, do: @valid_approval_policies
     ```

   - Rewrite `default_turn_sandbox_policy/1` (lines 104-120) so it reads
     exactly (the `writable_root` computation is unchanged; only the inline
     map literal is replaced by the canonical resolver call):

     ```elixir
     defp default_turn_sandbox_policy(workspace) do
       writable_root =
         if is_binary(workspace) and String.trim(workspace) != "" do
           Path.expand(workspace)
         else
           Path.expand(Aiur.Config.workspace_root())
         end

       Aiur.Config.CodexSandboxPolicy.default_policy(writable_root)
     end
     ```

   - Keep `@valid_approval_policies`, `@default_approval_policy`,
     `validate_approval_policy/1`, `invalid_approval_policy/1`,
     `resolve_approval_policy/0`, `resolve_thread_sandbox/0`, and
     `section_value/1` otherwise unchanged.

6. Modify `src/lib/aiur/config/codex_sandbox_policy.ex`:
   - Change `defp default_policy(workspace) do` (line 36) to a public
     function with a spec, keeping the body and position in the file
     unchanged:

     ```elixir
     @spec default_policy(Path.t()) :: map()
     def default_policy(workspace) do
     ```

   - No other change in this file.

7. Create `src/test/aiur/config/env_ref_test.exs` with EXACTLY this content:

   ```elixir
   defmodule Aiur.Config.EnvRefTest do
     use ExUnit.Case, async: false

     alias Aiur.Config.EnvRef

     @env_var "AIUR_ENV_REF_TEST_VAR"

     setup do
       System.delete_env(@env_var)
       on_exit(fn -> System.delete_env(@env_var) end)
       :ok
     end

     describe "resolve/2" do
       test "nil value resolves to the fallback" do
         assert EnvRef.resolve(nil, "fallback-secret") == "fallback-secret"
       end

       test "nil value with blank or nil fallback resolves to nil" do
         assert EnvRef.resolve(nil, "") == nil
         assert EnvRef.resolve(nil, nil) == nil
       end

       test "$VAR resolves the referenced env var" do
         System.put_env(@env_var, "from-env")
         assert EnvRef.resolve("$#{@env_var}", "fallback") == "from-env"
       end

       test "$VAR with the var missing falls back" do
         assert EnvRef.resolve("$#{@env_var}", "fallback") == "fallback"
       end

       test "$VAR with the var set to empty string is missing, not fallback" do
         System.put_env(@env_var, "")
         assert EnvRef.resolve("$#{@env_var}", "fallback") == nil
       end

       test "non-reference values pass through as literals" do
         assert EnvRef.resolve("literal-secret", "fallback") == "literal-secret"
       end

       test "empty literal normalizes to nil" do
         assert EnvRef.resolve("", "fallback") == nil
       end

       test "legacy env: references stay literal" do
         assert EnvRef.resolve("env:#{@env_var}", "fallback") == "env:#{@env_var}"
       end

       test "$ followed by an invalid identifier stays literal" do
         assert EnvRef.resolve("$not-a-var", "fallback") == "$not-a-var"
       end
     end

     describe "reference_name/1" do
       test "valid identifiers after $ are references" do
         assert EnvRef.reference_name("$MY_VAR") == {:ok, "MY_VAR"}
         assert EnvRef.reference_name("$_private1") == {:ok, "_private1"}
       end

       test "invalid identifiers and non-references are :error" do
         assert EnvRef.reference_name("$1BAD") == :error
         assert EnvRef.reference_name("$has-dash") == :error
         assert EnvRef.reference_name("plain") == :error
         assert EnvRef.reference_name(nil) == :error
       end
     end

     describe "normalize_secret/1" do
       test "trims binaries and blanks become nil" do
         assert EnvRef.normalize_secret("  token  ") == "token"
         assert EnvRef.normalize_secret("   ") == nil
         assert EnvRef.normalize_secret("") == nil
       end

       test "non-binaries become nil" do
         assert EnvRef.normalize_secret(nil) == nil
         assert EnvRef.normalize_secret(123) == nil
       end
     end
   end
   ```

8. Run the Agent gate (below). Do not add `Aiur.Config.EnvRef` to the
   `ignore_modules` list in `src/mix.exs` — the coverage threshold must apply
   to it.

## Files

- Create: `src/lib/aiur/config/env_ref.ex`,
  `src/test/aiur/config/env_ref_test.exs`
- Modify: `src/lib/aiur/config/schema.ex`, `src/lib/aiur/linear/config.ex`,
  `src/lib/aiur/config.ex`, `src/lib/aiur/codex/config.ex`,
  `src/lib/aiur/config/codex_sandbox_policy.ex`
- Test: `src/test/aiur/config/env_ref_test.exs`

## Out of scope

- Cluster 5 (dup-backends.md) "section accessor" dedup: do NOT touch
  `section_value`/trim helpers in `src/lib/aiur/github/config.ex`,
  `src/lib/aiur/opencode/config.ex`, `src/lib/aiur/claude/config.ex`, and do
  NOT change `section_value/1` in the two config modules this ticket edits.
  `normalize_secret/1` in `src/lib/aiur/github/config.ex` stays as-is (it is a
  cluster-5 copy, not this ticket's).
- `Aiur.Linear.Config.endpoint/0`, `project_slug/0`, `validate!/0` bodies.
- Any grammar extension: `${VAR}` syntax, or resolving legacy `env:NAME`
  references (FI-CFG-029 requires `env:` values to stay literal).
- `resolve_path_value/2`, `normalize_path_token/1`, `resolve_env_token/1` in
  schema.ex — they stay in schema.ex; only the one call named in Scope step 2
  changes.
- `Aiur.Config.CodexSandboxPolicy.resolve/3` and `resolve_runtime/4` logic,
  and the danger-full-access promotion (FI-CFG-061) in schema.ex.
- codex `thread_sandbox` validation, the `StringOrMap` Ecto type, schema field
  defaults, and `codex_runtime_settings/2`'s success/error shapes.
- `src/mix.exs` (no `ignore_modules` or coverage changes).
- All existing test files — modify none; the only test file in this ticket is
  the new `env_ref_test.exs`.

## Inventory-IDs

From `docs/refactor/feature-inventory/trk.md`:

- **FI-TRK-002** — Linear configuration resolution and validation (the primary
  entry: names this exact duplication and the
  $VAR-resolving-to-empty-is-missing rule).

From `docs/refactor/feature-inventory/cfg.md`:

- **FI-CFG-003** — Schema.parse pipeline (finalize_settings env resolution).
- **FI-CFG-025** — tracker.linear.api_key with env fallback resolution.
- **FI-CFG-029** — legacy `env:` references are NOT resolved (kept literal).
- **FI-CFG-035** — workspace.root $VAR resolution (shares the
  `^[A-Za-z_][A-Za-z0-9_]*$` reference grammar now owned by EnvRef).
- **FI-CFG-060** — agent.codex.approval_policy two-stage validation (names the
  duplicate validator this ticket removes).
- **FI-CFG-063** — Config.codex_runtime_settings composite (its validator call
  now delegates).
- **FI-CFG-064** — codex sandbox default policy shape (single home after this
  ticket).

Adjacent, from `docs/refactor/feature-inventory/cdx.md` (this ticket modifies
`src/lib/aiur/codex/config.ex`): **FI-CDX-045** (approval-policy enum
validation, fail-closed default), **FI-CDX-046** (thread_sandbox + turn
sandbox policy defaults, including the rescue fallback path).

## Characterization-tests

No Phase-1 characterization ticket (T-006..T-013) targets the config
schema/tracker-config area directly; the nearest is T-010 (workspace lifecycle
& git metadata — `workspace.root` feeds sandbox writable roots, FI-CFG-035).
The ENTIRE suite under `src/test/aiur/regression/` — every file present at
execution time, including everything T-007..T-013 added in Phase 1 — must pass
UNMODIFIED.

The binding behavioral protection for this ticket is the existing unit suite,
which must also pass unmodified (these files are cited by the FI entries
above):

- `src/test/aiur/core_test.exs` (env-fallback resolution 217-248; approval
  policy 120-134)
- `src/test/aiur/workspace_and_config_test.exs` ($VAR/env literal handling
  1767-1822; secret resolution 2211-2255; sandbox default/augmentation
  2257-2556)
- `src/test/aiur/codex/config_test.exs` (validate_approval_policy/1 contract)
- `src/test/aiur/app_server_test.exs` (sandbox policy augmentation, line 79)

## Acceptance criteria

All commands run from the repo root unless noted.

- `test -f src/lib/aiur/config/env_ref.ex` and
  `grep -n "defmodule Aiur.Config.EnvRef" src/lib/aiur/config/env_ref.ex`
  matches.
- `grep -c "" src/lib/aiur/config/env_ref.ex` <= 200 (expected ~95); every
  function in it <= 20 logic lines (guaranteed by copying Scope step 1
  verbatim).
- `test -f src/test/aiur/config/env_ref_test.exs`.
- `grep -rn "resolve_secret_setting\|normalize_secret_value" src/lib` → no
  output (Schema's private resolver is gone).
- `grep -rn "env_reference_name" src/lib` → no output (both private copies
  deleted; the public name is `reference_name/1`).
- `grep -rl "resolve_env_value" src/lib` → exactly one line:
  `src/lib/aiur/config/env_ref.ex`.
- `grep -rlF '[A-Za-z_][A-Za-z0-9_]*$' src/lib` → exactly one line:
  `src/lib/aiur/config/env_ref.ex` (the reference-identifier regex has one
  home).
- `grep -n "defp normalize_secret\|defp resolve_env_value\|defp env_reference_name" src/lib/aiur/linear/config.ex`
  → no output.
- `grep -n "@valid_codex_approval_policies" src/lib/aiur/config.ex` → no
  output.
- `grep -rn "on-failure on-request granular never" src/lib` → exactly one
  match, in `src/lib/aiur/codex/config.ex` (the enum list has one home).
- `grep -n "Aiur.Codex.Config.validate_approval_policy" src/lib/aiur/config.ex`
  → exactly one match (the delegating clause).
- `grep -n "def valid_policies" src/lib/aiur/codex/config.ex` → exactly one
  match.
- `grep -n "workspaceWrite\|writableRoots\|excludeSlashTmp" src/lib/aiur/codex/config.ex`
  → no output (the duplicate sandbox map is gone).
- `grep -rl "excludeSlashTmp" src/lib` → exactly one line:
  `src/lib/aiur/config/codex_sandbox_policy.ex`.
- `grep -n "def default_policy" src/lib/aiur/config/codex_sandbox_policy.ex` →
  exactly one match, and
  `grep -n "defp default_policy" src/lib/aiur/config/codex_sandbox_policy.ex`
  → no output.
- Parent file line counts reduced: `grep -c "" src/lib/aiur/config/schema.ex`
  < 990 (from 1017); `grep -c "" src/lib/aiur/linear/config.ex` < 80 (from
  104); `grep -c "" src/lib/aiur/config.ex` < 540 (from 540);
  `grep -c "" src/lib/aiur/codex/config.ex` < 127 (from 127).
- `grep -n "EnvRef" src/mix.exs` → no output (the new module is NOT in
  `ignore_modules`; the 85% coverage threshold enforces its tests).
- `cd src && mix test test/aiur/config/env_ref_test.exs` → all pass.
- `git diff --name-only origin/v2...HEAD` lists exactly the seven files in
  Files (2 created + 5 modified) — nothing under `src/test/aiur/regression/`,
  and none of the four existing test files named in Characterization-tests.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

All probes run from `src/`.

- Check (FI-TRK-002, missing var → fallback):
  `unset T021_PROBE; mix run --no-start -e 'IO.inspect(Aiur.Config.EnvRef.resolve("$T021_PROBE", "fb"))'`
  prints `"fb"`.
- Check (FI-TRK-002, empty-var-is-missing):
  `T021_PROBE= mix run --no-start -e 'IO.inspect(Aiur.Config.EnvRef.resolve("$T021_PROBE", "fb"))'`
  prints `nil` (NOT `"fb"`).
- Check (set var wins):
  `T021_PROBE=live mix run --no-start -e 'IO.inspect(Aiur.Config.EnvRef.resolve("$T021_PROBE", "fb"))'`
  prints `"live"`.
- Check (FI-CFG-029, `env:` stays literal):
  `mix run --no-start -e 'IO.inspect(Aiur.Config.EnvRef.resolve("env:HOME", "fb"))'`
  prints `"env:HOME"`.
- Check (FI-CFG-060 / FI-CDX-045, single validator):
  `mix run --no-start -e 'IO.inspect(Aiur.Codex.Config.validate_approval_policy("  never  "))'`
  prints `{:ok, "never"}`, and the same call with `"banana"` prints
  `{:error, "Invalid codex.approval_policy \"banana\" — must be one of: untrusted, on-failure, on-request, granular, never"}`.
- Check (FI-CFG-064, canonical default map):
  `mix run --no-start -e 'IO.inspect(Aiur.Config.CodexSandboxPolicy.default_policy("/tmp/w"))'`
  prints a map with exactly `"type" => "workspaceWrite"`,
  `"writableRoots" => ["/tmp/w"]`, `"readOnlyAccess" => %{"type" => "fullAccess"}`,
  `"networkAccess" => false`, `"excludeTmpdirEnvVar" => false`,
  `"excludeSlashTmp" => false`.
- Behavior spot-check:
  `mix test test/aiur/core_test.exs test/aiur/workspace_and_config_test.exs test/aiur/codex/config_test.exs test/aiur/app_server_test.exs`
  green, and the PR diff shows all four files unmodified.
- Check: PR diff contains no changes under `src/test/aiur/regression/` and no
  change to `src/mix.exs`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
