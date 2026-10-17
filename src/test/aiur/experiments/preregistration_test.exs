defmodule Aiur.Experiments.PreregistrationTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Preregistration
  @fixture Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__)

  test "server timestamps prevent backdating and author cannot hide post-hoc registration" do
    attrs = @fixture |> File.read!() |> Jason.decode!() |> Map.put("reason", "stray reason")
    now = ~U[2026-10-15 18:00:00Z]
    assert {:ok, record} = Preregistration.prepare(attrs, nil, "2026-10-14T18:00:00Z", now)
    assert record["post_hoc"] == true
    refute Map.has_key?(record, "reason")
    assert record["registered_at"] == "2026-10-15T18:00:00Z"
    assert {:ok, timely} = Preregistration.prepare(Map.put(attrs, "post_hoc", true), nil, nil, now)
    assert timely["post_hoc"] == false
    assert timely["amendments"] == []
  end

  test "amendments preserve the original, require a reason, and flag results already read" do
    attrs = @fixture |> File.read!() |> Jason.decode!()
    assert {:ok, first} = Preregistration.prepare(attrs, nil, nil, ~U[2026-10-09 18:00:00Z])
    changed = Map.put(attrs, "hypothesis", "Amended hypothesis")
    assert {:error, [%{path: "reason"}]} = Preregistration.prepare(changed, first, nil, ~U[2026-10-10 18:00:00Z])
    assert {:error, [%{path: "reason"}]} = Preregistration.prepare(Map.put(changed, "reason", "  "), first, nil, ~U[2026-10-10 18:00:00Z])
    assert {:ok, amended} = Preregistration.prepare(Map.put(changed, "reason", "Correct measurement unit"), first, "2026-10-10T00:00:00Z", ~U[2026-10-10 18:00:00Z])
    assert Map.delete(amended, "amendments") == Map.delete(first, "amendments")
    assert [%{"reason" => "Correct measurement unit", "post_hoc" => true, "at" => "2026-10-10T18:00:00Z", "record" => amendment}] = amended["amendments"]
    assert amendment["hypothesis"] == "Amended hypothesis"
    refute Map.has_key?(amendment, "reason")
  end

  @numeric_cases for field <- ["alpha", "fdr_q", "power_target"],
                     {value, message} <- [
                       {-0.1, "violates exclusiveMinimum: 0"},
                       {0, "violates exclusiveMinimum: 0"},
                       {1, "violates exclusiveMaximum: 1"},
                       {1.1, "violates exclusiveMaximum: 1"},
                       {"0.05", ~s(expected "number")}
                     ],
                     do: {[field], value, message}

  @string_fields [
    ["experiment_id"],
    ["hypothesis"],
    ["projected_ready_at"],
    ["stopping_rule"],
    ["baseline_snapshot_hash"],
    ["registered_by", "role"],
    ["registered_by", "agent"],
    ["registered_by", "model"],
    ["mde", "metric"]
  ]
  @string_cases for path <- @string_fields,
                    {value, message} <- [{"", "violates minLength: 1"}, {12, ~s(expected "string")}],
                    do: {path, value, message}

  @metric_cases for role <- ["primary_metrics", "secondary_metrics", "guardrail_metrics"],
                    {suffix, value, message} <- [
                      {[], %{}, ~s(expected "array")},
                      {[0], "latency", ~s(expected "object")},
                      {[0, "id"], "", "violates minLength: 1"},
                      {[0, "id"], 12, ~s(expected "string")},
                      {[0, "id"], :delete, "is required"},
                      {[0, "expected"], "sometimes", ~s(violates enum: ["decrease", "increase", "no-change", "no-increase", "no-decrease"])},
                      {[0, "expected"], :delete, "is required"}
                    ],
                    do: {[role | suffix], value, message}

  @required_cases for field <- [
                        "schema_version",
                        "experiment_id",
                        "registered_by",
                        "hypothesis",
                        "primary_metrics",
                        "secondary_metrics",
                        "guardrail_metrics",
                        "alpha",
                        "secondary_correction",
                        "fdr_q",
                        "mde",
                        "power_target",
                        "planned_n_per_cohort",
                        "projected_ready_at",
                        "stratify_by",
                        "exclusions",
                        "stopping_rule",
                        "baseline_snapshot_hash"
                      ],
                      do: {[field], :delete, "is required"}

  @nested_required_cases for {parent, fields} <- [{"registered_by", ["role", "agent", "model", "ticket"]}, {"mde", ["metric", "relative"]}],
                             field <- fields,
                             do: {[parent, field], :delete, "is required"}

  @other_cases [
    {["schema_version"], "preregistration.v2", ~s(violates const: "preregistration.v1")},
    {["planned_n_per_cohort"], 0, "violates minimum: 1"},
    {["planned_n_per_cohort"], -1, "violates minimum: 1"},
    {["planned_n_per_cohort"], 1.5, ~s(expected "integer")},
    {["planned_n_per_cohort"], "40", ~s(expected "integer")},
    {["primary_metrics"], [], "violates minItems: 1"},
    {["secondary_correction"], "bonferroni", ~s(violates enum: ["benjamini-hochberg"])},
    {["registered_by"], "analyst", ~s(expected "object")},
    {["registered_by", "ticket"], [], ~s(expected ["integer", "string"])},
    {["mde"], [], ~s(expected "object")},
    {["mde", "relative"], "0.2", ~s(expected "number")}
  ]

  @list_cases for field <- ["stratify_by", "exclusions"],
                  {suffix, value, message} <- [
                    {[], "complexity", ~s(expected "array")},
                    {[0], "", "violates minLength: 1"},
                    {[0], 12, ~s(expected "string")}
                  ],
                  do: {[field | suffix], value, message}

  for {path, value, message} <- @numeric_cases ++ @string_cases ++ @metric_cases ++ @required_cases ++ @nested_required_cases ++ @other_cases ++ @list_cases do
    test "rejects #{Enum.join(path, ".")} #{inspect(value)} with a field-specific explanation" do
      path = unquote(path)
      attrs = @fixture |> File.read!() |> Jason.decode!()
      # Populate optional collections before corrupting their nested fields.
      attrs =
        Enum.reduce(["secondary_metrics", "guardrail_metrics"], attrs, fn role, record ->
          Map.put(record, role, [%{"id" => "delivery/start", "expected" => "decrease"}])
        end)

      attrs = attrs |> Map.put("stratify_by", ["complexity"]) |> Map.put("exclusions", ["cancelled"])

      access_path =
        Enum.map(path, fn
          index when is_integer(index) -> Access.at(index)
          key -> Access.key(key)
        end)

      invalid = invalid_registration(attrs, access_path, unquote(Macro.escape(value)))

      assert {:error, errors} = Preregistration.prepare(invalid, nil, nil, ~U[2026-10-15 18:00:00Z])
      assert errors == [%{path: "preregistration." <> Enum.join(path, "."), message: unquote(message)}]
    end
  end

  defp invalid_registration(attrs, path, :delete), do: elem(pop_in(attrs, path), 1)
  defp invalid_registration(attrs, path, value), do: put_in(attrs, path, value)

  test "rejects malformed and incomplete registrations" do
    assert {:error, [%{path: "preregistration"}]} = Preregistration.prepare([], nil, nil, DateTime.utc_now())
    assert {:error, errors} = Preregistration.prepare(%{}, nil, nil, DateTime.utc_now())
    assert Enum.any?(errors, &(&1.path == "preregistration.planned_n_per_cohort"))
  end
end
