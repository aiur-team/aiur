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
  # legitimate sites, captured 2026-08-09 at these locations:
  # aiur/agent_github_guard.ex:13,14; aiur/agent_skills.ex:13,16,45,58;
  # aiur/init/templates.ex:13,14,28,29,38,39,49,50,51,52;
  # aiur/prompt_builder.ex:9,10; aiur_web/static_assets.ex:4,9,10,11,12.
  @allowlist %{
    "aiur/agent_github_guard.ex" => [
      "@script_path Path.expand(\"../../priv/github_quota_guard.sh\", __DIR__)",
      "@external_resource @script_path"
    ],
    "aiur/agent_skills.ex" => [
      "The skill files are embedded at COMPILE time (via `@external_resource` +",
      "`priv/`, not the repo's `.claude` tree. (A runtime `__DIR__`-relative read",
      "@skills_root Path.expand(\"../../../\#{@bundled_skills_dir}\", __DIR__)",
      "for path <- bundled_paths, do: @external_resource(path)"
    ],
    "aiur/init/templates.ex" => [
      "@prompt_example_path Path.expand(\"../../../../.aiur/examples/prompt.md.example\", __DIR__)",
      "@external_resource @prompt_example_path",
      "@example_path Path.expand(\"../../../../.aiur/examples/config.example\", __DIR__)",
      "@external_resource @example_path",
      "@aiurhooks_example_path Path.expand(\"../../../../.aiur/examples/hooks.example\", __DIR__)",
      "@external_resource @aiurhooks_example_path",
      "@alerts_macos_example_path Path.expand(\"../../../../.aiur/examples/alerts.macos.example\", __DIR__)",
      "@alerts_linux_example_path Path.expand(\"../../../../.aiur/examples/alerts.linux.example\", __DIR__)",
      "@external_resource @alerts_macos_example_path",
      "@external_resource @alerts_linux_example_path",
      "@executor_handoff_example_path Path.expand(\"../../../../.aiur/examples/executor-handoff.md.example\", __DIR__)",
      "@external_resource @executor_handoff_example_path"
    ],
    "aiur/prompt_builder.ex" => [
      "@shared_prompt_path Path.expand(\"../../prompts/shared-agent-instructions.md\", __DIR__)",
      "@external_resource @shared_prompt_path"
    ],
    "aiur_web/static_assets.ex" => [
      "@dashboard_css_path Path.expand(\"../../priv/static/dashboard.css\", __DIR__)",
      "@external_resource @dashboard_css_path",
      "@dom_svg_layout_adapter_path Path.expand(\"../../priv/static/aiur-dom-svg-layout-adapter.js\", __DIR__)",
      "@external_resource @dom_svg_layout_adapter_path",
      "@external_resource @phoenix_html_js_path",
      "@external_resource @phoenix_js_path",
      "@external_resource @phoenix_live_view_js_path"
    ],
    "aiur_web/components/operator_control_center/build_order_epic_icon.ex" => [
      "@external_resource path"
    ],
    # The Stream Deck key-face contract is authored once in the npm package
    # that the packaged deck ships from, and embedded into the web emulator at
    # compile time via File.read!/1. Nothing reads @contract_path at runtime.
    "aiur_web/streamdeck_key_face_contract.ex" => [
      "@contract_path Path.expand(\"../../../packages/streamdeck/src/key-face-contract.json\", __DIR__)",
      "@external_resource @contract_path"
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
