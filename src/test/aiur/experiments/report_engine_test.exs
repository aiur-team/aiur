defmodule Aiur.Experiments.ReportEngineTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, ReportEngine}

  test "registered expectations and secondary FDR override original metric settings" do
    input = %{"spec" => %{"metrics" => [%{"ref" => "pack/primary", "direction" => "decrease"}, %{"ref" => "pack/secondary", "direction" => "increase"}]}}

    registration = %{
      "primary_metrics" => [%{"id" => "pack/primary", "expected" => "increase"}],
      "secondary_metrics" => [%{"id" => "pack/secondary", "expected" => "no-change"}],
      "guardrail_metrics" => [],
      "mde" => %{"metric" => "pack/primary", "relative" => -0.3},
      "alpha" => 0.05,
      "fdr_q" => 0.1,
      "power_target" => 0.8
    }

    catalog = %{metrics: %{"pack/primary" => %Metric{kind: "duration"}, "pack/secondary" => %Metric{kind: "binary"}}}
    spec = ReportEngine.spec(input, registration, catalog)
    assert spec["fdr_q"] == 0.1
    assert spec["alpha"] == 0.05
    assert [%{"direction" => "increase", "mde" => 0.3}, %{"direction" => "none", "mde" => 0.2}] = spec["metrics"]
  end
end
