# T-019: Single identifier/path sanitization module

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:2` `model:claude`

## Problem / context

The identifier/filesystem sanitization regex (replace every character outside
`[A-Za-z0-9._-]` with `_`) exists in five copies: the documented canonical one,
`Aiur.Config.Paths.sanitize/1` (`src/lib/aiur/config/paths.ex:61-64`, FI-CFG-100),
plus private re-implementations in `src/lib/aiur/workspace.ex:875-877`
(`safe_identifier/1`, with an `identifier || "issue"` default),
`src/lib/aiur/opencode/config.ex:139-142` (public `safe_identifier/1`, identical
body), `src/lib/aiur/claude/hook_settings.ex:77` (`slug/1`, same character class
spelled `[^A-Za-z0-9_.-]`), and `src/lib/aiur/test_reset.ex:596` (inlined). See
`docs/refactor/research-arch/dup-backends.md` Cluster 10 and
`docs/refactor/research-arch/dup-infra.md` §10 — this ticket implements exactly
their consolidation.

The output of this transformation is a CROSS-SUBSYSTEM JOIN KEY: workspace
directory names (`<root>/<owner>/<repo>/<safe_id>`), opencode model ids
(`issue-<safe_id>`, FI-OC-055), per-issue log/session filenames, and
hook-settings temp files must all derive the SAME string from the same
identifier, or lookups silently break (a workspace dir sanitized one way and a
session file sanitized another no longer pair up). Because each copy is
private, nothing enforces they stay identical — if one is "improved" (e.g.
collapsing `..`, a gap `paths.ex` documents by test) the joins break. All five
copies are byte-identical in behavior today (the three regex spellings
`[^A-Za-z0-9._-]`, `[^a-zA-Z0-9._-]`, `[^A-Za-z0-9_.-]` denote the same
character set); this ticket makes that permanent by giving them one home and a
test pinning the exact transformation.

## Scope (exact)

The canonical module already exists: `Aiur.Config.Paths`
(`src/lib/aiur/config/paths.ex`). Per the binding name map
(`dup-backends.md` Cluster 10), do NOT create a new module — extend `Paths`
with a defaulting arity-2 variant and delegate the other four sites to it. The
transformation must remain byte-identical; you are changing only WHERE the
regex lives, never WHAT it produces.

1. In `src/lib/aiur/config/paths.ex`, insert this function directly below the
   existing `sanitize/1` (after current line 64), verbatim:

   ```elixir
   @doc """
   Like `sanitize/1`, but substitutes `default` when `value` is `nil`.

   Canonical home of the former per-site `safe_identifier/1` copies
   (workspace dirs, opencode model ids/session rows, hook-settings temp
   files, test-reset workspace paths). These names are join keys across
   subsystems: they must all derive from this one function, byte-identically,
   or cross-subsystem lookups break.
   """
   @spec sanitize(String.t() | nil, String.t()) :: String.t()
   def sanitize(value, default) when is_binary(default) do
     sanitize(value || default)
   end
   ```

   Do not modify `sanitize/1` itself (lines 61-64) in any way.

2. In `src/lib/aiur/workspace.ex`:
   - Insert `alias Aiur.Config.Paths` on a new line immediately after line 7
     (`alias Aiur.{Config, PathSafety, RepoBase, SSH}`). This grouped-then-
     nested alias pattern is house style (see `src/lib/aiur/alerts.ex:9-10`).
   - Replace the body of `safe_identifier/1` (lines 875-877) so it reads
     exactly:

     ```elixir
     defp safe_identifier(identifier) do
       Paths.sanitize(identifier, "issue")
     end
     ```

   - Change nothing else. All call sites (lines 20, 350, 361, 808, 868) and
     the traversal-dropping `safe_repo_segment/1` (lines 864-873) stay as-is.

3. In `src/lib/aiur/opencode/config.ex`:
   - Insert `alias Aiur.Config.Paths` on a new line immediately after line 6
     (`@behaviour Aiur.AgentConfig`), separated by a blank line.
   - Replace the body of the public `safe_identifier/1` (lines 139-142) so it
     reads exactly (keep the function PUBLIC and keep the `@spec` — it has
     external callers in `src/lib/aiur/opencode/protocol.ex` and
     `src/lib/aiur/opencode/session_writer_registry.ex` that must not change):

     ```elixir
     @spec safe_identifier(String.t() | nil) :: String.t()
     def safe_identifier(identifier) do
       Paths.sanitize(identifier, "issue")
     end
     ```

4. In `src/lib/aiur/claude/hook_settings.ex`:
   - Insert `alias Aiur.Config.Paths` on a new line immediately after the
     closing `"""` of the `@moduledoc` (line 9), separated by a blank line.
   - Replace line 77 so it reads exactly:

     ```elixir
     defp slug(identifier), do: Paths.sanitize(identifier)
     ```

     Note: arity-1, no `"issue"` default — `slug/1` is only called with the
     already-validated binary identifier (line 50); preserve that exactly.

5. In `src/lib/aiur/test_reset.ex` (it already has `alias Aiur.Config.Paths`
   at line 38 — do not add another), replace line 596 so it reads exactly:

   ```elixir
   safe_id = Paths.sanitize(to_string(id))
   ```

6. In `src/test/aiur/config_paths_test.exs`, add this describe block inside
   the module, after the existing `describe "sanitize/1"` block (after current
   line 40), verbatim:

   ```elixir
   describe "sanitize/2 (identifier join key)" do
     # Pins the EXACT current transformation shared by the five former
     # copies (config/paths.ex, workspace.ex, opencode/config.ex,
     # claude/hook_settings.ex, test_reset.ex). Workspace dir names,
     # opencode model ids, and per-issue log/session filenames are join
     # keys across subsystems: they must all derive identically or
     # cross-subsystem lookups silently break. Any diff here is a breaking
     # change to on-disk naming — never "fix" an expected value.
     @sanitize_fixtures [
       {"issue-123", "issue-123"},
       {"ISSUE_42.v1-final", "ISSUE_42.v1-final"},
       {"owner/repo#45", "owner_repo_45"},
       {"a b\tc\nd", "a_b_c_d"},
       {"../etc/passwd", ".._etc_passwd"},
       {"..", ".."},
       {".", "."},
       {"..hidden..", "..hidden.."},
       {"trailing.", "trailing."},
       # The regex is byte-oriented (no /u modifier): every byte of a
       # multi-byte UTF-8 character is replaced with one underscore.
       {"héllo wörld", "h__llo_w__rld"},
       {"ünïcode", "__n__code"},
       {"🎉", "____"},
       {"", ""}
     ]

     test "matches the historical transformation byte-for-byte" do
       for {input, expected} <- @sanitize_fixtures do
         assert Paths.sanitize(input) == expected
         assert Paths.sanitize(input, "issue") == expected
       end
     end

     test "nil falls back to the default" do
       assert Paths.sanitize(nil, "issue") == "issue"
     end

     test "opencode safe_identifier stays a byte-identical delegate" do
       for {input, _expected} <- @sanitize_fixtures do
         assert Aiur.Opencode.Config.safe_identifier(input) ==
                  Paths.sanitize(input, "issue")
       end

       assert Aiur.Opencode.Config.safe_identifier(nil) == "issue"
     end
   end
   ```

7. Run `mix format` from `src/` (formatting only; if it rewrites your
   insertions, keep the formatted result). Then run the full Agent gate.

## Files

- Create: None — the canonical module is the existing `Aiur.Config.Paths`
  (`src/lib/aiur/config/paths.ex`), per `dup-backends.md` Cluster 10 (the
  binding name map).
- Modify:
  - `src/lib/aiur/config/paths.ex`
  - `src/lib/aiur/workspace.ex`
  - `src/lib/aiur/opencode/config.ex`
  - `src/lib/aiur/claude/hook_settings.ex`
  - `src/lib/aiur/test_reset.ex`
- Test: `src/test/aiur/config_paths_test.exs` (modify — add the
  `sanitize/2` describe block; do not change the existing tests)

## Out of scope

- `src/lib/aiur/pane_manager.ex:1786` — the node-name sanitize
  (`[^A-Za-z0-9_-]` → `"-"`) is GENUINELY DIFFERENT (dots are invalid in BEAM
  node short-names, and it replaces with `-` not `_`). Do not migrate it, do
  not touch the file.
- The `~/.aiur/logs` log-home literal consolidation (`dup-infra.md` §10,
  second half) — not this ticket.
- `src/lib/aiur/opencode/protocol.ex` and
  `src/lib/aiur/opencode/session_writer_registry.ex` — callers of
  `Opencode.Config.safe_identifier/1`; they keep calling it unchanged.
- `src/lib/aiur/issue_log.ex`, `src/lib/aiur/session_handle.ex`,
  `src/lib/aiur/events/subscription_store.ex` — already delegate to
  `Paths.sanitize/1`; nothing to do there.
- Any hardening or behavior change to the transformation (collapsing `..`,
  Unicode-aware replacement, trimming) — explicitly forbidden; byte-identical
  or nothing.
- `shell_escape` dedup (T-018), workspace decomposition (T-048/T-049), config
  schema split (T-052).
- Everything under `src/test/aiur/regression/` — read-only.
- `src/mix.exs` — do not edit (in particular the coverage `ignore_modules`
  list; `Aiur.Config.Paths` is not on it and must not be added).

## Inventory-IDs

Behavior these files implement that must survive unchanged:

- **FI-WS-001** (ws.md) — per-issue workspace creation; sanitize step
  `src/lib/aiur/workspace.ex:875-877` is this ticket's exact target.
- **FI-WS-002** (ws.md) — repo-namespaced layout; `safe_repo_segment` maps
  each component through `safe_identifier/1` (workspace.ex:864-873).
- **FI-WS-030** (ws.md) — per-ticket reset `rm -rf`'s
  `<workspace_root>/<sanitized-id>`; the test_reset.ex:596 inline copy.
- **FI-ART-021** (art.md) — per-issue git workspace paths; identifiers
  sanitized before joining (path-escape guard).
- **FI-ART-008** (art.md) — `Aiur.Config.Paths` as single source of truth for
  per-issue/per-repo sidecar paths (the module this ticket extends;
  `log_root_dir/0` itself untouched).
- **FI-CFG-100** (cfg.md) — `Paths.sanitize/1` exact semantics incl. the
  documented-by-test `..` survival; must not change.
- **FI-OC-055** (oc.md) — opencode `safe_identifier` sanitation
  (nil → `"issue"`) feeding model names and session rows; stays public,
  byte-identical.
- **FI-CLD-020** (cld.md) — hook-settings temp-file artifact named with the
  slugged identifier.

## Characterization-tests

- The workspace lifecycle & git metadata suite created by T-010 under
  `src/test/aiur/regression/` (identify the files via
  `git log --name-only --diff-filter=A -- src/test/aiur/regression/` on the
  T-010 merge) — must pass UNMODIFIED.
- The T-006 compile-time path-embedding guard test under
  `src/test/aiur/regression/` — must pass UNMODIFIED.
- All 19 pre-existing files under `src/test/aiur/regression/` (e.g.
  `instance_identity_test.exs`, `shutdown_cleanup_test.exs`,
  `warm_state_transitions_test.exs`) — must pass UNMODIFIED.

Existing (non-regression) tests that pin this area and must also pass
unmodified: `src/test/aiur/config_paths_test.exs` (existing `sanitize/1`
asserts, lines 20-40), `src/test/aiur/opencode/config_test.exs` (lines 93-95,
`model_for_issue` sanitation), `src/test/aiur/workspace_and_config_test.exs`,
`src/test/aiur/workspace_materialize_test.exs`,
`src/test/aiur/claude/hook_settings_test.exs`,
`src/test/aiur/test_reset_test.exs`.

## Acceptance criteria

- Exactly ONE copy of the sanitization regex remains in `src/lib`. From the
  repo root:
  `grep -rnF -e "[^A-Za-z0-9._-]" -e "[^a-zA-Z0-9._-]" -e "[^A-Za-z0-9_.-]" src/lib`
  outputs exactly one line, and it is in `src/lib/aiur/config/paths.ex`
  (before this ticket it outputs five lines).
- `grep -n 'def sanitize(value, default)' src/lib/aiur/config/paths.ex`
  matches (the new arity-2 clause exists in the canonical module).
- `grep -c "" src/lib/aiur/config/paths.ex` <= 200 (expected ~90); every
  function added or edited by this ticket is <= 20 logic lines (the three
  delegates are 1 line each).
- `grep -n 'def safe_identifier' src/lib/aiur/opencode/config.ex` still
  matches (public API preserved for protocol.ex /
  session_writer_registry.ex callers).
- `grep -rn 'Paths.sanitize' src/lib/aiur/workspace.ex src/lib/aiur/opencode/config.ex src/lib/aiur/claude/hook_settings.ex src/lib/aiur/test_reset.ex`
  yields >= 4 hits (one per migrated site).
- `grep -n 'describe "sanitize/2' src/test/aiur/config_paths_test.exs`
  matches, and that block asserts the exact fixture outputs from Scope step 6
  (including the unicode, traversal, and dot cases).
- `git diff --name-only origin/v2...HEAD` lists exactly the six files in
  Files (five under `src/lib/`, one under `src/test/aiur/`) and nothing else —
  in particular no `src/mix.exs`, no `src/lib/aiur/pane_manager.ex`, nothing
  under `src/test/aiur/regression/`.
- `grep -n "Aiur.Config.Paths" src/mix.exs` outputs nothing (the canonical
  module is coverage-enforced; `ignore_modules` is unchanged).
- `cd src && mix test test/aiur/config_paths_test.exs test/aiur/opencode/config_test.exs test/aiur/workspace_and_config_test.exs test/aiur/test_reset_test.exs test/aiur/claude/hook_settings_test.exs`
  passes with zero test-file edits outside the one listed Test file.

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

- Check: rerun the tri-spelling grep from Acceptance criteria; confirm the
  single `config/paths.ex` hit.
- Check (FI-OC-055 probe): `src/test/aiur/opencode/config_test.exs:93-95`
  is byte-unchanged and green —
  `Config.model_for_issue("MT 123/unsafe") == "aiur/issue-MT_123_unsafe"`.
- Check (FI-CFG-100 probe): the pre-existing `sanitize/1` asserts at
  `src/test/aiur/config_paths_test.exs:20-40` are byte-unchanged (including
  the `"../etc/passwd" → ".._etc_passwd"` documented-gap test) and green.
- Check (join-key spot check): from `src/`, run
  `mix run --no-start -e 'IO.puts(Aiur.Config.Paths.sanitize("MT 123/unsafe", "issue")); IO.puts(Aiur.Opencode.Config.safe_identifier("MT 123/unsafe"))'`
  — both lines print `MT_123_unsafe`.
- Check (FI-WS-001/FI-ART-021): `src/test/aiur/workspace_and_config_test.exs`
  and `src/test/aiur/workspace_materialize_test.exs` pass unmodified (workspace
  dir naming unchanged).
- Check: the PR diff shows `src/test/aiur/config_paths_test.exs` gained the
  `sanitize/2` describe block and lost nothing; `src/test/aiur/regression/`
  untouched (`regression-guard / guard` check green without the override
  label).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
