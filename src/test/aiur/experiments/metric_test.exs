defmodule Aiur.Experiments.MetricTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, Observation}

  test "validates observation samples rather than substituting missing values" do
    assert {:ok, observation} = Observation.new(%{"unit_id" => "a", "value" => 0, "at" => "2026-10-01T00:00:00Z"})
    assert observation.value == 0
    assert observation.at == ~U[2026-10-01 00:00:00Z]

    for value <- ["12", nil, "NaN", "Infinity"] do
      assert {:error, :invalid_observation} = Observation.new(%{unit_id: "a", value: value, at: ~U[2026-10-01 00:00:00Z]})
    end

    assert {:error, :invalid_observation} = Observation.new(%{unit_id: "a", value: 1})
    assert {:error, :invalid_observation} = Observation.new(%{unit_id: "", value: 1, at: ~U[2026-10-01 00:00:00Z]})
  end

  test "metric definition rejects unrecognized kind and non snake_case id" do
    attrs = %{
      "id" => "Latency",
      "label" => "Latency",
      "unit" => "ms",
      "unit_of_analysis" => "deploy",
      "kind" => "custom",
      "better" => "lower",
      "default_direction" => "decrease",
      "group" => "app",
      "requires" => []
    }

    assert {:error, errors} = Metric.new(attrs, "app")
    assert Enum.any?(errors, &(&1.path == "metric.id"))
    assert Enum.any?(errors, &(&1.path == "metric.kind"))
  end
end
