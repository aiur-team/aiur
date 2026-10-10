defmodule Aiur.Config.PropagationTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema
  alias Aiur.Orchestrator.BlockerPropagation

  test "explicit propagation booleans survive validated configuration" do
    for value <- [true, false] do
      assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "github", "propagate_blocker_pushes" => value}})
      assert settings.tracker.propagate_blocker_pushes == value
      assert BlockerPropagation.enabled_for?(settings.tracker, "20", fn -> flunk("explicit setting must not read queues") end) == value
    end
  end

  test "unspecified propagation preserves the per-queue default" do
    assert {:ok, settings} = Schema.parse(%{})
    assert Map.fetch!(settings.tracker, :propagate_blocker_pushes) == nil
    queues = fn -> %{queues: [%{start_trigger: :pr_opened, items: [%{number: 20}]}, %{start_trigger: :pr_merged, items: [%{number: 30}]}]} end
    github = %{settings.tracker | kind: "github"}
    assert BlockerPropagation.enabled_for?(github, "20", queues)
    refute BlockerPropagation.enabled_for?(github, "30", queues)
    refute BlockerPropagation.enabled_for?(github, "40", queues)
    refute BlockerPropagation.enabled_for?(%{github | kind: "linear"}, "20", queues)
  end

  test "invalid propagation option is refused at the config boundary" do
    assert {:error, {:invalid_workflow_config, error}} = Schema.parse(%{"tracker" => %{"propagate_blocker_pushes" => "sometimes"}})
    assert error =~ "propagate_blocker_pushes"
  end
end
