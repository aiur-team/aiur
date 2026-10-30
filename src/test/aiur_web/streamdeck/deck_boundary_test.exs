defmodule AiurWeb.Streamdeck.DeckBoundaryTest do
  use ExUnit.Case, async: true

  test "deck surfaces keep shared reads behind their section adapters" do
    root = Path.expand("../../..", __DIR__)

    files =
      ["lib/aiur_web/streamdeck*.ex", "lib/aiur_web/streamdeck*/**/*.ex", "lib/aiur_web/live/streamdeck*.ex", "lib/aiur_web/live/streamdeck*/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))

    assert files != []

    for file <- files,
        forbidden <- ["ProviderMeterProjection", "AgentEventFeed", "Orchestrator.dashboard_snapshot"] do
      refute File.read!(file) =~ forbidden, "#{Path.relative_to(file, root)} directly reads #{forbidden}"
    end
  end
end
