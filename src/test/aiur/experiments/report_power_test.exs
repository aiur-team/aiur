defmodule Aiur.Experiments.ReportPowerTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, ReportEngine}

  defp report_row(needed) do
    metric = %{
      "status" => "insufficient_data",
      "direction" => "no_change",
      "adjustment" => "holm",
      "groups" => %{"before" => %{"n" => 4}, "after" => %{"n" => 3}},
      "power" => %{"power_at_current_n" => 0.42, "mde_at_current_n" => 0.07, "samples_needed_per_group" => needed}
    }

    body = %{"experiment_id" => "power-report", "metrics" => %{"pack/latency" => metric}}
    registration = %{"primary_metrics" => [%{"id" => "pack/latency"}], "secondary_metrics" => [], "guardrail_metrics" => []}
    catalog = %{metrics: %{"pack/latency" => %Metric{unit: "ms"}}}
    ReportEngine.context(body, registration, %{}, catalog).engine_results["pack/latency"]
  end

  test "report rows carry nested estimates and preserve unbounded requirements" do
    row = report_row(67)
    assert row["power_at_mde"] == 0.42
    assert row["mde_at_n"] == 0.07
    assert row["n_needed_per_cohort"] == 67
    assert report_row("> 5000")["n_needed_per_cohort"] == nil
  end
end
