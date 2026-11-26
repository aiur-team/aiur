defmodule Aiur.Config.BuildQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.BuildQueue

  test "build_queue defaults are embedded in existing configs" do
    assert {:ok, settings} = Schema.parse(%{})
    assert %BuildQueue{enabled: true, reconcile_interval_seconds: 60, max_writes_per_minute: 20, observation_max_age_seconds: nil, merged_open_grace_seconds: 600} = settings.build_queue
  end

  test "build_queue overrides survive parsing and unknown keys are ignored" do
    attrs = %{
      "enabled" => false,
      "reconcile_interval_seconds" => 10,
      "max_writes_per_minute" => 60,
      "observation_max_age_seconds" => 3600,
      "merged_open_grace_seconds" => 86_400,
      "unknown" => "ignored"
    }

    assert {:ok, settings} = Schema.parse(%{"build_queue" => attrs})
    assert settings.build_queue == %BuildQueue{enabled: false, reconcile_interval_seconds: 10, max_writes_per_minute: 60, observation_max_age_seconds: 3600, merged_open_grace_seconds: 86_400}
  end

  test "build_queue enforces both bounds and accepts the endpoints of each numeric field" do
    for {key, minimum, maximum} <- [{"reconcile_interval_seconds", 10, 3600}, {"max_writes_per_minute", 1, 60}, {"observation_max_age_seconds", 10, 3600}, {"merged_open_grace_seconds", 60, 86_400}] do
      for value <- [minimum - 1, maximum + 1] do
        assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{key => value}})
        assert message =~ "build_queue.#{key}"
      end

      for value <- [minimum, maximum] do
        assert {:ok, settings} = Schema.parse(%{"build_queue" => %{key => value}})
        assert Map.fetch!(settings.build_queue, String.to_existing_atom(key)) == value
      end
    end
  end

  test "build_queue rejects invalid field types" do
    for {key, value} <- [{"enabled", "invalid"}, {"max_writes_per_minute", "invalid"}] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{key => value}})
      assert message =~ "build_queue.#{key}"
    end
  end
end
