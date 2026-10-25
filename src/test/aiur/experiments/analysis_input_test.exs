defmodule Aiur.Experiments.AnalysisInputTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{AnalysisInput, Arms, Evidence}

  @ref "delivery-speed/start_to_merge"

  test "flat analysis rows validate, preserve censoring and strata, and hash stably" do
    spec = Path.join(__DIR__, "fixtures/valid_ab.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")

    rows = [
      %{"unit_id" => "second", "value" => 20, "at" => "2026-10-09T01:00:00Z", "censored" => true, "attrs" => %{"backend" => "claude", "complexity" => 3}},
      %{"unit_id" => "first", "value" => 10, "at" => "2026-10-09T00:00:00Z", "censored" => false, "attrs" => %{"backend" => "claude", "complexity" => 1}}
    ]

    data = %{source: :frozen, metrics: %{@ref => %{"coverage" => %{"state" => "captured"}, "observations" => rows}}}
    arms = Arms.assign(spec, [{"observation", data}])
    input = AnalysisInput.build(spec, [], arms)
    schema = Path.expand("../../../priv/experiments/analysis-input.v1.schema.json", __DIR__) |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    assert ExJsonSchema.Validator.validate(schema, input) == :ok
    assert [first, second] = input["rows"]
    assert first == %{"metric" => @ref, "unit_id" => "first", "group" => "control", "value" => 10, "censored" => false, "strata" => %{"complexity" => 1}, "observed_at" => "2026-10-09T00:00:00Z"}
    assert second["censored"] == true
    assert second["strata"] == %{"complexity" => 3}
    assert input["input_sha256"] == Evidence.hash(Map.delete(input, "input_sha256"))
    shuffled = put_in(data, [:metrics, @ref, "observations"], Enum.reverse(rows))
    assert AnalysisInput.build(spec, [], Arms.assign(spec, [{"observation", shuffled}])) == input
    changed = put_in(rows, [Access.at(0), "value"], 21)
    changed = put_in(data, [:metrics, @ref, "observations"], changed)
    refute AnalysisInput.build(spec, [], Arms.assign(spec, [{"observation", changed}]))["input_sha256"] == input["input_sha256"]
    refute ExJsonSchema.Validator.validate(schema, put_in(input, ["rows", Access.at(0), "censored"], "false")) == :ok
  end

  test "missing and nonobject dotted strata remain explicit nulls" do
    spec = %{"stratify_by" => ["tags.team"], "registered_at" => nil}
    rows = [%{"unit_id" => "one", "value" => 1, "at" => "2026-10-09T00:00:00Z", "attrs" => %{"tags" => "invalid"}}]
    arms = %{"arms" => %{"control" => %{"metrics" => %{@ref => %{"observations" => rows}}}}}
    assert [%{"strata" => %{"tags.team" => nil}}] = AnalysisInput.build(spec, [], arms)["rows"]
  end
end
