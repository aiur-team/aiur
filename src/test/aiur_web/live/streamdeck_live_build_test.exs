defmodule AiurWeb.StreamdeckLiveBuildTest do
  use AiurWeb.StreamdeckLiveCase

  alias Aiur.TestSupport.EndpointStubs

  test "renders build percent and bar and refreshes from both build topics" do
    {:ok, model} = Agent.start_link(fn -> queue_model(41) end)
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> Agent.get(model, & &1) end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-meter="build"][data-observed="true"] [aria-label="Build 41%"] i[style="width: 41%"]))

    for {topic, event, percent} <- [{"build_progress", :build_progress_changed, 62}, {"build_queue:changed", :build_queue_changed, 80}] do
      Agent.update(model, fn _ -> queue_model(percent) end)
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {event, %{}})
      assert render(view) =~ "Build #{percent}%"
    end
  end

  test "distinguishes no lane, unavailable read and unknown progress" do
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :running, queues: []} end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, ~s([data-meter="build"][data-observed="false"] [aria-label="No build order"]))
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :disabled} end)
    send(view.pid, {:build_queue_changed, :disabled})
    assert has_element?(view, ~s([data-meter="build"][data-observed="false"] [aria-label="Build unavailable"]))
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> queue_model(nil) end)
    send(view.pid, {:build_progress_changed, %{}})
    assert has_element?(view, ~s([data-meter="build"][data-observed="false"] [aria-label="Build progress unavailable"]))
  end

  defp queue_model(percent) do
    %{status: :running, queues: [%{queue_id: "q", set_rank: 1, name: "X", kind: :build_order, progress: %{completed: nil, resolved: 9, total: 22, percent: percent, resolution: :partial}}]}
  end
end
