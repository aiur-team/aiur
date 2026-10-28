defmodule AiurWeb.StreamdeckLiveCountsTest do
  use AiurWeb.StreamdeckLiveCase
  alias Aiur.TestSupport.EndpointStubs

  test "emulator renders Build counts and dims stale observations" do
    window = %{
      sources: %{agents: %{state: "stale", observed_at: 123}},
      sections: %{
        now: [
          %{agent: %{state: "active"}},
          %{agent: %{state: "active"}},
          %{agent: %{state: "ci_wait"}}
        ],
        plan: List.duplicate(%{}, 5),
        nq: []
      }
    }

    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, window} end)
    grid = AiurWeb.StreamdeckFleet.grid(%{})
    assert grid.counts.live == 2
    assert grid.counts.queued == 5
    assert grid.counts.status == "stale"
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-streamdeck-region="200"] [data-status="stale"][opacity="0.45"]))
    assert has_element?(view, ~s([data-streamdeck-region="200"]), "Running 2")
    assert has_element?(view, ~s([data-streamdeck-region="600"]), "Queued 5")
  end

  test "unknown counts display unavailable and keep nil values" do
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end)
    grid = AiurWeb.StreamdeckFleet.grid(%{})
    assert grid.counts.live == nil
    assert grid.counts.queued == nil
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-streamdeck-region="200"]), "Counts unavailable")
    assert has_element?(view, ~s([data-streamdeck-region="600"]), "Queued unknown")
    refute has_element?(view, ~s([data-streamdeck-region="600"]), "Queued 0")
  end
end
