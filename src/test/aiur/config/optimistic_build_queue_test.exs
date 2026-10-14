defmodule Aiur.Config.OptimisticBuildQueueTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.BuildQueue

  test "optimistic failure grace and churn defaults are applied" do
    assert {:ok, parsed} = Schema.parse(%{})
    settings = parsed.build_queue
    assert settings.optimistic_failure_grace_seconds == 600
    assert settings.optimistic_churn_attention_threshold == 3
  end

  test "optimistic policy rejects out-of-range values and accepts disabled churn" do
    for {key, invalid} <- [
          optimistic_failure_grace_seconds: 59,
          optimistic_failure_grace_seconds: 86_401,
          optimistic_churn_attention_threshold: -1,
          optimistic_churn_attention_threshold: 51
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_queue" => %{key => invalid}})
      assert message =~ Atom.to_string(key)
      changeset = BuildQueue.changeset(%BuildQueue{}, %{key => invalid})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, key)
    end

    for grace <- [60, 86_400], churn <- [0, 50] do
      assert BuildQueue.changeset(%BuildQueue{}, %{optimistic_failure_grace_seconds: grace, optimistic_churn_attention_threshold: churn}).valid?
    end
  end
end
