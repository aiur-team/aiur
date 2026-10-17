defmodule Aiur.Experiments.ReportContractTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{ContractSchema, Evidence, ReportContract}
  @fixture Path.expand("../../fixtures/experiments/report.valid.json", __DIR__)

  setup do
    report = @fixture |> File.read!() |> Jason.decode!()
    registration = report["preregistration"]["record"]
    report = put_in(report, ["header", "preregistration_hash"], Evidence.hash(registration))

    context = %{
      experiment_id: "report-example",
      stats_snapshot_hash: "stats-fixture",
      preregistration: registration,
      events: %{"snapshot_hash" => "events-fixture", "events" => [%{"event_id" => "cap-1"}]},
      engine_labels: %{"delivery/start" => "inconclusive"}
    }

    context = Map.put(context, :engine_results, Map.new(report["results"], &{&1["metric"], &1}))
    %{report: report, context: context}
  end

  test "golden report validates against the runtime and published JSON schemas", %{report: report, context: context} do
    assert {:ok, ^report, []} = ReportContract.validate(report, context)

    for name <- ~w(report preregistration) do
      schema = Application.app_dir(:aiur, "priv/experiments/schema/#{name}.v1.json") |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
      value = if name == "report", do: report, else: context.preregistration
      assert :ok = ExJsonSchema.Validator.validate(schema, value)
      assert :ok = ContractSchema.validate(value, name)
    end
  end

  for {name, path, value, message} <- [
        {"upgraded labels", ["results", 0, "label"], "significant", "upgrades"},
        {"forged engine labels", ["results", 0, "engine_label"], "significant", "recomputed"},
        {"missing event ids", ["confounders"], [], "every event id"},
        {"bare summary verdicts", ["summary"], "The feature is significant.", "bare label"},
        {"stale stats", ["header", "stats_snapshot_hash"], "stale", "stale stats"},
        {"stale events", ["header", "events_snapshot_hash"], "stale", "stale events"},
        {"stale registration", ["header", "preregistration_hash"], "stale", "stale preregistration"},
        {"unknown labels", ["results", 0, "label"], "amazing", "enum"},
        {"downgrades without a reason", ["results", 0, "label"], "underpowered", "label_reason"},
        {"missing required sections", ["threats"], nil, "expected"},
        {"unlinked sensitivity", ["confounders", 0, "handling"], "sensitivity", "sensitivity_id"},
        {"primary role changes", ["results", 0, "role"], "exploratory", "primary role"}
      ] do
    @path path
    @value value
    @message message
    test "rejects #{name}", %{report: report, context: context} do
      assert {:error, errors} = ReportContract.validate(put_in(report, Enum.map(@path, fn key -> if is_integer(key), do: Access.at(key), else: key end), @value), context)
      assert Enum.any?(errors, &String.contains?(&1.message, @message))
    end
  end

  test "high noted confounders require a modifier and primary overall label", %{report: report, context: context} do
    report = put_in(report, ["confounders", Access.at(0), "severity"], "high")
    assert {:error, [%{message: "high/noted confounder requires confounded"}]} = ReportContract.validate(report, context)
    report = put_in(report, ["results", Access.at(0), "modifiers"], ["confounded"])
    assert {:error, [%{path: "labels"}]} = ReportContract.validate(report, context)
    report = Map.put(report, "labels", ["inconclusive", "confounded"])
    assert {:ok, ^report, []} = ReportContract.validate(report, context)
  end

  test "below planned n rewrites confirmatory to interim", %{report: report, context: context} do
    report = put_in(report, ["results", Access.at(0), "n", "after"], 39)
    context = put_in(context, [:engine_results, "delivery/start", "n", "after"], 39)
    assert {:ok, normalized, ["confirmatory rewritten to interim: below planned n"]} = ReportContract.validate(report, context)
    assert normalized["header"]["analysis_type"] == "interim"
  end

  test "matching a snapshot hash does not allow invented sample sizes or statistics", %{report: report, context: context} do
    for {key, value} <- [{"n", %{"before" => 400, "after" => 400}}, {"p", 0.001}, {"ci95", [-5, -1]}, {"power_at_mde", 0.99}] do
      forged = put_in(report, ["results", Access.at(0), key], value)
      assert {:error, [%{message: "numbers must match recomputed engine"}]} = ReportContract.validate(forged, context)
    end
  end

  test "confounder time can be an interval", %{report: report, context: context} do
    report = put_in(report, ["confounders", Access.at(0), "at"], ["2026-10-10T00:00:00Z", "2026-10-10T01:00:00Z"])
    assert {:ok, ^report, []} = ReportContract.validate(report, context)
  end

  test "secondary and guardrail roles cannot be changed by an author", %{report: report, context: context} do
    for {registered_role, forged_role, field} <- [{"secondary", "guardrail", "secondary_metrics"}, {"guardrail", "exploratory", "guardrail_metrics"}] do
      registration = Map.put(context.preregistration, field, [%{"id" => "delivery/other", "expected" => "decrease"}])
      engine_row = hd(report["results"]) |> Map.put("metric", "delivery/other") |> Map.put("role", registered_role)
      forged = Map.put(engine_row, "role", forged_role)

      context = %{
        context
        | preregistration: registration,
          engine_results: Map.put(context.engine_results, "delivery/other", engine_row),
          engine_labels: Map.put(context.engine_labels, "delivery/other", "inconclusive")
      }

      report = report |> put_in(["preregistration", "record"], registration) |> put_in(["header", "preregistration_hash"], Evidence.hash(registration)) |> Map.update!("results", &(&1 ++ [forged]))
      assert {:error, [%{message: "metric role must match preregistration"}]} = ReportContract.validate(report, context)
    end
  end

  test "downgrades with reasons and numeric verdict sentences are accepted", %{report: report, context: context} do
    report =
      report |> put_in(["results", Access.at(0), "label"], "underpowered") |> put_in(["results", Access.at(0), "label_reason"], "Power 0.65 below target 0.8") |> Map.put("labels", ["underpowered"])

    assert {:ok, ^report, []} = ReportContract.validate(report, context)
  end
end
