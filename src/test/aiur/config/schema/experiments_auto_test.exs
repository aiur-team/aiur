defmodule Aiur.Config.Schema.ExperimentsAutoTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema

  test "empty workflow supplies every automatic line default" do
    assert {:ok, settings} = Schema.parse(%{})

    assert Map.from_struct(settings.experiments.auto) == %{
             enabled: true,
             version_line: true,
             release_line: true,
             release_tag_pattern: "v*",
             release_include_prereleases: false,
             release_min_interval_days: 7,
             feature_label: "experiment:feature",
             feature_live_signal: "auto",
             feature_quiet_hours: 6,
             live_signal_max_wait_hours: 72,
             before_days: 14,
             after_days: 14,
             after_step_days: 7,
             after_max_days: 42,
             metric_packs: ["delivery"]
           }
  end

  test "invalid live signals, backwards windows and malformed tags are rejected" do
    for {field, value} <- [{"feature_live_signal", "deploy"}, {"after_max_days", 7}, {"release_tag_pattern", "v *"}, {"feature_label", ""}, {"before_days", 0}] do
      assert {:error, {:invalid_workflow_config, errors}} = Schema.parse(%{"experiments" => %{"auto" => %{field => value}}})
      assert errors =~ field
    end
  end

  test "automatic lines can be disabled while keeping a custom window" do
    assert {:ok, settings} = Schema.parse(%{"experiments" => %{"auto" => %{"enabled" => false, "after_days" => 21, "after_max_days" => 28}}})
    refute settings.experiments.auto.enabled
    assert settings.experiments.auto.after_days == 21
  end
end
