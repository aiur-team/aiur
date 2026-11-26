defmodule Aiur.BuildOrder.History.ClassificationCostMeasurementTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.History.ClassificationCost

  # Pilot #6353 used transcript totals because the live usage ledger was full.
  # This guards the published projection, not a new production behavior.
  test "V-12: projection matches the measurement record for pilot 6353" do
    fixture = File.read!(Path.expand("../../../fixtures/history/classification_cost_sample.json", __DIR__)) |> Jason.decode!()

    assert Map.take(fixture, ["pilot_ticket", "sample_size", "proposals_with_epic", "proposals_with_feature", "unsorted"]) == %{
             "pilot_ticket" => 6353,
             "sample_size" => 100,
             "proposals_with_epic" => 95,
             "proposals_with_feature" => 11,
             "unsorted" => 5
           }

    assert fixture["recommended_tickets_per_run"] == fixture["sample_size"]

    sample = %{
      tokens: known_figures(fixture["tokens"], Aiur.UsageEnvelope.token_dimensions()),
      github: known_figures(fixture["github"], [:core, :graphql, :search])
    }

    inputs = %{
      population: fixture["population"],
      sample_size: fixture["sample_size"],
      feature_writes_in_sample: {:known, fixture["feature_writes_in_sample"]},
      epic_writes_in_sample: {:known, fixture["epic_writes_in_sample"]},
      ceilings_per_hour: fixture["ceilings_per_hour"]
    }

    assert ClassificationCost.project(sample, inputs) ==
             {:ok,
              %{
                runs: 9,
                bound: :upper_bound,
                tokens: %{input: {:known, 3_701_304}, cached_input: {:known, 3_110_400}, cache_creation_input: {:known, 0}, output: {:known, 29_394}, reasoning_output: {:known, 2_169}},
                per_ticket: %{input: {:known, 4_113}, cached_input: {:known, 3_456}, cache_creation_input: {:known, 0}, output: {:known, 33}, reasoning_output: {:known, 3}},
                github: %{core: {:known, 18}, graphql: {:known, 0}, search: {:known, 0}},
                feature_writes: {:known, 89},
                epic_writes: {:known, 762},
                hours: [{:known, 2}, {:known, 1}],
                hours_with_epic_labels: [{:known, 15}, {:known, 7}]
              }}
  end

  defp known_figures(values, dimensions), do: Map.new(dimensions, &{&1, {:known, Map.fetch!(values, Atom.to_string(&1))}})
end
