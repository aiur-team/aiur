defmodule Aiur.Config.TestRunSettingsTest do
  # `aiurdev --test` beside the live daemon (#5121): the sandbox overrides must
  # reach the settings every caller reads, not only `TestRunOverrides.apply/1`.
  use Aiur.TestSupport

  setup do
    System.delete_env("AIUR_DEV_TEST_TICKET_IDS")
    ensure_workflow_store_running()
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 16)
  end

  test "settings_from applies the sandbox overrides" do
    Aiur.TestScopeGuard.put_ticket_scope!("2897")

    config = %{
      "agent" => %{
        "max_concurrent_agents" => 16,
        "max_cpu_pressure" => 20.0,
        "max_load_average" => 1.5
      }
    }

    assert {:ok, %{agent: agent}} = Config.settings_from({:ok, %{config: config}})
    assert agent.max_concurrent_agents == 1
    assert [nil, nil] == [agent.max_cpu_pressure, agent.max_load_average]
  end

  test "the settings memo expires when a sandbox run starts" do
    assert Config.settings!().agent.max_concurrent_agents == 16

    Aiur.TestScopeGuard.put_ticket_scope!("2897,2898")
    assert Config.settings!().agent.max_concurrent_agents == 2
    assert Config.max_cpu_pressure() == nil
  end
end
