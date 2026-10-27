defmodule AiurWeb.Experiments.MetricsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Experiments.Metrics

  test "AE1 shows n 4/10 and suppresses inference while retaining descriptives" do
    [row] = rows("analysis")
    assert row.sample == "n 4/10"
    assert row.guarded?
    assert row.interval == "not enough data (n 4 of 10)"
    assert row.p == row.interval
    assert row.effect == row.interval
    assert row.change == "Change unavailable"
    assert Enum.map(row.groups, & &1.n) == [12, 4]
    assert hd(row.groups).center == "100.06"
    assert row.labels == ["analyst: confounded — Release overlap"]
  end

  test "custom pack label and signed relative change use stored effects" do
    result = %{
      "kind" => "duration",
      "status" => "inconclusive",
      "direction" => "improved",
      "adjustment" => "holm",
      "primary_effect" => "median_ratio",
      "groups" => %{"before" => %{"n" => 20}, "after" => %{"n" => 20}},
      "effects" => %{"median_ratio" => %{"estimate" => 0.88}, "median_difference" => %{"estimate" => -12, "lo" => -20, "hi" => -5}},
      "p_raw" => 0.01,
      "p_adj" => 0.03,
      "tests" => %{"mann_whitney" => %{}},
      "analyst_flags" => []
    }

    [row] = custom(result)
    assert row.label == "Checkout latency"
    assert row.unit == "ms"
    assert row.change == "-12%"
    assert row.direction == "✓ in expected direction"
    assert row.interval == "-20 to -5"
    assert row.p == "0.01 (holm: 0.03)"
    assert row.tests == "mann_whitney"
    [tiny] = custom(Map.put(result, "p_raw", 0.000001))
    assert tiny.p == "1.00e-06 (holm: 0.03)"
  end

  test "real binary engine output preserves its proportion interval" do
    [row] = rows("binary")
    assert row.contrast == "proportion_difference: 0.5"
    assert row.interval == "0.21 to 0.7"
    assert row.tests == "fisher"
    refute row.guarded?
  end

  test "real rate engine output preserves its ratio interval and rate summary" do
    [row] = rows("rate")
    assert row.contrast == "rate_ratio: 2.5"
    assert row.interval == "1.05 to 6.56"
    assert hd(row.groups).center_label == "rate"
    assert hd(row.groups).center == "0.08"
    assert row.tests == "conditional_poisson"
  end

  test "unknown evidence stays unavailable rather than becoming zero" do
    body = fixture("rate")
    body = put_in(body, ["metrics", "custom/rate", "effects", "rate_ratio", "estimate"], nil)
    [row] = format(body)
    assert row.effect == "rate_ratio: Unavailable"
    assert row.change == "Change unavailable"
    assert Metrics.rows(%{}, nil, %{}) == []
  end

  test "generated copy has no bare verdict words" do
    for name <- ~w(analysis binary rate), row <- rows(name) do
      copy = Enum.join([row.direction, row.change, row.effect, row.interval], " ")
      refute copy =~ ~r/\b(?:win|better|worse|regress\w*|improv\w*)\b/i
    end
  end

  defp rows(name), do: name |> fixture() |> format()
  defp fixture(name), do: Path.expand("../../aiur/experiments/fixtures/results/page_#{name}.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
  defp format(body), do: Metrics.rows(%{"metrics" => Enum.map(Map.keys(body["metrics"]), &%{"ref" => &1})}, body, %{})

  defp custom(result),
    do:
      Metrics.rows(%{"metrics" => [%{"ref" => "custom/latency"}]}, %{"metrics" => %{"custom/latency" => result}, "group_order" => ["before", "after"], "defaults" => %{"min_samples" => 10}}, %{
        "custom/latency" => %{label: "Checkout latency", unit: "ms"}
      })
end
