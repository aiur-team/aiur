defmodule AiurWeb.OperatorControlCenter.Analytics.ProjectedSeriesTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.SummaryReader
  alias AiurWeb.OperatorControlCenter.Analytics.{Presenter, ProjectedSeries}

  test "a continuously busy retained actor does not acquire idle zeros when its observations are sampled" do
    samples =
      for i <- 0..5999,
          do: %{
            "cpu_percent" => 100.0,
            "rss_bytes" => 1000,
            timestamp_ms: i * 5000,
            availability: "measured",
            actor_type: "agent",
            boot_id: "boot",
            record_id: "boot:#{i}"
          }

    actor = %{samples: SummaryReader.sample(samples), profile: %{"cpu_percent" => %{count: 6000, mean: 100.0, max: 100.0}}}
    model = Presenter.model(%{actors: %{"ticket:7" => actor}, tickets: %{}, records: [], provenance: %{time_range: %{}}}, cores: 1, cap: 1, range: :full)
    assert length(model.series) == 180
    assert Enum.all?(model.series, &(&1.total_cpu == 100.0 and &1.total_mem == 1000))
    assert model.kpis.cpu_hours == 8.3
  end

  test "sample coverage does not fill outages, unavailable observations, or boot boundaries" do
    samples =
      for i <- 0..1999 do
        %{timestamp_ms: i * 5000 + if(i >= 500, do: 1_000_000, else: 0), availability: if(i == 999, do: "unavailable", else: "measured"), boot_id: if(i >= 1500, do: "second", else: "first")}
      end

    projected = SummaryReader.sample(samples)
    bucket = fn timestamp -> div(timestamp, 5000) end
    cells = projected |> Enum.filter(&(&1.availability == "measured")) |> Map.new(&{bucket.(&1.timestamp_ms), 100})
    filled = ProjectedSeries.fill(cells, projected, bucket)
    refute Map.has_key?(filled, 600)
    refute Map.has_key?(filled, 1199)

    assert Enum.all?(projected, fn sample ->
             finish = Map.get(sample, :covered_until_ms, sample.timestamp_ms)
             not (sample.boot_id == "first" and finish >= 8_500_000)
           end)

    assert filled[0] == 100
    assert filled[bucket.(List.last(samples).timestamp_ms)] == 100
  end
end
