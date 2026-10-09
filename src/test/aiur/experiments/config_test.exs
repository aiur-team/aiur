defmodule Aiur.Experiments.ConfigTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema

  test "absent experiments config supplies the complete downstream settings" do
    assert {:ok, settings} = Schema.parse(%{})

    assert Map.from_struct(settings.experiments) == %{
             enabled: true,
             default_min_samples: 15,
             default_before_days: 14,
             pack_dirs: [".aiur/experiments/packs"],
             disabled_packs: [],
             script_timeout_ms: 60_000,
             checkpoint_interval_ms: 3_600_000,
             max_snapshot_observations: 50_000
           }
  end

  test "invalid sample and snapshot limits are both reported" do
    assert {:error, {:invalid_workflow_config, errors}} = Schema.parse(%{"experiments" => %{"default_min_samples" => 0, "max_snapshot_observations" => -1}})
    assert errors =~ "default_min_samples"
    assert errors =~ "max_snapshot_observations"
  end

  test "a disabled writer and empty pack lists are valid" do
    assert {:ok, settings} = Schema.parse(%{"experiments" => %{"enabled" => false, "pack_dirs" => [], "disabled_packs" => []}})
    refute settings.experiments.enabled
    assert settings.experiments.pack_dirs == []
  end
end
