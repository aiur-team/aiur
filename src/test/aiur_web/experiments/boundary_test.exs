defmodule AiurWeb.Experiments.BoundaryTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib/aiur_web", __DIR__)
  @forbidden ~r/Aiur\.(?:RunTelemetry|Orchestrator|GitHub)\b|Aiur\.Experiments\.|Analytics\.(?:Presenter|Charts)\b|Enum\.(?:sum|frequencies)\b|\b(?:median|quantile)\s*\(/
  # Coordinate transforms are drawing primitives, not statistical inference.
  @allowed_math %{Path.join(@lib, "experiments/charts/svg.ex") => ~w(log10 pow)}
  @math_reference ~r/:math\.([a-zA-Z_][a-zA-Z_0-9]*)/

  test "page sources use only the experiment facade and never calculate statistics" do
    files = Path.wildcard(Path.join(@lib, "experiments/**/*.ex")) ++ [Path.join(@lib, "live/experiments_live.ex")]
    assert length(files) >= 4

    for file <- files do
      source = File.read!(file)
      refute forbidden?(source, file), "forbidden data or statistics reference in #{file}"
    end
  end

  test "future guard: scan recognizes forbidden aliases and statistics calls" do
    assert Regex.match?(@forbidden, "alias Aiur.RunTelemetry")
    assert Regex.match?(@forbidden, "Enum.sum(samples)")
    svg = Path.join(@lib, "experiments/charts/svg.ex")
    refute forbidden?(":math.log10(value) + :math.pow(base, exponent)", svg)
    assert forbidden?(":math.sqrt(value)", svg)
    assert forbidden?(":math.log10(value)", Path.join(@lib, "experiments/charts/forest.ex"))
  end

  defp forbidden?(source, file) do
    Regex.match?(@forbidden, source) or
      Enum.any?(Regex.scan(@math_reference, source), fn [_reference, function] -> function not in Map.get(@allowed_math, file, []) end)
  end
end
