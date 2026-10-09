defmodule Aiur.BuildQueue.SeamTest do
  use ExUnit.Case, async: true

  @source_root Path.expand("../../../lib/aiur/build_queue", __DIR__)
  @build_order_source Path.join(@source_root, "sources/build_order.ex")
  # #3306 (U2-T01): the build queue is a sanctioned caller of the lifecycle label-write owner.
  @sanctioned ["Aiur.Orchestrator.TicketTransition"]

  # Future-regression guards; MP-R1's dependency checker will absorb these rules.
  test "no build_queue module references orchestration or GitHub" do
    assert offenders(source_files(), ["Aiur.Orchestrator", "Aiur.GitHub"]) == []
  end

  test "only sources/build_order.ex references Aiur.BuildOrder" do
    files = Enum.reject(source_files(), &(&1 == @build_order_source))

    assert offenders(files, ["Aiur.BuildOrder"]) == []
  end

  test "the scanner flags a grouped alias and literal module references" do
    modules = ["Aiur.Orchestrator", "Aiur.GitHub", "Aiur.BuildOrder"]

    assert references("alias Aiur.{Config, GitHub}", modules) == ["Aiur.GitHub"]

    assert references("alias Aiur.{\nOrchestrator.DispatchPolicy, BuildOrder\n}", modules) ==
             ["Aiur.Orchestrator", "Aiur.BuildOrder"]

    assert references(~s|Module.concat(["Elixir.Aiur.GitHub", "Client"])|, modules) == ["Aiur.GitHub"]
    assert references("Aiur.Orchestrator.run()", modules) == ["Aiur.Orchestrator"]
    assert references("alias Aiur.BuildOrder", modules) == ["Aiur.BuildOrder"]
    assert references("# alias Aiur.{Orchestrator, GitHub, BuildOrder}\nalias Aiur.Config", modules) == []
  end

  defp source_files do
    files = Path.wildcard(Path.join(@source_root, "**/*.ex"))
    assert files != [], "No build queue source files found under #{@source_root}"
    files
  end

  defp offenders(files, modules) do
    Enum.flat_map(files, fn file ->
      file
      |> File.read!()
      |> String.replace(@sanctioned, "")
      |> references(modules)
      |> Enum.map(&{Path.relative_to(file, @source_root), &1})
    end)
  end

  defp references(source, modules) do
    source = Regex.replace(~r/#.*$/m, source, "")

    expanded =
      Regex.replace(~r/alias\s+Aiur\.\{([^}]*)\}/, source, fn _, aliases ->
        aliases
        |> String.split(",")
        |> Enum.map_join(" ", &("Aiur." <> String.trim(&1)))
      end)

    Enum.filter(modules, &String.contains?(expanded, &1))
  end
end
