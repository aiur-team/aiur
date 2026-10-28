defmodule AiurWeb.StreamdeckLiveCountsTest do
  use AiurWeb.StreamdeckLiveCase
  alias Aiur.TestSupport.EndpointStubs

  test "emulator renders Build counts and dims stale observations" do
    window = %{
      sources: %{agents: %{state: "stale", observed_at: 123}},
      sections: %{
        now: [%{num: 1, sec: "now", agent: %{state: "active"}}, %{num: 2, sec: "now", agent: %{state: "active"}}, %{num: 3, sec: "now", agent: %{state: "ci_wait"}}],
        plan: Enum.map(10..14, &%{num: &1, sec: "plan"}),
        nq: []
      }
    }

    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, window} end)
    grid = AiurWeb.StreamdeckFleet.grid(%{})
    assert grid.counts.live == 2
    assert grid.counts.queued == 5
    assert grid.counts.status == "stale"
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-streamdeck-region="0"]), "2 live / 5 left stale")
  end

  test "unknown counts display dashes and keep nil values" do
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end)
    grid = AiurWeb.StreamdeckFleet.grid(%{})
    assert grid.counts.live == nil
    assert grid.counts.queued == nil
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-streamdeck-region="0"]), "— live / — left")
  end
end
