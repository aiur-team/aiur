defmodule Aiur.Config.AgentTurnCapsTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "repeated-command detection defaults to five and optional caps stay disabled" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.max_repeated_identical_commands == 5
    assert settings.agent.max_commands_per_turn == nil
    assert settings.agent.max_input_tokens_per_turn == nil
  end

  test "operators can set positive per-turn caps and zero disables repeated-command detection" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{
                 max_repeated_identical_commands: 0,
                 max_commands_per_turn: 1_000,
                 max_input_tokens_per_turn: 20_000_000
               }
             })

    assert settings.agent.max_repeated_identical_commands == 0
    assert settings.agent.max_commands_per_turn == 1_000
    assert settings.agent.max_input_tokens_per_turn == 20_000_000
  end

  test "per-turn caps reject non-positive configured values" do
    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_commands_per_turn: 0}})

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_input_tokens_per_turn: -1}})
  end
end
