defmodule AiurWeb.Experiments.BoundaryTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib/aiur_web", __DIR__)
  @forbidden ~r/Aiur\.(?:RunTelemetry|Orchestrator|GitHub)\b|Aiur\.Experiments\.|Analytics\.(?:Presenter|Charts)\b|Enum\.(?:sum|frequencies)\b|\b(?:median|quantile)\s*\(|:math\./

  test "page sources use only the experiment facade and never calculate statistics" do
    files = Path.wildcard(Path.join(@lib, "experiments/**/*.ex")) ++ [Path.join(@lib, "live/experiments_live.ex")]
    assert length(files) >= 4

    for file <- files do
      refute Regex.match?(@forbidden, File.read!(file)), "forbidden data or statistics reference in #{file}"
    end
  end

  test "future guard: scan recognizes forbidden aliases and statistics calls" do
    assert Regex.match?(@forbidden, "alias Aiur.RunTelemetry")
    assert Regex.match?(@forbidden, "Enum.sum(samples)")
  end
end
