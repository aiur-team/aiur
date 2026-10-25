defmodule Aiur.Config.RelayTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "local relay defaults on with a thirty-minute orphan timeout" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.relay == true
    assert settings.agent.relay_orphan_timeout_seconds == 1_800
  end

  test "operators can select the direct transport and override the orphan timeout" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"relay" => false, "relay_orphan_timeout_seconds" => 60}})
    assert settings.agent.relay == false
    assert settings.agent.relay_orphan_timeout_seconds == 60
  end

  test "orphan timeout rejects nonpositive and invalid values" do
    for value <- [0, -1, 1.5, "invalid"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"agent" => %{"relay_orphan_timeout_seconds" => value}})
      assert message =~ "agent.relay_orphan_timeout_seconds"
    end
  end

  test "relay rejects nonboolean values" do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"agent" => %{"relay" => "invalid"}})
    assert message =~ "agent.relay"
  end
end
