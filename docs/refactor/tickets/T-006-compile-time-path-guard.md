# T-006: Compile-time path-embedding guard test

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:2`

## Problem / context

One defect class has recurred every time the repo layout moved: compile-time
file-path embedding. `@external_resource` attributes and `__DIR__`-relative
`Path.expand` reads bake the build machine's source-tree layout into compiled
BEAM files, and they break at a distance when files move or a release is
relocated: #393 (`@external_resource` paths broke after the `.aiur/`
consolidation), #700/#702 (stale bundled alerts path caused 15 CI failures),
#726 (PromptBuilder `__DIR__` path broke in relocated releases). See
`docs/refactor/research-history-hotspots.md` ("Layout/rename fallout" chain and
hotspot row 15), which explicitly recommends this cheap global guard. The fixed
counter-example lives in `src/lib/aiur/alerts.ex`: `alerts_path/0` (line 311)
and `default_alerts_path/0` (line 329) resolve the alerts.yaml path at RUNTIME
from the active config path instead of a compile-time attribute.

The refactor is about to move dozens of files (phases 3–4 decompose the giant
modules), so this class is at maximum risk right now. This ticket adds one
regression test that greps `src/lib` for `@external_resource` and `__DIR__`
and fails on any occurrence not on an explicit allowlist, so every new
compile-time path embedding becomes a deliberate, reviewed act.

## Scope (exact)

Constraints copied from the characterization-test authoring rules — they are
hard requirements for this test:

- No `Process.sleep` synchronization anywhere in the test (this test is pure
  filesystem reads; it needs none).
- Never assert exact counts on shared singletons — the vacuous-pass guard
  below uses `>=` lower bounds, not exact counts, so removing a legitimate
  site later does not false-fail.
- The test does not touch `src/lib/aiur/events`, the engine, or any process,
  so `:log_file` isolation, `AIUR_RELEASE_NODE` pinning, and `assert_receive`
  windows do not apply. It must be `async: true`.

Steps:

1. Create `src/test/aiur/regression/compile_time_paths_test.exs` with EXACTLY
   this content (copy verbatim — the allowlist strings contain escaped quotes
   `\"` and one escaped interpolation `\#{`; do not "fix" them):

```elixir
defmodule Aiur.Regression.CompileTimePathsTest do
  @moduledoc """
  Guard against compile-time file-path embedding regressions (#393, #700/#702,
  #726).

  `@external_resource` and `__DIR__`-relative paths bake the build machine's
  source-tree layout into compiled BEAM files. Every time the repo layout
  moved, this class broke at a distance: #393 (`@external_resource` paths
  after the `.aiur/` consolidation), #700/#702 (stale bundled alerts path, 15
  CI failures), #726 (PromptBuilder `__DIR__` path in relocated releases).
  See docs/refactor/research-history-hotspots.md ("Layout/rename fallout").

  Every textual occurrence of `@external_resource` or `__DIR__` under
  `src/lib/` — including mentions inside docs and comments — must be on the
  explicit allowlist below. Adding a new occurrence is a deliberate act:
  confirm the path is dereferenced ONLY at compile time (content embedded via
  `File.read!/1`; nothing reads the path at runtime), then add the trimmed
  line under its file key in `@allowlist`.
  """

  use ExUnit.Case, async: true

  # src/test/aiur/regression -> src/lib
  @lib_root Path.expand("../../../lib", __DIR__)

  # file (relative to src/lib) => trimmed matching lines: the currently
  # legitimate sites, captured 2026-07-07 at these locations:
  # aiur/agent_skills.ex:13,16,45,58;
  # aiur/init.ex:49,50,72,73,82,83,93,94,95,96;
  # aiur/prompt_builder.ex:9; aiur_web/static_assets.ex:4,9,10,11,12.
  @allowlist %{
    "aiur/agent_skills.ex" => [
      "The skill files are embedded at COMPILE time (via `@external_resource` +",
      "`priv/`, not the repo's `.claude` tree. (A runtime `__DIR__`-relative read",
      "@skills_root Path.expand(\"../../../\#{@claude_skills_dir}\", __DIR__)",
      "for path <- bundled_paths, do: @external_resource(path)"
    ],
    "aiur/init.ex" => [
      "@prompt_example_path Path.expand(\"../../../.aiur/examples/prompt.md.example\", __DIR__)",
      "@external_resource @prompt_example_path",
      "@example_path Path.expand(\"../../../.aiur/examples/config.example\", __DIR__)",
      "@external_resource @example_path",
      "@aiurhooks_example_path Path.expand(\"../../../.aiur/examples/hooks.example\", __DIR__)",
      "@external_resource @aiurhooks_example_path",
      "@alerts_macos_example_path Path.expand(\"../../../.aiur/examples/alerts.macos.example\", __DIR__)",
      "@alerts_linux_example_path Path.expand(\"../../../.aiur/examples/alerts.linux.example\", __DIR__)",
      "@external_resource @alerts_macos_example_path",
      "@external_resource @alerts_linux_example_path"
    ],
    "aiur/prompt_builder.ex" => [
      "@shared_prompt_path Path.expand(\"../../prompts/shared-agent-instructions.md\", __DIR__)"
    ],
    "aiur_web/static_assets.ex" => [
      "@dashboard_css_path Path.expand(\"../../priv/static/dashboard.css\", __DIR__)",
      "@external_resource @dashboard_css_path",
      "@external_resource @phoenix_html_js_path",
      "@external_resource @phoenix_js_path",
      "@external_resource @phoenix_live_view_js_path"
    ]
  }

  test "every @external_resource / __DIR__ usage under src/lib is allowlisted" do
    offenders =
      for {file, line_number, trimmed} <- scan_hits(),
          trimmed not in Map.get(@allowlist, file, []) do
        "#{file}:#{line_number}: #{trimmed}"
      end

    assert offenders == [], """
    Compile-time file-path embedding under src/lib not on the allowlist:

    #{Enum.join(offenders, "\n")}

    @external_resource and __DIR__-relative paths bake the build machine's
    source layout into compiled BEAM files; they silently break when the repo
    layout moves or a release is relocated. This exact class produced #393,
    #700/#702 and #726 — see docs/refactor/research-history-hotspots.md
    ("Layout/rename fallout"). Prefer runtime resolution (pattern:
    alerts_path/0 + default_alerts_path/0 in lib/aiur/alerts.ex). If the
    usage is genuinely compile-time-only (content embedded via File.read!/1
    at compile time; the path is never read at runtime), add the trimmed line
    under its file key in @allowlist in
    src/test/aiur/regression/compile_time_paths_test.exs.
    """
  end

  test "the scan walks the real source tree (vacuous-pass guard)" do
    files = Path.wildcard(Path.join(@lib_root, "**/*.ex"))

    assert length(files) >= 100,
           "expected >= 100 .ex files under #{@lib_root}, found #{length(files)} — " <>
             "the scan root is wrong and the allowlist test above passes vacuously"

    refute scan_hits() == [],
           "the scan found zero @external_resource/__DIR__ hits under src/lib — " <>
             "either the matcher broke (fix it) or the last legitimate site was " <>
             "removed (then delete this canary assertion together with @allowlist)"
  end

  # Every {file-relative-to-src/lib, 1-based line number, trimmed line} whose
  # raw line contains @external_resource or __DIR__.
  defp scan_hits do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, @lib_root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _number} ->
        String.contains?(line, "@external_resource") or String.contains?(line, "__DIR__")
      end)
      |> Enum.map(fn {line, number} -> {relative, number, String.trim(line)} end)
    end)
  end
end
```

2. From `src/`, run `mix format test/aiur/regression/compile_time_paths_test.exs`
   so the file is formatter-clean. Do not otherwise reflow the allowlist
   strings.

3. Green check — run
   `mix test test/aiur/regression/compile_time_paths_test.exs` from `src/`.
   Expected outcome: `2 tests, 0 failures`. If the allowlist test fails
   because a line in `src/lib` drifted since this ticket was written (e.g. a
   rebase moved or reworded one of the 20 sites), update ONLY the affected
   trimmed-line string in `@allowlist` to match the current source exactly —
   never add a new file key for a site that did not exist at capture time
   without confirming it is compile-time-only.

4. Red check (proves the guard fires) — temporarily delete the single
   allowlist entry `"@external_resource @prompt_example_path"` from the
   `"aiur/init.ex"` list, rerun the same test file. Expected outcome: 1
   failure whose message names `aiur/init.ex:50: @external_resource
   @prompt_example_path` and contains
   `docs/refactor/research-history-hotspots.md`. Restore the entry, rerun,
   confirm `2 tests, 0 failures` again. This check edits only the file this
   ticket creates — do not touch anything under `src/lib` to test the guard.

5. Run the full Agent gate (Verification below).

Note on the executor rule about `src/test/aiur/regression/`: the never-edit
rule protects the 19 pre-existing regression tests. Creating (and, in step 4,
editing) `compile_time_paths_test.exs` — this ticket's own deliverable — is
the ticket, not a violation. All 19 pre-existing regression tests must still
pass untouched.

## Files

- Create: `src/test/aiur/regression/compile_time_paths_test.exs`
- Modify: none
- Test: `src/test/aiur/regression/compile_time_paths_test.exs`

## Out of scope

- Do NOT fix any of the allowlisted sites. In particular
  `src/lib/aiur/prompt_builder.ex:9` + its runtime `File.read` in
  `shared_prompt_prefix/0` (line 47) is the live #726 seam — it is frozen
  as-is here and addressed by the agent_runner/prompt tickets, not this one.
- Do NOT touch anything under `src/lib/` (no refactoring `@external_resource`
  usages to runtime reads, no comment edits).
- Do NOT edit the 19 existing tests under `src/test/aiur/regression/` or
  `src/test/support/snapshot_support.exs`.
- Do NOT extend the scan to `src/test/`, `scripts/`, `packaging/`, or
  `Application.app_dir` usages — `src/lib` × {`@external_resource`,
  `__DIR__`} only.
- Do NOT add a CI workflow or tripwire wiring (that is T-005).

## Inventory-IDs

The allowlisted sites implement these inventory entries (the test freezes
their current mechanism):

- FI-ART-002 (`.aiur/hooks` scaffold from embedded example — init.ex)
- FI-ART-003 (`.aiur/prompt.md` template scaffold + PromptBuilder — init.ex,
  prompt_builder.ex)
- FI-ART-005 (alerts.yaml runtime path resolution — alerts.ex, the fixed
  counter-example cited in the failure message)
- FI-ART-006 (init scaffolded `.aiur/` layout, templates embedded via
  `@external_resource` — init.ex)
- FI-SKL-050 (bundled skill install, compile-time embedded — agent_skills.ex)
- FI-WS-016 (workspace agent-skills install — agent_skills.ex)
- FI-WEB-032 (compile-time embedded static assets — aiur_web/static_assets.ex)

## Characterization-tests

This ticket itself creates the guard:
`src/test/aiur/regression/compile_time_paths_test.exs`. Adjacent protection
already in-tree (do not modify): `src/test/aiur/alerts_test.exs` (runtime
alerts path), `src/test/aiur/init_test.exs` (embedded templates),
`src/test/aiur/prompt_builder_test.exs`.

## Acceptance criteria

- `src/test/aiur/regression/compile_time_paths_test.exs` exists;
  `grep -c "defmodule Aiur.Regression.CompileTimePathsTest" src/test/aiur/regression/compile_time_paths_test.exs`
  returns 1.
- `grep -c "async: true" src/test/aiur/regression/compile_time_paths_test.exs`
  returns 1; `grep -c "Process.sleep" …` returns 0.
- The allowlist covers exactly the 4 current files:
  `grep -c '"aiur/agent_skills.ex" =>\|"aiur/init.ex" =>\|"aiur/prompt_builder.ex" =>\|"aiur_web/static_assets.ex" =>' src/test/aiur/regression/compile_time_paths_test.exs`
  returns 4, and no other `=> [` file keys exist in `@allowlist`.
- Failure message points at the research doc:
  `grep -c "research-history-hotspots.md" src/test/aiur/regression/compile_time_paths_test.exs`
  returns >= 2 (moduledoc + assertion message).
- From `src/`: `mix test test/aiur/regression/compile_time_paths_test.exs`
  prints `2 tests, 0 failures`.
- The red check (Scope step 4) was performed and produced the documented
  failure, then restored to green.
- `git diff --stat` against the branch point shows exactly one added file and
  zero modified files.
- Size norms: the new file is <= 200 lines (`wc -l` check); every function
  body is <= 20 logic lines (`scan_hits/0` is the largest at ~15).

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

- This PR touches the guarded regression path by design — apply the
  `regression-suite-change` override label before merging.
- Check: offender probe. Append a matching line to a lib file, confirm the
  guard fires, revert:
  `echo "# probe: __DIR__ layout-guard check" >> src/lib/aiur/alerts.ex`,
  then from `src/` run
  `mix test test/aiur/regression/compile_time_paths_test.exs` and confirm 1
  failure whose message contains `aiur/alerts.ex` and
  `docs/refactor/research-history-hotspots.md`; then
  `git checkout -- src/lib/aiur/alerts.ex` and confirm the test file goes
  back to `2 tests, 0 failures`.
- Check: `git diff --stat v2...HEAD` for the PR shows only
  `src/test/aiur/regression/compile_time_paths_test.exs` added, nothing under
  `src/lib/` touched.
- Check: the 20 allowlist entries match the live tree — from repo root,
  `grep -rn "@external_resource\|__DIR__" src/lib --include="*.ex" | wc -l`
  returns 20 (or, if the count differs, every extra/missing hit is explained
  by a commit already merged to `v2` and the allowlist in the PR matches the
  merged state).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
