defmodule Aiur.Config.Schema.PressureTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "CPU pressure defaults are percentages independent of legacy load settings" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.max_cpu_pressure == 20.0
    assert settings.agent.target_cpu_pressure == 10.0
    assert settings.agent.max_load_average == 1.5
    assert settings.agent.target_load_average == 1.0
  end

  test "CPU pressure settings accept percentage boundaries and numeric overrides" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"max_cpu_pressure" => 100, "target_cpu_pressure" => 0.1}})
    assert settings.agent.max_cpu_pressure == 100.0
    assert settings.agent.target_cpu_pressure == 0.1
  end

  test "CPU pressure settings reject zero, negative, excessive and nonnumeric values" do
    for key <- ["max_cpu_pressure", "target_cpu_pressure"], value <- [0, -0.1, 100.1, "invalid"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"agent" => %{key => value}})
      assert message =~ "agent.#{key}"
    end
  end

  test "explicit pressure nulls survive normalization and disable each setting independently" do
    assert {:ok, maximum_disabled} = Schema.parse(%{"agent" => %{"max_cpu_pressure" => nil}})
    assert maximum_disabled.agent.max_cpu_pressure == nil
    assert maximum_disabled.agent.target_cpu_pressure == 10.0

    assert {:ok, target_disabled} = Schema.parse(%{"agent" => %{"target_cpu_pressure" => nil}})
    assert target_disabled.agent.max_cpu_pressure == 20.0
    assert target_disabled.agent.target_cpu_pressure == nil
  end
end
