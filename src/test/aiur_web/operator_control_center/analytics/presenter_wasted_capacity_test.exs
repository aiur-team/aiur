defmodule AiurWeb.OperatorControlCenter.Analytics.PresenterWastedCapacityTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @t0 1_000_000

  defp dataset(samples) do
    agents =
      for key <- ["ticket:1", "ticket:2"], into: %{} do
        {key,
         %{
           samples:
             Enum.map(0..10, fn index ->
               %{
                 "cpu_percent" => 50.0,
                 "rss_bytes" => 100_000,
                 actor: key,
                 actor_type: "agent",
                 timestamp_ms: @t0 + index * 60_000,
                 availability: "measured"
               }
             end),
           profile: %{}
         }}
      end

    %{
      actors: Map.merge(agents, %{"_daemon" => %{samples: samples, profile: %{}}}),
      tickets: %{
        "1" => %{
          intervals: [%{phase: "implement", status: "measured", start_ms: @t0, end_ms: @t0 + 570_000}]
        }
      },
      provenance: %{}
    }
  end

  defp capacity_samples(missing_index \\ nil) do
    for index <- 0..10 do
      %{
        "fleet_agents_occupied" => 2,
        "fleet_agents_configured" => 16,
        "fleet_agents_max" => 16,
        "fleet_agents_effective" => if(index == missing_index, do: nil, else: if(index < 5, do: 13, else: 8)),
        "build_gate_active" => 2,
        "build_gate_queued" => 0,
        "build_queue_oldest_wait_seconds" => 0,
        actor: "_daemon",
        actor_type: "daemon",
        timestamp_ms: @t0 + index * 60_000,
        availability: "measured",
        fleet_capacity_status: "current",
        build_gate_status: "measured"
      }
    end
  end

  defp wasted(samples, cap) do
    dataset = Presenter.model(dataset(samples), cap: cap, cores: 4, host_mem_bytes: 1_000_000_000, buckets: 10)
    dataset.kpis
  end

  test "uses each bucket's recorded cap independent of the final cap" do
    cap_8 = wasted(capacity_samples(), 8)
    cap_13 = wasted(capacity_samples(), 13)

    assert cap_8.wasted_slot_hours == 1.4
    assert cap_13.wasted_slot_hours == 1.4
    assert cap_8.wasted_slot_hours_partial == false
    assert cap_13.wasted_slot_hours_partial == false
  end

  test "omits missing cap buckets and marks the total partial" do
    cap_8 = wasted(capacity_samples(2), 8)
    cap_13 = wasted(capacity_samples(2), 13)

    assert cap_8.wasted_slot_hours == 1.2
    assert cap_13.wasted_slot_hours == 1.2
    assert cap_8.wasted_slot_hours_partial == true
    assert cap_13.wasted_slot_hours_partial == true
  end
end
