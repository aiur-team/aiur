defmodule AiurWeb.StreamdeckLiveCountsTest do
  use AiurWeb.StreamdeckLiveCase
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.StreamdeckLive.Surface

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
    [summary | _] = Surface.screen_descriptors(grid, %{}, 0, nil)
    assert summary.live == 2
    assert summary.remaining == 5
    assert summary.counts_status == "stale"
    refute summary.observed?
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-segment="summary"] .sd-info-live[style="opacity: 0.5"]), "2 live · 5 left")
  end

  test "unknown counts display dashes and keep nil values" do
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end)
    grid = AiurWeb.StreamdeckFleet.grid(%{})
    [summary | _] = Surface.screen_descriptors(grid, %{}, 0, nil)
    assert summary.live == nil
    assert summary.remaining == nil
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-segment="summary"] .sd-info-live), "— live · — left")
  end
end
