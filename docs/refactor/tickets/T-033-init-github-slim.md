# T-033: init wave 3: Codeowners, Labels, GitHub, AgentCli, Dotenv; slim

**Phase:** 3
**Depends-on:** T-032
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/init.ex` is the `aiur init` scaffold wizard and a recurring
regression hotspot (init & config scaffolding, ~14 incidents —
`docs/refactor/research-history-hotspots.md` row 7; the never-clobber and label
staging surfaces are #649/#724/#702). The decomposition contract is
`docs/refactor/research-arch/giant-init.md` §2 (the NAME MAP — binding) and §4
(semantics that must be preserved verbatim). T-031 already extracted
`Aiur.Init.Runtime`, `Aiur.Init.Format`, `Aiur.Init.Questions`,
`Aiur.Init.Resume`, and `Aiur.Init.Templates`; T-032 already extracted
`Aiur.Init.Scaffold`, `Aiur.Init.Migration`, `Aiur.Init.Prewarm`,
`Aiur.Init.Prewarm.Failure`, and `Aiur.Init.Alerts`.

This ticket is the **FINAL init wave**: extract the five remaining concerns into
`Aiur.Init.Codeowners` (plus one cross-namespace move, `Aiur.Codeowners.Edit`),
`Aiur.Init.Labels`, `Aiur.Init.GitHub`, `Aiur.Init.AgentCli`, and
`Aiur.Init.Dotenv`, then slim `Aiur.Init` to the wizard-orchestration facade
(entry flow + stable public facade delegates). **Slimmed line ceiling:
`src/lib/aiur/init.ex` must be `<= 245` lines after this ticket** (research
target ~220).

Hard extraction rules for this whole ticket (no exceptions):

- Move code **verbatim** — extract, do not rewrite. Function bodies, guards,
  pattern-match clauses, comments, and every operator-facing string
  (`io.puts` text, faint-ANSI formatting, label padding, "Created:"/"Found:"
  prefixes, the token/label instruction screens, the `gh label create`
  fallback) move byte-for-byte. The ONLY permitted edits are: the module
  wrapper, `alias`/`require` lines, `defp` → `def` where a function becomes
  cross-module API, the **four renames** named below (all in
  `Aiur.Codeowners.Edit`), copying the small module attributes each moved
  function references, and qualifying calls with the new module names.
- Public function signatures and observable behavior of `Aiur.Init` are
  unchanged. The only external lib caller (`src/lib/aiur/cli.ex:49`,
  `Aiur.Init.run/1`) and every test that drives `Aiur.Init.run/3` or the public
  facade are NOT edited.
- The parent module and its siblings delegate to the extracted modules so all
  existing callers keep working.
- Every extracted module gets a `@moduledoc`, an `@spec` on every public `def`,
  and its own test file. **New modules are NOT coverage-exempt** — do NOT touch
  `ignore_modules` or the `threshold` in `src/mix.exs` (that file is not in
  Files). Note: `test_coverage.summary.threshold` is a repo-wide **aggregate**
  85% (`src/mix.exs:11-19`), not per-module; a verbatim move of
  already-counted lines keeps the aggregate intact, and the directed tests
  below add margin.
- After every step below, the repo compiles and the full suite passes
  (`mix compile --warnings-as-errors` + `mix test` from `src/`). After the final
  step, the full Agent gate passes.

Semantics that must be preserved **verbatim** (from giant-init.md §4 — this
file's regressions are semantic, not structural):

1. **Label staging semantics (§4.5).** Existing labels are fetched once
   (`fetch_existing_labels`; a read error is treated as "all missing" because
   creation is idempotent); each stage computes `labels -- existing`; the
   lifecycle stage is Enter-gated (`io.input.("Press Enter to create them", ...)`);
   optional stages are confirm-gated with their EXACT defaults (complexity
   `true`, model `true`, remote `false`); a `create_labels` failure prints the
   `gh` fallback and returns `:error`, which withholds the ready screen. The
   remote stage exists only when `Aiur.GitHub.Labels.alias_labels(kinds)` is
   non-empty.
2. **Exact operator-facing text (§4.6).** Dozens of tests assert `io.puts`
   output by substring, including label-column padding
   (`String.pad_trailing`), the faint `label_status_line` "created." form, and
   the `gh label create ... --force` fallback line. Moved text must be
   byte-identical.
3. **CODEOWNERS trust semantics (§4).** `normalize_login/1` stays the single
   normalizer (trim → strip leading `@` → downcase → `nil` on empty);
   duplicate detection is case-insensitive, `@`-tolerant, comment-aware;
   `content_with_login/2` appends to the LAST `*` wildcard rule (before an
   inline `#` comment) or writes a new `* @login` rule; a wrong append changes
   who can drive agents from comments, so the tokenizers move byte-for-byte.
   `Aiur.Codeowners.Edit` only **moves** the init implementation next to the
   existing parser (`src/lib/aiur/codeowners.ex`) — do NOT merge it with
   `Aiur.Codeowners.parse_line`/`line_tokens` (that is a flagged follow-up, not
   this wave).
4. **Agent-CLI check filtering (§4.7).** `check_agent_clis/3` must keep
   filtering agents to the `@routing_order` (`["claude", "codex"]`) allowlist so
   `claude-repl` never gets an auth check; claude's missing-CLI path installs
   `aiur-claude` before warning, degrading to a manual-install hint on failure.
5. **`.env` load is existing-env-wins, runtime-path only (§4.4).**
   `Aiur.Init.Dotenv.load/0` mutates `System.put_env` only-if-unset and is
   called ONLY from `run/1` (never `run/3`); `parse/1` never inspects or logs
   values. Do not move the `System.put_env` mutation onto the injected-`deps`
   path.

Line ranges below cite `src/lib/aiur/init.ex` as of ticket authoring (2254
lines, pre-T-031/T-032). After T-031 and T-032 merge the absolute numbers shift
and the intervening extracted functions are gone, but neither prior wave renames
or rewrites any function listed here — locate each function by name and move its
then-current body.

## Scope (exact)

1. **Preflight (do not skip).** Verify T-031 and T-032 landed on your branch
   base and `mix test` is green there. Confirm these files exist and contain the
   named definitions; if any check fails, STOP and comment the blocker on the
   issue instead of proceeding:
   - `src/lib/aiur/init/format.ex` defines `Aiur.Init.Format` with
     `def print_hint(` and `def dim(` (this ticket's Labels/Codeowners modules
     call `Aiur.Init.Format.print_hint/2` and `Aiur.Init.Format.dim/1`; if
     `print_hint`/`dim` are still in `src/lib/aiur/init.ex` instead, T-031
     deviated from the name map — STOP and comment).
   - `src/lib/aiur/init/runtime.ex` defines `Aiur.Init.Runtime` and contains the
     runtime `deps` map with the keys `detect_repo:`, `github_login:`,
     `list_labels:`, `create_labels:`, `check_agent_auth:`, and
     `install_claude_app_server:` (this ticket repoints those six values). If
     the `deps` map is not in `runtime.ex`, STOP and comment.
   - `src/lib/aiur/init/resume.ex` defines `Aiur.Init.Resume`. Grep it for
     `setup_codeowners(` — you will repoint that call in step 7 iff it is
     present.

2. **Step 1 (commit 1): create `Aiur.Codeowners.Edit` and `Aiur.Init.Codeowners`.**
   - `src/lib/aiur/codeowners/edit.ex` — module `Aiur.Codeowners.Edit`,
     `@moduledoc` stating it is the pure CODEOWNERS content-editing companion to
     the `Aiur.Codeowners` parser (one source of truth for CODEOWNERS format
     facts). Move verbatim from `init.ex`, applying the four renames:
     - `add_codeowners_login/2` (lines 1260–1274) → **`add_login/2`** (rename
       #1), public `def` with `@spec`; keep the `with`/`else` body byte-for-byte
       except the internal calls now resolve within `Edit`.
     - `write_codeowners_login/3` (lines 1276–1281) — private (`defp`),
       unchanged name.
     - `codeowners_content_has_login?/2` (lines 1283–1290) → **`has_login?/2`**
       (rename #2), public `def` with `@spec`.
     - `codeowner_tokens/1` (lines 1292–1300) — private.
     - `content_with_codeowner/2` (lines 1302–1313) → **`content_with_login/2`**
       (rename #3), public `def` with `@spec`.
     - `wildcard_rule_index/1` (1315–1326), `wildcard_rule?/1` (1328–1333),
       `codeowner_rule_tokens/1` (1335–1343), `append_login_to_rule/2`
       (1345–1350), `append_codeowner_rule/2` (1352–1355) — all private.
     - `normalize_login/1` — both clauses (1357–1368) → keep the name
       **`normalize_login/1`** but make it a public `def` with `@spec` (rename
       #4 is "make public"; `Aiur.Init.Codeowners` and `Aiur.Init.GitHub` both
       call it).
     - Update `add_login/2`'s internal references so they call the same-module
       functions (`normalize_login`, `has_login?`, `write_codeowners_login`,
       `content_with_login`).
   - `src/lib/aiur/init/codeowners.ex` — module `Aiur.Init.Codeowners`,
     `@moduledoc`. `alias Aiur.Codeowners`, `alias Aiur.Codeowners.Edit`,
     `alias Aiur.Init.Format`. Move verbatim:
     - `setup_codeowners/3` — both clauses (lines 1148–1157 and 1157) → public
       `def setup_codeowners(io, deps, tracker)` with `@spec`.
     - `maybe_create_codeowners/3` — both clauses (1159–1178) — private; the
       `dim(...)` calls become `Format.dim(...)`.
     - `explain_codeowners_trust/1` (1180–1186) — private.
     - `create_codeowners_file/1` (1188–1206) — private (keep the exact heredoc
       comment body written to the file).
     - `maybe_add_operator_codeowner/4` — both clauses (1208–1219) — private;
       `normalize_login(...)` becomes `Edit.normalize_login(...)`.
     - `prompt_and_add_operator_codeowner/4` (1221–1233) — private.
     - `prompt_github_login/2` (1235–1242) — private; the trailing
       `normalize_login()` pipe becomes `Edit.normalize_login()`.
     - `codeowners_has_login?/2` (1244–1246) — private; keeps calling
       `Codeowners.repo_ownership(repo_root: repo_root).owners`.
     - `offer_operator_codeowner/3` (1248–1258) — private; `add_codeowners_login`
       becomes `Edit.add_login`, `dim` becomes `Format.dim`, matching the
       `{:updated, _}` / `{:exists, _}` / `{:error, _}` return shapes unchanged.
   - New tests: `src/test/aiur/codeowners/edit_test.exs` (module
     `Aiur.Codeowners.EditTest`, `async: true`, pure — no fs/net) with at least
     these 5 tests:
     1. `normalize_login/1`: `"@Foo"` → `"foo"`; `"  "` → `nil`; `nil` → `nil`.
     2. `has_login?/2`: content `"* @alice\n"` returns `true` for `"alice"`,
        `"@ALICE"`, and `false` for `"bob"` (case-insensitive, `@`-tolerant).
     3. `content_with_login/2` with an existing `"* @alice # owners"` rule
        appends `@bob` BEFORE the inline `#` comment (assert the result contains
        `"@alice @bob #"`).
     4. `content_with_login/2` on content with no wildcard rule appends a new
        `"* @bob\n"` line (and no leading blank line is added when the input
        already ends in `\n`).
     5. `add_login/2` on a temp file: returns `{:updated, path}` when the login
        is new, `{:exists, path}` on a second call with the same login, and
        `{:error, :missing_github_login}` for a blank login.
   - New tests: `src/test/aiur/init/codeowners_test.exs` (module
     `Aiur.Init.CodeownersTest`, `use ExUnit.Case`) with at least these 3 tests,
     driving `setup_codeowners/3` with a scripted `io` map (build a plain map
     matching the `@type io` shape used by `src/test/aiur/init_test.exs` — copy
     that harness's label-keyed scripted-`io` helper) and a `deps` map providing
     `repo_root` (a fresh tmp dir) and `github_login`:
     1. With no CODEOWNERS present and the create-confirm answered "yes",
        `.github/CODEOWNERS` is created (assert `File.regular?`) and its body
        contains `"aiur uses CODEOWNERS"`.
     2. With the create-confirm answered "no", no file is created and the
        skip line `"Skipped CODEOWNERS."` was emitted.
     3. With `github_login` returning `"octocat"` and the add-confirm "yes",
        the CODEOWNERS file ends up containing `"@octocat"`.
   - Verify: from `src/`, `mix compile --warnings-as-errors && mix test` — green,
     `src/test/aiur/init_test.exs` and `src/test/aiur/codeowners_test.exs`
     untouched and passing. Commit.

3. **Step 2 (commit 2): create `Aiur.Init.GitHub`.**
   - `src/lib/aiur/init/github.ex` — module `Aiur.Init.GitHub`, `@moduledoc`.
     `alias Aiur.GitHub.Labels`, `alias Aiur.Codeowners.Edit`. Copy the module
     attributes these functions reference (verbatim, with their comments if
     any): `@config_file_name ".aiur/config"`, `@env_file_name ".env"`,
     `@token_url "https://github.com/settings/tokens"`. Move verbatim:
     - `create_labels/2` — both clauses (lines 2023–2033) — public `def` with
       `@spec`; calls `Labels.ensure/4`.
     - `list_repo_labels/1` — both clauses (2036–2043) — public `def` with `@spec`.
     - `fetch_label_names/5` (2045–2067, including the `rescue`) — public with
       `@doc false` + `@spec` (test seam); the `Req.get` call and pagination
       (`if length(body) == 100`) move byte-for-byte.
     - `parse_owner_repo/1` (2069–2074) — public with `@doc false` + `@spec`.
     - `require_github_token/0` (2076–2081) — public with `@doc false` + `@spec`;
       calls `Aiur.GitHub.Config.token/0`.
     - `label_error_message/1` — all five clauses (2083–2097) — public with
       `@doc false` + `@spec`.
     - `detect_github_login/0` (2137–2149) — public `def` with `@spec`; the
       `normalize_login` pipe becomes `Edit.normalize_login`.
     - `detect_repo/0` (2165–2172) — public `def` with `@spec`.
     - `parse_repo/1` (2174–2183) — public with `@doc false` + `@spec`.
   - New tests: `src/test/aiur/init/github_test.exs` (module
     `Aiur.Init.GitHubTest`) with at least these 6 tests (no network):
     1. `parse_repo/1`: `"git@github.com:o/r.git"` → `"o/r"`;
        `"https://github.com/o/r.git"` → `"o/r"`; `"https://github.com/o/r"` →
        `"o/r"`; `"garbage"` → `nil`.
     2. `parse_owner_repo/1`: `"o/r"` → `{:ok, {"o", "r"}}`; `nil` and `"nope"`
        → `{:error, msg}` where `msg` contains `".aiur/config"`.
     3. `label_error_message/1` for `{:github_api_status, 403, "agent:todo"}`,
        `{:github_api_status, 404, "agent:todo"}`, `{:github_api_status, 500, "x"}`,
        `{:github_api_request, :timeout}`, and an unknown term each return the
        documented string (404 mentions `"404"` and `".aiur/config"`).
     4. `require_github_token/0`: with `GITHUB_TOKEN` deleted returns
        `{:error, msg}` (`msg` contains `".env"`); with it set to `"tok"`
        returns `{:ok, "tok"}`. Use `on_exit` to restore the env var; NOT
        `async`.
     5. `detect_repo/0`: in a fresh tmp dir made a git repo with
        `git remote add origin git@github.com:o/r.git`, invoked via
        `File.cd!(tmp, fn -> Aiur.Init.GitHub.detect_repo() end)`, returns
        `"o/r"`; in a git repo with no `origin` remote returns `nil`.
     6. `list_repo_labels/1` with a non-github tracker (`%{kind: "memory"}`)
        returns `{:ok, []}`, and `create_labels/2` with the same returns `:ok`
        (the catch-all clauses).
   - Verify: `mix compile --warnings-as-errors && mix test` green. Commit.

4. **Step 3 (commit 3): create `Aiur.Init.AgentCli`.**
   - `src/lib/aiur/init/agent_cli.ex` — module `Aiur.Init.AgentCli`,
     `@moduledoc`. `alias Aiur.Claude.Config`, `alias Aiur.Codex.Config`. Copy
     the attribute `@routing_order ["claude", "codex"]` (with its "Low
     complexity routes to the first kind, high to the last." comment). Move
     verbatim:
     - `check_agent_clis/3` (lines 1574–1582) — public `def` with `@spec`; keep
       the `Enum.filter(&(&1 in @routing_order))` filter exactly.
     - `ensure_agent_cli/3` — both clauses (1589–1598) — private.
     - `install_claude_then_check/2` (1600–1615) — private.
     - `run_auth_check/3` (1617–1631) — private.
     - `check_agent_auth/1` (2099–2111) — public `def` with `@spec`.
     - `install_hint/2` — both clauses (2115–2116) — public with `@doc false` +
       `@spec` (test seam).
     - `install_claude_app_server/0` (2122–2135, including the `rescue`) —
       public `def` with `@spec`.
     - `agent_executable/1` (2151–2163) — public with `@doc false` + `@spec`
       (test seam); calls `Aiur.Claude.Config.command/0` and
       `Aiur.Codex.Config.command/0`.
   - New tests: `src/test/aiur/init/agent_cli_test.exs` (module
     `Aiur.Init.AgentCliTest`) with at least these 3 tests (no network; do not
     invoke `npm`):
     1. `install_hint/2`: `install_hint("claude", "anything")` mentions
        `"npm install -g aiur-claude"`; `install_hint("codex", "codex")`
        mentions `"codex"` and `"PATH"`.
     2. `agent_executable/1`: `"claude"` and `"codex"` return the first
        whitespace-delimited token of their configured command (a binary);
        an unknown kind (e.g. `"nope"`) returns `nil`.
     3. `check_agent_auth/1` for an unknown kind returns
        `{:error, "no command configured for nope"}`.
   - Verify: `mix compile --warnings-as-errors && mix test` green. Commit.

5. **Step 4 (commit 4): create `Aiur.Init.Labels`.**
   - `src/lib/aiur/init/labels.ex` — module `Aiur.Init.Labels`, `@moduledoc`.
     `alias Aiur.GitHub.Labels`, `alias Aiur.Init.Format`. Copy the attributes
     `@label_prefix "agent"` (with its workflow-state comment) and
     `@config_file_name ".aiur/config"`. Move verbatim:
     - `setup_labels/4` — both clauses (lines 1387–1398) — public `def` with
       `@spec`; the `with`-chain over the four stages is unchanged.
     - `fetch_existing_labels/2` (1402–1407) — private.
     - `create_lifecycle_labels/4` (1410–1425) — private; `Labels.state_labels`,
       `label_status_line`, `print_label_list`, and
       `Format.print_hint(io, ...)` calls unchanged (`print_hint` lives in
       `Aiur.Init.Format` per T-031).
     - `maybe_create_complexity_labels/4` (1428–1442) — private.
     - `maybe_create_model_labels/5` (1446–1460) — private.
     - `maybe_create_remote_label/5` (1463–1481) — private; the
       `Labels.alias_labels(kinds)` empty-vs-present branch unchanged.
     - `create_or_skip/7` (1483–1490) — private.
     - `label_status_line/1` (1494) — private; keeps the exact
       `IO.ANSI.format([:faint, "  #{name}: created."])`.
     - `create_labels_request/5` (1496–1506) — private; calls
       `deps.create_labels.(tracker, missing)` (injected — do NOT call
       `Aiur.Init.GitHub` directly).
     - `print_label_list/2` (1509–1515) — private; keeps the
       `String.pad_trailing(label, width)` alignment.
     - `emit_gh_label_fallback/4` (1521–1532) — private; the
       `gh label create ... --force` line moves byte-for-byte.
     - `shell_arg/1` (1534) — private.
   - Note: `print_hint/2` (init.ex:1517) is NOT moved here — it belongs to
     `Aiur.Init.Format` (T-031). Reference it as `Format.print_hint`.
   - New tests: `src/test/aiur/init/labels_test.exs` (module
     `Aiur.Init.LabelsTest`) with at least these 4 tests, driving
     `setup_labels/4` with a scripted `io` map (copy the `init_test.exs`
     harness) and a `deps` map providing `list_labels`/`create_labels` fakes:
     1. With `list_labels` returning every lifecycle label already present and
        all optional confirms "no", each all-existing stage prints its faint
        `"created."` status line (assert the lifecycle status substring) and no
        `create_labels` call is made; result is `:ok`.
     2. With `list_labels` returning `[]` and `create_labels` returning `:ok`,
        the lifecycle stage emits `"Press Enter to create them"` and calls
        `create_labels` with the missing labels.
     3. With `create_labels` returning `{:error, "no scope"}` on the lifecycle
        stage, `setup_labels/4` returns `:error` and the output contains a
        `"gh label create"` fallback line.
     4. With `kinds` that yield no alias labels
        (`Aiur.GitHub.Labels.alias_labels(kinds) == []`), the remote stage is
        skipped (no `"model:remote"` prompt appears).
   - Verify: `mix compile --warnings-as-errors && mix test` green. Commit.

6. **Step 5 (commit 5): create `Aiur.Init.Dotenv`.**
   - `src/lib/aiur/init/dotenv.ex` — module `Aiur.Init.Dotenv`, `@moduledoc`.
     Copy the attribute `@env_file_name ".env"`. Move verbatim, applying the
     two public renames:
     - `load_dotenv/0` (lines 2203–2210) → **`load/0`**, public `def` with
       `@spec`; keep the exact "existing env always wins / values never logged"
       comment block; still reads `Path.join(File.cwd!(), @env_file_name)`.
     - `put_env_if_unset/1` (2212–2215) — private.
     - `parse_dotenv/1` (2219–2223) → **`parse/1`**, public `def` with `@spec`.
     - `parse_dotenv_line/1` (2225–2233) — private.
     - `parse_dotenv_pair/1` (2235–2246) — private.
     - `dotenv_value/1` (2248) — private.
   - New tests: `src/test/aiur/init/dotenv_test.exs` (module
     `Aiur.Init.DotenvTest`) with at least these 3 tests:
     1. `parse/1` (pure, can be `async`) on
        `"A=1\n# comment\n\nB=\"x\"\nC='y'\nEMPTY=\n"` returns exactly
        `[{"A", "1"}, {"B", "x"}, {"C", "y"}]` (comment, blank, and
        empty-value lines dropped; surrounding quotes stripped).
     2. `parse/1` on a line with no `=` (`"NOTAPAIR"`) yields no pair.
     3. `load/0` (NOT `async`): in a tmp dir containing a `.env` with
        `LOADED_ONLY=fromfile` and `PRESET=fromfile`, with `PRESET` pre-set in
        the real env to `"fromenv"`, invoked via `File.cd!(tmp, fn -> ... end)`,
        sets `LOADED_ONLY` to `"fromfile"` and leaves `PRESET` as `"fromenv"`
        (existing-env-wins). Use `on_exit` to `System.delete_env` both keys.
   - Verify: `mix compile --warnings-as-errors && mix test` green. Commit.

7. **Step 6 (commit 6): slim `Aiur.Init` and repoint all call sites.**
   - In `src/lib/aiur/init.ex`, delete every definition moved in steps 1–6
     (all CODEOWNERS flow + edit fns; all `setup_labels`…`shell_arg`; all
     `check_agent_clis`…`run_auth_check`; all GitHub adapters
     `create_labels`…`label_error_message`, `detect_github_login`,
     `detect_repo`, `parse_repo`; `check_agent_auth`…`agent_executable`; the
     dotenv block `load_dotenv`…`dotenv_value`).
   - Replace the public `def parse_dotenv/1` (2217–2223) with a delegate — keep
     the `@doc false` and `@spec`, then:
     `defdelegate parse_dotenv(content), to: Aiur.Init.Dotenv, as: :parse`.
   - In `run/1` (lines 137–142), change the `load_dotenv()` call to
     `Aiur.Init.Dotenv.load()`. Leave the rest of `run/1` exactly as T-031 left
     it.
   - Repoint the remaining in-facade call sites (they live in `fresh_setup/4`,
     `provision/4`):
     - `setup_codeowners(io, deps, tracker)` → `Aiur.Init.Codeowners.setup_codeowners(io, deps, tracker)`
       (fresh_setup, line 316).
     - `check_agent_clis(io, deps, agents)` → `Aiur.Init.AgentCli.check_agent_clis(io, deps, agents)`
       (all three `provision/4` clauses, lines 330/346/353).
     - `setup_labels(io, deps, tracker, agents)` → `Aiur.Init.Labels.setup_labels(io, deps, tracker, agents)`
       (provision, line 333).
   - In `src/lib/aiur/init/resume.ex`: iff the preflight grep found
     `setup_codeowners(` there, repoint that call to
     `Aiur.Init.Codeowners.setup_codeowners(...)`. Make no other edit to
     `resume.ex`.
   - In `src/lib/aiur/init/runtime.ex`, repoint the six `deps`-map values (locate
     by key, not by capture text):
     - `detect_repo:` → `&Aiur.Init.GitHub.detect_repo/0`
     - `github_login:` → `&Aiur.Init.GitHub.detect_github_login/0`
     - `list_labels:` → `&Aiur.Init.GitHub.list_repo_labels/1`
     - `create_labels:` → `&Aiur.Init.GitHub.create_labels/2`
     - `check_agent_auth:` → `&Aiur.Init.AgentCli.check_agent_auth/1`
     - `install_claude_app_server:` → `&Aiur.Init.AgentCli.install_claude_app_server/0`

     Leave the other `deps`/`io` entries (including
     `github_token: &Aiur.GitHub.Config.token/0` and the `repo_root:` closure
     over `Aiur.Codeowners.repo_root`) untouched.
   - Remove from `src/lib/aiur/init.ex` ONLY the module attributes and `alias`
     lines that this extraction leaves with zero remaining references — the
     `mix compile --warnings-as-errors` gate flags each unused attribute/alias;
     delete exactly those it names and NO others. Do NOT delete an attribute or
     alias still referenced by code remaining in the facade (e.g. `@env_file_name`
     and `@token_url` are still used by `token_setup_instructions/1`, and
     `@linear_key_url` by `linear_walkthrough/2` — those stay).
   - Verify: the full Agent gate (below) is green; `wc -l < src/lib/aiur/init.ex`
     prints `<= 245`. Commit.

8. **Dependency direction (enforce, do not deviate).** `Aiur.Init` (facade) →
   {`Codeowners`, `Labels`, `AgentCli`, `Dotenv`}. `Aiur.Init.Codeowners` →
   {`Aiur.Codeowners`, `Aiur.Codeowners.Edit`, `Aiur.Init.Format`}.
   `Aiur.Init.GitHub` → {`Aiur.GitHub.Labels`, `Aiur.GitHub.Config`,
   `Aiur.Codeowners.Edit`}. `Aiur.Init.Labels` → {`Aiur.GitHub.Labels`,
   `Aiur.Init.Format`} and the injected `deps` (never `Aiur.Init.GitHub`
   directly). `Aiur.Init.AgentCli` → {`Aiur.Claude.Config`, `Aiur.Codex.Config`}.
   `Aiur.Init.Dotenv` → none. `Aiur.Codeowners.Edit` → none. No extracted module
   calls the `Aiur.Init` facade.

9. **Test authoring rules** (from `docs/refactor/regression-safety.md` §2): no
   `Process.sleep` synchronization; any `assert_receive` window `>= 2000 ms`; no
   exact-count assertions on shared singletons. Tests that mutate `System` env
   (`Dotenv.load/0`, `GitHub.require_github_token/0`) must NOT be `async: true`
   and must restore state via `on_exit`. No new test requires tmux, docker, ssh,
   or network.

## Files

- Create: `src/lib/aiur/codeowners/edit.ex`, `src/lib/aiur/init/codeowners.ex`, `src/lib/aiur/init/github.ex`, `src/lib/aiur/init/agent_cli.ex`, `src/lib/aiur/init/labels.ex`, `src/lib/aiur/init/dotenv.ex`
- Modify: `src/lib/aiur/init.ex`, `src/lib/aiur/init/runtime.ex`, `src/lib/aiur/init/resume.ex`
- Test: `src/test/aiur/codeowners/edit_test.exs`, `src/test/aiur/init/codeowners_test.exs`, `src/test/aiur/init/github_test.exs`, `src/test/aiur/init/agent_cli_test.exs`, `src/test/aiur/init/labels_test.exs`, `src/test/aiur/init/dotenv_test.exs`

## Out of scope

- The T-031/T-032 modules — `src/lib/aiur/init/{format,questions,resume,templates,runtime,scaffold,migration,prewarm,alerts}.ex` and `src/lib/aiur/init/prewarm/failure.ex` — are read-only here EXCEPT the two surgical repoints named in Scope step 7 (`runtime.ex` deps-map values; the `resume.ex` `setup_codeowners` call, if present). Any other change to them: STOP and comment.
- `src/lib/aiur/codeowners.ex` (the existing `Aiur.Codeowners` parser) — do NOT edit it. `Aiur.Codeowners.Edit` is a NEW sibling file; do not merge the two tokenizers (flagged follow-up).
- `src/lib/aiur/init/prompt.ex` — untouched.
- `src/test/aiur/init_test.exs` — the primary characterization pin; must stay byte-identical and pass. `src/test/aiur/codeowners_test.exs`, `src/test/aiur/init/prompt_test.exs`, `src/test/aiur/cli_test.exs` — untouched and passing.
- `src/test/aiur/regression/` — read-only, never edited. This ticket moves NO `@external_resource` / `__DIR__` compile-time path (those are the Templates attributes, already handled by T-031), so `compile_time_paths_test.exs` is unaffected.
- `src/mix.exs` — do NOT add the new modules to `ignore_modules` (the list only ever shrinks) and do not change the `threshold`.
- Any behavior change: no renamed error tuples, no reworded operator text, no altered label padding or `gh` fallback, no new features, no fixing of "weird" code you notice while moving it. No merging of `@config_file_name` copies into a shared module (each module owns its copy — verbatim-move policy).

## Inventory-IDs

From `docs/refactor/feature-inventory/ws.md`, the entries this ticket's files implement:

- **FI-WS-023** — CODEOWNERS trust setup (#705): `Aiur.Init.Codeowners` + `Aiur.Codeowners.Edit` (init.ex:1148–1368) and the `gh api user` login detection now in `Aiur.Init.GitHub.detect_github_login/0` (init.ex:2137–2149).
- **FI-WS-026** — GitHub label provisioning (staged, idempotent, token-gated): `Aiur.Init.Labels` (init.ex:1387–1534) + `Aiur.Init.GitHub` label/API adapters (init.ex:2023–2097).
- **FI-WS-027** — Agent CLI presence checks + aiur-claude auto-install: `Aiur.Init.AgentCli` (init.ex:1571–1631, 2099–2135, 2151–2163).
- **FI-WS-017** — `aiur init` wizard entry (dotenv load half): the `.env` load/parse moved into `Aiur.Init.Dotenv` (init.ex:2203–2248); the `run/1` risk-warning + `:req` start stay in the `Aiur.Init`/`Aiur.Init.Runtime` seam (T-031).

(FI-WS-018/019/020/021/022/024/025 belong to the T-031/T-032 modules and are out of scope here.)

## Characterization-tests

- `src/test/aiur/regression/compile_time_paths_test.exs` (created by T-006, Phase 1) — must pass UNMODIFIED. This ticket moves no compile-time path attribute, so it is unaffected.
- Primary behavior pin (not under `regression/` but the characterization suite for this file, per giant-init.md §4): `src/test/aiur/init_test.exs` (~110 tests driving `Aiur.Init.run/3` + the public facade). It exercises CODEOWNERS setup, label staging, claude app-server install, and dotenv parsing through the facade, so the extraction keeps it green WITHOUT edits. `src/test/aiur/codeowners_test.exs` (pins `Aiur.Codeowners`) must also pass unmodified — the new `Aiur.Codeowners.Edit` submodule adds no behavior to the parser.

## Acceptance criteria

All greps run from the repo root; all `mix` commands from `src/`.

- The 6 new lib files and 6 new test files listed in Files exist (`test -f` each).
- Module declarations exist at the exact paths:
  - `grep -c "defmodule Aiur.Codeowners.Edit" src/lib/aiur/codeowners/edit.ex` → 1
  - `grep -c "defmodule Aiur.Init.Codeowners" src/lib/aiur/init/codeowners.ex` → 1
  - `grep -c "defmodule Aiur.Init.GitHub" src/lib/aiur/init/github.ex` → 1
  - `grep -c "defmodule Aiur.Init.AgentCli" src/lib/aiur/init/agent_cli.ex` → 1
  - `grep -c "defmodule Aiur.Init.Labels" src/lib/aiur/init/labels.ex` → 1
  - `grep -c "defmodule Aiur.Init.Dotenv" src/lib/aiur/init/dotenv.ex` → 1
- `wc -l < src/lib/aiur/init.ex` prints `<= 245`.
- Each new lib file: `wc -l` `<= 200`; `grep -c "@moduledoc" <file>` prints 1. Functions `<= 20` logic lines (excluding comments/blanks/`@spec`/`@doc`) applies only to NEWLY-WRITTEN glue; verbatim-moved functions inherit their current size — do NOT rewrite one to satisfy this.
- The four `Aiur.Codeowners.Edit` renames are in place and the old names are gone from that file:
  - `grep -c "def add_login\|def content_with_login\|def has_login?\|def normalize_login" src/lib/aiur/codeowners/edit.ex` → 4
  - `grep -c "add_codeowners_login\|content_with_codeowner\|codeowners_content_has_login" src/lib/aiur/codeowners/edit.ex` → 0
- The two `Aiur.Init.Dotenv` renames: `grep -c "def load\b" src/lib/aiur/init/dotenv.ex` → 1 and `grep -c "def parse\b" src/lib/aiur/init/dotenv.ex` → 1.
- Facade emptied of the moved concerns — each prints `0`:
  - `grep -c "defp setup_codeowners" src/lib/aiur/init.ex`
  - `grep -c "defp setup_labels" src/lib/aiur/init.ex`
  - `grep -c "defp check_agent_clis" src/lib/aiur/init.ex`
  - `grep -c "defp check_agent_auth" src/lib/aiur/init.ex`
  - `grep -c "defp create_labels" src/lib/aiur/init.ex`
  - `grep -c "defp fetch_label_names" src/lib/aiur/init.ex`
  - `grep -c "defp detect_repo" src/lib/aiur/init.ex`
  - `grep -c "defp load_dotenv" src/lib/aiur/init.ex`
  - `grep -c "defp add_codeowners_login" src/lib/aiur/init.ex`
  - `grep -c "defp normalize_login" src/lib/aiur/init.ex`
- Facade surface intact / repointed — each prints `>= 1`:
  - `grep -c "defdelegate parse_dotenv" src/lib/aiur/init.ex`
  - `grep -c "Aiur.Init.Dotenv.load" src/lib/aiur/init.ex`
  - `grep -c "Aiur.Init.Codeowners.setup_codeowners" src/lib/aiur/init.ex`
  - `grep -c "Aiur.Init.Labels.setup_labels" src/lib/aiur/init.ex`
  - `grep -c "Aiur.Init.AgentCli.check_agent_clis" src/lib/aiur/init.ex`
  - `grep -c "def run" src/lib/aiur/init.ex` (the `run/1` + `run/3` entry flow survived)
- Runtime deps repointed: `grep -c "Aiur.Init.GitHub" src/lib/aiur/init/runtime.ex` → `>= 4` and `grep -c "Aiur.Init.AgentCli" src/lib/aiur/init/runtime.ex` → `>= 2`.
- Semantics anchors moved byte-for-byte — each prints `>= 1`:
  - `grep -cF 'Press Enter to create them' src/lib/aiur/init/labels.ex`
  - `grep -cF 'gh label create' src/lib/aiur/init/labels.ex`
  - `grep -cF ': created.' src/lib/aiur/init/labels.ex`
  - `grep -cF 'GitHub returned 404' src/lib/aiur/init/github.ex`
  - `grep -cF 'npm install -g aiur-claude' src/lib/aiur/init/agent_cli.ex`
  - `grep -cF 'aiur uses CODEOWNERS' src/lib/aiur/init/codeowners.ex`
  - `grep -cF '@routing_order' src/lib/aiur/init/agent_cli.ex`
- New test files meet the directed counts: `grep -c 'test "' <file>` prints `>= 5` (edit), `>= 3` (init/codeowners), `>= 6` (github), `>= 3` (agent_cli), `>= 4` (labels), `>= 3` (dotenv). Each prints `0` for `grep -c "Process.sleep" <file>`.
- `git diff --name-only origin/v2...HEAD` includes exactly the 12 created files, `src/lib/aiur/init.ex`, and `src/lib/aiur/init/runtime.ex`; it includes `src/lib/aiur/init/resume.ex` if and only if `setup_codeowners` was called there; it MUST NOT list `src/mix.exs`, `src/test/aiur/init_test.exs`, `src/test/aiur/codeowners_test.exs`, any `src/test/aiur/regression/` file, or any other T-031/T-032 module file.
- From `src/`: `mix test test/aiur/init_test.exs test/aiur/codeowners_test.exs test/aiur/init/ test/aiur/codeowners/` passes (0 failures).
- The full Agent gate below passes.

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

- Run every grep in Acceptance criteria verbatim; all must match.
- Confirm the PR diff touches only the Files paths; `src/lib/aiur/init.ex` shows deletions plus thin delegation/qualification edits (no logic rewrites), and each new module's function bodies match the deleted facade bodies byte-for-byte modulo module-qualification and the five renames (spot-check `create_lifecycle_labels/4`, `fetch_label_names/5`, `content_with_login/2`, and `install_claude_then_check/2`).
- From `src/`: `mix test test/aiur/ --seed 0` and `mix test test/aiur/ --seed 1` — both green.
- Check: FI-WS-026 — `grep -rn 'Press Enter to create them' src/lib/` hits exactly one file (`init/labels.ex`); a token-gated `aiur init` run against a scratch repo (reviewer, manual) still creates the `agent:*` lifecycle labels and withholds the ready screen on a create failure.
- Check: FI-WS-023 — `grep -rn 'def normalize_login' src/lib/` hits exactly one file (`codeowners/edit.ex`); both `Aiur.Init.Codeowners` and `Aiur.Init.GitHub` reference `Aiur.Codeowners.Edit.normalize_login/1` (grep each).
- Check: FI-WS-017 — `grep -rn 'System.put_env' src/lib/aiur/init` hits only `init/dotenv.ex`; the `run/3` path never loads `.env`.
- Confirm `src/mix.exs` is untouched (new modules are coverage-counted) and the repo-wide coverage still meets the 85% threshold in the CI run.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
