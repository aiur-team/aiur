defmodule Aiur.BaseBranchLiteralGuardTest do
  use ExUnit.Case, async: true

  @allowed_main_literals %{
    "aiur_web/live/streamdeck_live.ex" => [~s(class="sd-key-main")],
    # Policy labels are identifiers, independent of the configured integration branch.
    "aiur/config/schema/merge_policy.ex" => [~s|field(:fixer_label, :string, default: "main-fix")|, ~s|field(:full_ci_labels, {:array, :string}, default: ["main-fix"])|],
    # MP4 event topics, status fields and component log names are fixed identifiers,
    # independent of Config.base_branch(); subscriptions and polling use that configured branch.
    "aiur/executor_bindings.ex" => [
      ~S|{"system.main.ci.failed", "ci:auto"},|,
      ~S|{"system.main.ci.failed.resolved", "ci:auto"},|,
      ~S|{"system.main.ci.flaked", "ci:auto"},|,
      ~S|{"system.main.ci.flake_rerun", "ci:auto"},|,
      ~S|{"system.main.ci.canary", "attention:auto"},|,
      ~S|{"system.main.ci.unavailable", "attention:auto"},|,
      ~S|{"system.main.fixer.*", "attention:auto"},|
    ],
    "aiur/main_watch.ex" => [
      ~S|Logger.warning("main-watch poll failed: #{inspect(reason)}")|,
      ~S|if Enum.any?(events, &(elem(&1, 0) == "system.main.ci.flaked")) do|,
      ~S|[{"system.main.ci.flake_rerun", %{sha: observation.sha, signature: observation.digest.signature, outcome: outcome_payload(outcome), run_urls: observation.run_urls}}]|,
      ~S|Logger.warning("main-watch reconcile unavailable: #{inspect(reason)}")|,
      ~S|event = {"system.main.ci.unavailable", %{reason: inspect(reason)}}|,
      ~S|event = {"system.main.ci.canary", payload}|,
      ~S|Logger.warning("main-watch persistence failed: #{inspect(reason)}")|,
      ~S|defp attention?("system.main.ci.flake_rerun", %{outcome: outcome}) when is_list(outcome), do: Enum.any?(outcome, &(&1.result.status != "ok"))|,
      ~S|defp attention?(topic, _payload), do: topic in ["system.main.ci.failed", "system.main.ci.canary", "system.main.ci.unavailable", "system.main.ci.flake_rerun"]|
    ],
    "aiur/main_watch/state.ex" => [
      ~S|events = if state.status == :red, do: [{"system.main.ci.failed.resolved", payload}], else: []|,
      ~S|topic = if flaked, do: "system.main.ci.flaked", else: "system.main.ci.failed"|
    ],
    # Fixer topics and evidence markers are protocol identifiers, independent of the base branch.
    "aiur/main_watch/fixer.ex" => [
      ~S|"system.main.fixer.failed"|,
      ~S|"system.main.fixer.needs_triage"|,
      ~S|"system.main.fixer.dispatch_unavailable"|,
      ~S|"system.main.fixer.no_pr"|,
      ~S|"<!-- aiur:main-watch test="|,
      ~S|"<!-- aiur:main-watch test=#{hash(identity)} -->"|
    ],
    "aiur/main_watch/fixer_watchdog.ex" => [~S|"system.main.fixer.stalled"|],
    "aiur/github/main_fixer.ex" => [
      ~S|@marker ~r/<!-- aiur:main-watch signature=([a-f0-9]{64}) sha=([a-f0-9]{40}) -->/|
    ],
    "aiur/merge_policy_cli.ex" => [
      ~S|labels = if policy.ci == "wait" and policy.full_ci_labels == ["main-fix"], do: "", else: " full_ci=[#{Enum.join(policy.full_ci_labels, ",")}]"|,
      ~S|IO.puts("MERGE POLICY ci=#{policy.ci} local_tests=#{policy.local_tests}#{labels} main_watch=#{watch} watcher=#{state.watcher} landing_watcher=#{landing.watcher}#{main}")|,
      ~S|"main=unavailable last_known=" <> String.replace_prefix(main_state(Map.delete(state, :unavailable), now_ms), "main=", "")|,
      ~S|"main=red" <> observation(state, now_ms) <> since <> fixer|,
      ~S|def main_state(%{status: :green} = state, now_ms), do: "main=green" <> observation(state, now_ms)|,
      ~S|def main_state(_state, _now_ms), do: "main=unknown"|
    ]
  }

  test "production code contains no hardcoded main branch literal" do
    lib_root = Path.expand("../../lib", __DIR__)

    violations =
      lib_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        relative_path = Path.relative_to(path, lib_root)
        source = File.read!(path)
        lines = String.split(source, "\n")

        source
        |> hardcoded_main_literal_lines()
        |> Enum.reject(fn line_number -> allowed_main_literal?(relative_path, Enum.at(lines, line_number - 1)) end)
        |> Enum.map(fn line_number -> "#{relative_path}:#{line_number}" end)
      end)

    assert violations == [],
           "hardcoded base-branch literal found; route the value through Aiur.Config.base_branch instead:\n" <>
             Enum.join(violations, "\n")
  end

  test "guard catches every quoted main token while allowing function names" do
    assert hardcoded_main_literal_lines("defp base_branch do\n  _ -> \"main\"\nend") == [2]
    assert hardcoded_main_literal_lines("def prewarm_label, do: \"fetching main\"") == [1]
    assert hardcoded_main_literal_lines("def main(args), do: args\nmode = \"main\"") == [2]
    assert hardcoded_main_literal_lines("def main(args), do: args") == []
  end

  defp hardcoded_main_literal_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_number} -> String.match?(line, ~r/"[^"\n]*\bmain\b[^"\n]*"/i) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp allowed_main_literal?(path, line) do
    Enum.any?(Map.get(@allowed_main_literals, path, []), &String.contains?(line, &1))
  end
end
