# T-018: Single shell_escape helper

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:2`

## Problem / context

The security-critical single-quote shell-escape primitive is implemented six times in two textual dialects (`docs/refactor/research-arch/dup-backends.md`, Cluster 9): `src/lib/aiur/ssh.ex:97-99`, `src/lib/aiur/workspace.ex:1173-1175`, `src/lib/aiur/codex/coding_agent.ex:1553-1555`, and `src/lib/aiur/opencode/protocol.ex:445-451` use the `'` → `'"'"'` splice; `src/lib/aiur/agent_environment.ex:120-122` and `src/lib/aiur/claude/repl_agent.ex:1172-1174` use the `'` → `'\''` splice. Both dialects are valid POSIX quote-splicing, but reviewers must re-verify each copy, and a hardening fix (e.g. rejecting NUL bytes, which single-quoting does NOT neutralize for `bash -lc` argv) needs six edits today.

These copies guard command splice points across all three backends: the codex `--config model=…` splice and remote SSH launch, the claude REPL flag builder (`--remote-control`, `--resume`, `--model`, …), opencode serve/attach commands, remote workspace prep/hooks/docker bootstrap, and env exports. Consolidating to one module turns "is this splice safe?" into a one-module audit.

## Scope (exact)

Line numbers below are pinned at commit `8712a32f`. If a file has drifted, locate the code by the function names given — the shapes are unambiguous.

1. Create `src/lib/aiur/shell.ex` with EXACTLY this content (module name `Aiur.Shell` is binding per `docs/refactor/research-arch/dup-backends.md` Cluster 9):

   ```elixir
   defmodule Aiur.Shell do
     @moduledoc """
     Single canonical POSIX single-quote shell escaping.

     This is the ONLY shell-escape implementation in the codebase. Every
     Elixir call site that splices a value into a `sh`/`bash -lc` command
     string must use `escape/1`, or `escape/2` with `fast_path: true` when
     human-readable output is wanted for values that are already shell-safe.

     Canonical dialect: wrap the value in single quotes and splice embedded
     single quotes as `'"'"'` (close quote, double-quoted single quote,
     reopen). Note: single-quoting does not neutralize NUL bytes; callers
     must not pass NUL-containing values.

     Shell scripts cannot call this module. Any quoting helper added to a
     shell script must carry a comment pointing at `Aiur.Shell.escape/1` as
     the canonical semantics to mirror. As of this module's creation, no
     shell script in the repo implements shell quoting.
     """

     @fast_path_charset ~r/^[A-Za-z0-9_\/:.,=@%+-]+$/

     @spec escape(String.t()) :: String.t()
     def escape(value) when is_binary(value) do
       "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
     end

     @spec escape(String.t(), fast_path: boolean()) :: String.t()
     def escape(value, opts) when is_binary(value) and is_list(opts) do
       if Keyword.get(opts, :fast_path, false) and String.match?(value, @fast_path_charset) do
         value
       else
         escape(value)
       end
     end
   end
   ```

2. Create `src/test/aiur/shell_test.exs` with EXACTLY this content:

   ```elixir
   defmodule Aiur.ShellTest do
     use ExUnit.Case, async: true

     alias Aiur.Shell

     @tricky_inputs [
       "plain",
       "two words",
       ~s(double "quoted" text),
       "it's",
       "'",
       "''",
       "$HOME and ${PATH}",
       "`id`",
       "line one\nline two",
       "mix 'of' \"all\" $THINGS `here`\nand a newline",
       ""
     ]

     describe "escape/1" do
       test "wraps in single quotes and splices embedded single quotes with the canonical dialect" do
         assert Shell.escape("plain") == "'plain'"
         assert Shell.escape("two words") == "'two words'"
         assert Shell.escape(~s(say "hi")) == ~s('say "hi"')
         assert Shell.escape("it's") == ~s('it'"'"'s')
         assert Shell.escape("$HOME") == "'$HOME'"
         assert Shell.escape("`id`") == "'`id`'"
         assert Shell.escape("a\nb") == "'a\nb'"
         assert Shell.escape("") == "''"
       end

       test "round-trips every tricky input through a real POSIX shell byte-for-byte" do
         for value <- @tricky_inputs do
           {out, 0} = System.cmd("sh", ["-c", "printf %s " <> Shell.escape(value)])
           assert out == value
         end
       end
     end

     describe "escape/2 with fast_path: true" do
       test "returns safe-charset values unquoted" do
         assert Shell.escape("abc-123", fast_path: true) == "abc-123"
         assert Shell.escape("http://127.0.0.1:1234", fast_path: true) == "http://127.0.0.1:1234"
         assert Shell.escape("a_b/c:d.e,f=g@h%i+j", fast_path: true) == "a_b/c:d.e,f=g@h%i+j"
       end

       test "quotes anything outside the safe charset, including the empty string" do
         assert Shell.escape("session one", fast_path: true) == "'session one'"
         assert Shell.escape("it's", fast_path: true) == ~s('it'"'"'s')
         assert Shell.escape("", fast_path: true) == "''"
       end

       test "fast_path: false behaves exactly like escape/1" do
         assert Shell.escape("abc", fast_path: false) == "'abc'"
       end
     end
   end
   ```

3. `src/lib/aiur/ssh.ex` — in `remote_shell_command/1` (line 31) replace `shell_escape(command)` with `Aiur.Shell.escape(command)`. Delete `defp shell_escape/1` (lines 97-99). Do not add an alias; call fully qualified (precedent: `Aiur.AgentSkills.install` in workspace.ex:42).

4. `src/lib/aiur/workspace.ex` — replace all six `shell_escape` occurrences with `Aiur.Shell.escape`:
   - `bootstrap_image_script/3`: `shell_escape(image)` on line 522 and the two occurrences on line 523 (`shell_escape(image)`, `shell_escape(bootstrap_image_copy_script())`).
   - `bootstrap_image_copy_script/0`: `&shell_escape/1` on line 530 becomes `&Aiur.Shell.escape/1`.
   - `run_hook/5` (remote clause): `shell_escape(workspace)` on line 1019.
   - `remote_shell_assign/2`: `shell_escape(raw_path)` on line 1124.
   Delete `defp shell_escape/1` (lines 1173-1175).

5. `src/lib/aiur/codex/coding_agent.ex` — replace `shell_escape(workspace)` in the remote launch command list (line 285) and `shell_escape(~s(#{key}="#{value}"))` in `append_config/3` (line 308) with `Aiur.Shell.escape(...)`. Delete `defp shell_escape/1` (lines 1553-1555).

6. `src/lib/aiur/opencode/protocol.ex` — the public `shell_escape/1` (lines 444-451) is inventory-pinned API (FI-OC-060) and STAYS public, but its body becomes a delegate. Replace the whole function (keeping the `@spec` line) with:

   ```elixir
   @spec shell_escape(String.t()) :: String.t()
   def shell_escape(value) when is_binary(value) do
     Aiur.Shell.escape(value, fast_path: true)
   end
   ```

   Leave the three internal `&shell_escape/1` references (lines 420, 429, 441) unchanged — they now route through the delegate. This is the "re-exports" option the research doc allows.

7. `src/lib/aiur/agent_environment.ex` — in `workspace_env_export_prefix/1` replace the three `shell_escape(...)` interpolations on line 98 with `Aiur.Shell.escape(...)`. Delete `defp shell_escape/1` (lines 120-122). INTENDED behavior note: this file used the `'\''` dialect; values containing a single quote now escape as `'"'"'` instead. The bytes the shell *receives after unquoting* are identical (proven by the round-trip test in step 2); no test pins the old byte form.

8. `src/lib/aiur/claude/repl_agent.ex` — in `build_command/7` replace all seven `shell_escape(...)` calls (lines 1083, 1084, 1085, 1086, 1087, 1088, 1091) with `Aiur.Shell.escape(...)`. Delete `defp shell_escape/1` (lines 1172-1174). Same dialect note as step 7 applies.

9. Shell-side copies: none exist. Verified at ticket-writing time — the only escaping helper in any shell script is `json_escape` in `.claude/skills/aiur-monitor/scripts/watch-alerts.sh:88`, which is JSON string escaping, not shell quoting: leave it untouched. Run `grep -rn "printf %q" scripts/ packaging/ .claude/ 2>/dev/null` and `grep -rn "escape" scripts/ packaging/*/libexec/ 2>/dev/null` from the repo root to confirm nothing new appeared. If a shell-side shell-quoting helper HAS appeared, do NOT port or modify it; add this one-line comment directly above it and mention it in the PR description: `# Shell-quoting semantics must mirror the canonical Elixir implementation: Aiur.Shell.escape/1 (src/lib/aiur/shell.ex)`.

10. Run `mix format` from `src/`, then the full Agent gate below.

## Files

- Create: `src/lib/aiur/shell.ex`, `src/test/aiur/shell_test.exs`
- Modify: `src/lib/aiur/ssh.ex`, `src/lib/aiur/workspace.ex`, `src/lib/aiur/codex/coding_agent.ex`, `src/lib/aiur/opencode/protocol.ex`, `src/lib/aiur/agent_environment.ex`, `src/lib/aiur/claude/repl_agent.ex`
- Test: `src/test/aiur/shell_test.exs` (new; sole test file this ticket creates)

## Out of scope

- Do NOT touch `src/lib/aiur/tmux.ex` — its `send_escape/2` is a keystroke sender (ESC key), not shell escaping.
- Do NOT touch `json_escape` in `.claude/skills/aiur-monitor/scripts/watch-alerts.sh` (JSON escaping, unrelated).
- Do NOT add NUL-byte rejection or any other hardening — this ticket is behavior-preserving consolidation only; the moduledoc's NUL note is documentation, not a check.
- Do NOT touch identifier/path sanitization (`Aiur.Config.Paths.sanitize`, `safe_identifier`, etc.) — that is T-019.
- Do NOT touch `Regex.escape` or `html_escape`/`html_attr_escape` call sites anywhere.
- Do NOT edit `src/mix.exs` (`Aiur.Shell` must NOT be added to `ignore_modules`; the list only shrinks, and this ticket does not shrink it).
- Do NOT edit any existing test file (including `src/test/aiur/ssh_test.exs`, whose line 160-162 byte-pins the canonical dialect — it must pass as-is).
- Do NOT edit anything under `src/test/aiur/regression/`.

## Inventory-IDs

Read from `docs/refactor/feature-inventory/` — these are the entries whose pinned behavior this ticket's Files implement (none of this ticket's files are covered by `tui.md` or `eng.md`; `tmux.ex` contains no shell escaping):

- FI-CDX-018 (cdx.md) — codex app-server spawn, local and remote; remote command `cd <ws>` splice (codex/coding_agent.ex:285) and `SSH.start_port`.
- FI-CDX-020 (cdx.md) — model/effort `--config` splice shell-escaped as ONE single-quoted argument (codex/coding_agent.ex:292-309, 1553-1555).
- FI-CDX-059 (cdx.md) — remote-worker session variants (the SSH launch path built with the escaped command).
- FI-CLD-026 (cld.md) — persistent REPL pane spawn; every flag value single-quote shell-escaped (claude/repl_agent.ex:1080-1092, 1172-1174).
- FI-OC-060 (oc.md) — serve/attach command builders with shell escaping; public `shell_escape` with safe-charset fast path (opencode/protocol.ex:415-451).
- FI-WS-011 (ws.md) — bootstrap-image warm cache seeding via `docker run` (workspace.ex:458-557).
- FI-WS-013 (ws.md) — `before_remove` hook + removal; remote hook commands built through `run_hook`'s escaped `cd` splice (workspace.ex:1019).
- FI-WS-015 (ws.md) — remote (SSH) workspace prep protocol; single-quote escaping of paths (workspace.ex:1121-1175).
- FI-PW-031 (pw.md) — remote docker warm-cache bootstrap (workspace.ex:518-557).
- FI-ART-023 (art.md) — workspace-scoped toolchain cache env exports (agent_environment.ex:55-104, 120-122).

## Characterization-tests

All of `src/test/aiur/regression/` must pass UNMODIFIED. Specifically protecting this ticket's area:

- `src/test/aiur/regression/workspace_lifecycle_test.exs` (created by T-010) — workspace lifecycle incl. remote prep paths.
- `src/test/aiur/regression/chat_pane_loads_session_test.exs` (pre-existing) — pins opencode attach-command behavior (cited by FI-OC-060).
- The opencode-slot/attach file created by T-011 and the agent_runner drain/resume file created by T-013 (their filenames are fixed by those tickets; all Phase-1 tickets are merged into `v2` before Phase 2 starts, so they are on your branch — run the whole directory).

## Acceptance criteria

All checks run from `src/` unless noted. Every bullet must hold:

- `lib/aiur/shell.ex` exists and defines module `Aiur.Shell` with `escape/1` and `escape/2` exactly as specified: `grep -c "defmodule Aiur.Shell do" lib/aiur/shell.ex` prints `1`; `grep -c "def escape" lib/aiur/shell.ex` prints `2`.
- `lib/aiur/shell.ex` is ≤ 200 lines (`wc -l`); no function exceeds 20 logic lines (both are ≤ 6).
- `test/aiur/shell_test.exs` exists and covers spaces, double quotes, single quotes, `$`, backticks, newlines, and the empty string, plus a live `sh` round-trip: `grep -c "printf %s" test/aiur/shell_test.exs` prints `1`.
- No duplicate implementation remains: `grep -rn "defp shell_escape" lib/` prints nothing.
- The token `shell_escape` survives ONLY in the opencode delegate: `grep -rn "shell_escape" lib/ | grep -v "lib/aiur/opencode/protocol.ex"` prints nothing, and `grep -c "def shell_escape" lib/aiur/opencode/protocol.ex` prints `1`.
- All call sites migrated: `grep -ro "Aiur.Shell.escape" lib/aiur/ssh.ex lib/aiur/workspace.ex lib/aiur/agent_environment.ex lib/aiur/claude/repl_agent.ex lib/aiur/codex/coding_agent.ex lib/aiur/opencode/protocol.ex | wc -l` prints `20` (ssh 1, workspace 6, agent_environment 3, repl_agent 7, codex 2, protocol delegate 1).
- Parent files shrank (each loses its private copy): `wc -l` reports `lib/aiur/ssh.ex` ≤ 97 (was 100), `lib/aiur/workspace.ex` ≤ 1232 (was 1235), `lib/aiur/codex/coding_agent.ex` ≤ 1994 (was 1997), `lib/aiur/opencode/protocol.ex` ≤ 449 (was 452), `lib/aiur/agent_environment.ex` ≤ 120 (was 123), `lib/aiur/claude/repl_agent.ex` ≤ 1172 (was 1175).
- Coverage enforces the new module's tests: `grep -n "Aiur.Shell" mix.exs` prints nothing (`Aiur.Shell` is NOT in `ignore_modules`), and `git diff --name-only` shows `src/mix.exs` untouched.
- The canonical-dialect byte pin still holds without edits: `mix test test/aiur/ssh_test.exs` passes and `git diff --name-only` shows no change to `test/aiur/ssh_test.exs`.
- `git diff --name-only <base>...HEAD | grep "^src/test/aiur/regression/"` prints nothing.
- No shell script was edited except (conditionally) the one-line pointer comment from Scope step 9: `git diff --name-only -- "*.sh" scripts/ packaging/` is empty unless step 9's grep found a new shell-quoting helper.

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

- Run every grep and `wc -l` bullet from Acceptance criteria; all must hold on the merge commit.
- FI-OC-060 spot-check: `cd src && mix test test/aiur/opencode/protocol_test.exs` — the "serve and attach commands are shell escaped" test passes; confirm the fast path survives by checking `Protocol.attach_command("http://127.0.0.1:1234")` output embeds the URL unquoted (the test's `=~` assertions only pass if so).
- FI-CLD-026 spot-check: `cd src && mix test test/aiur/claude/repl_agent_test.exs` — REPL command construction unchanged.
- FI-CDX-020 spot-check: `cd src && mix test test/aiur/coding_agent_test.exs` — model/effort `--config` splice tests (lines 328-354) pass.
- FI-ART-023 spot-check: `cd src && mix test test/aiur/agent_environment_test.exs` — export prefix still yields `MISE_TRUSTED_CONFIG_PATHS='<ws>'` for quote-free paths.
- Dialect-unification semantics: `cd src && mix test test/aiur/shell_test.exs` — the POSIX round-trip test proves the shell receives byte-identical values for all tricky inputs under the canonical dialect.
- Confirm the PR diff contains no behavioral edits beyond call-site substitution, the six deletions, and the opencode delegate body.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
