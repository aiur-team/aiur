defmodule Aiur.Config.MaxTurnsByComplexityTest do
  use ExUnit.Case, async: false

  alias Aiur.{Config, Issue, Workflow}

  setup %{config: config} do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("aiur-maxturns-test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.yaml")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      File.rm_rf!(dir)

      if is_nil(previous) do
        Workflow.clear_workflow_file_path()
      else
        Workflow.set_workflow_file_path(previous)
      end
    end)

    :ok
  end

  defp issue(labels), do: %Issue{identifier: "1", title: "t", labels: labels}

  @config """
  tracker:
    kind: memory
  agent:
    kind: codex
    max_turns: 12
    max_turns_by_complexity:
      1: 3
      2: 6
  """

  @tag config: @config
  test "uses the per-complexity cap when the issue's level is configured" do
    assert Config.agent_max_turns_for(issue(["complexity:1"])) == 3
    assert Config.agent_max_turns_for(issue(["complexity:2"])) == 6
  end

  @tag config: @config
  test "falls back to flat max_turns when the level is not in the map" do
    assert Config.agent_max_turns_for(issue(["complexity:5"])) == 12
  end

  @tag config: @config
  test "falls back to flat max_turns when the issue has no complexity label" do
    assert Config.agent_max_turns_for(issue([])) == 12
  end

  @tag config: """
       tracker:
         kind: memory
       agent:
         kind: codex
         max_turns: 12
       """
  test "returns flat max_turns when the map is unset" do
    assert Config.agent_max_turns_for(issue(["complexity:1"])) == 12
  end
end
