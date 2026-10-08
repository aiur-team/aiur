defmodule AiurWeb.Build.SeamTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @allowed ~w(AiurWeb.BuildLive Aiur.BuildQueue Aiur.AgentChat AiurWeb.Layouts AiurWeb.FinancialDataAccess AiurWeb.Presenter AiurWeb.BuildOrder.Runtime)
  @shell ~w(UnitsRow UnitsControlPolicy DecisionCommands DashboardShell NavState AwaitingCommands RouteRegistry)

  test "web side references only the seam (future regression guard)" do
    files = [Path.join(@root, "lib/aiur_web/live/build_live.ex")] ++ Path.wildcard(Path.join(@root, "lib/aiur_web/build/**/*.ex"))
    assert [_ | _] = files
    assert Enum.all?(files, &File.regular?/1)
    assert offenders(files, &allowed?/1) == []
  end

  test "stores do not reference AiurWeb (future regression guard)" do
    # ponytail: zero files is allowed until history and features stores land; then scan them too.
    files = for store <- ~w(history features), pattern <- ["#{store}.ex", "#{store}/**/*.ex"], file <- Path.wildcard(Path.join(@root, "lib/aiur/build_order/#{pattern}")), do: file
    assert offenders(files, &(not String.starts_with?(&1, "AiurWeb"))) == []
  end

  test "scanner expands grouped aliases and string modules and skips whole-line comments" do
    source = "alias AiurWeb.{Build, DashboardLive}\n\"Elixir.Aiur.Orchestrator\"\n  # see AiurWeb.DashboardLive"
    assert references(source) == [{1, "AiurWeb.Build"}, {1, "AiurWeb.DashboardLive"}, {2, "Aiur.Orchestrator"}]
    assert references("alias AiurWeb.{\n  Build,\n  DashboardLive\n}") == [{2, "AiurWeb.Build"}, {3, "AiurWeb.DashboardLive"}]
    assert references("Module.concat([Aiur.Orchestrator, State])") == [{1, "Aiur.Orchestrator.State"}]
    assert references(~s|Module.concat([AiurWeb, "DashboardLive"])|) == [{1, "AiurWeb.DashboardLive"}]
    refute allowed?("AiurWeb.DashboardLive")
    refute allowed?("Aiur.Orchestrator")
    assert allowed?("AiurWeb.OperatorControlCenter.UnitsRow.Cell")
  end

  defp offenders(files, allowed) do
    for file <- files, {line, module} <- references(File.read!(file)), not allowed.(module), do: {Path.relative_to(file, @root), line, module}
  end

  defp references(source) do
    source
    |> String.replace(~r/^[\t ]*#.*$/m, "")
    |> expand_grouped_aliases()
    |> expand_module_concat()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for [module] <- Regex.scan(~r/\b(?:AiurWeb|Aiur)(?:\.[A-Z]\w*)+/, text), do: {line, module}
    end)
  end

  defp expand_grouped_aliases(source) do
    Regex.replace(~r/((?:AiurWeb|Aiur)(?:\.[A-Z]\w*)*)\.\{([^}]+)\}/, source, fn _, prefix, members ->
      Regex.replace(~r/[A-Z]\w*(?:\.[A-Z]\w*)*/, members, fn member -> prefix <> "." <> member end)
    end)
  end

  defp expand_module_concat(source) do
    Regex.replace(~r/Module\.concat\(\[?([^\]\)]+)\]?\)/, source, fn _, parts ->
      Regex.scan(~r/(?:Elixir\.)?[A-Z]\w*(?:\.[A-Z]\w*)*/, parts)
      |> List.flatten()
      |> Enum.map_join(".", &String.replace_prefix(&1, "Elixir.", ""))
    end)
  end

  defp allowed?(module) do
    module in @allowed or module == "AiurWeb.Build" or String.starts_with?(module, "AiurWeb.Build.") or
      String.starts_with?(module, "Aiur.BuildOrder.") or
      Enum.any?(@shell, fn name ->
        base = "AiurWeb.OperatorControlCenter." <> name
        module == base or (name == "UnitsRow" and String.starts_with?(module, base <> "."))
      end)
  end
end
