defmodule AiurWeb.Streamdeck.Deck.TicketsProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.BuildOrder.Index
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.Deck.Tickets
  alias AiurWeb.Streamdeck.FrameUpdates
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckFleet
  alias AiurWeb.StreamdeckLive.ImageComponents
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "shared Build window drives snapshot, emulator keys, raw key input and index refresh" do
    owner = self()
    row = %{num: 77, id: "77", title: "Shared CI ticket", sec: "now", agent: %{state: "ci_wait", model: "codex"}, pct: nil}
    window = %{sources: %{agents: %{state: "ok", observed_at: 123}}, sections: %{now: [row], plan: [], nq: []}}

    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        send(owner, :window_read)
        {:ok, window}
      end
    )

    grid = StreamdeckFleet.grid(%{})
    assert [%{id: "77", label: "Waiting for CI", pct: nil}] = grid.agents
    assert grid.total == 1
    assert grid.windows == 1
    assert grid.counts.live == 0
    assert_received :window_read
    refute_received :window_read
    {_nav, model, frame} = FrameUpdates.frame(%Nav{}, grid, %{})
    html = render_component(&ImageComponents.keys/1, frame: frame, model: model, grid: grid, page: 0, dial_value: 0, selected_identifier: nil, mode: :grid, logs: %{}, commands_view: :history)
    assert html =~ "Waiting for CI"
    refute html =~ ~s(data-part="progress-fill")

    socket = joined_socket()
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    state = :sys.get_state(socket.channel_pid)
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0, "chip_offset" => 0})
    assert state.assigns.deck_effects == [{:open_ticket, "77"}]
    updated = put_in(window, [:sections, :now], [%{row | agent: %{state: "command"}, pct: 40}])
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, updated} end)
    Index.broadcast(%{})
    receive_barrier(%Phoenix.Socket.Message{event: "fleet", payload: %{"grid" => %{agents: [%{label: "Awaiting command", progress_percent: 40}]}}})
  end

  test "Build facts win while control metadata and stale progress survive merging" do
    row = %{num: 77, id: "77", title: "Build title", sec: "now", agent: %{state: "retrying", model: "codex"}, pct: 40}
    window = %{sources: %{agents: %{state: "ok", observed_at: 123}}, sections: %{now: [row], plan: [], nq: []}}
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, window} end)
    snapshot = %{running: [%{identifier: "77", title: "Old title", work_state: :working, progress_percent: 30, progress_freshness: :stale, priority: 1}], retrying: [], idle: []}
    [key] = StreamdeckFleet.grid(snapshot).agents
    assert key.title == "Build title"
    assert key.label == "Retrying"
    assert key.progress_percent == 40
    assert key.progress_freshness == "stale"
    assert key.bucket == :running
    assert key.priority == true
    assert Render.key(key).label =~ "40% stale"

    stale = put_in(window, [:sources, :agents, :state], "stale")
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, stale} end)
    [key] = StreamdeckFleet.grid(%{}).agents
    assert key.progress_freshness == "stale"
    assert key.bucket == :stuck

    for state <- ["retrying", "mystery"] do
      [key] = Tickets.keys(%{now: [%{row | agent: %{state: state}}]})
      assert key.bucket == :stuck
    end
  end

  test "failed window publishes an unavailable empty ticket list rather than legacy running state" do
    for read <- [fn _, _, _ -> {:error, :offline} end, fn _, _, _ -> raise "offline" end, fn _, _, _ -> exit(:offline) end] do
      EndpointStubs.put(streamdeck_build_window_fun: read)
      grid = StreamdeckFleet.grid(%{running: [%{identifier: "77", title: "Old running fact"}]})
      assert grid.agents == []
      assert grid.total == 0
      assert grid.tickets_status == "unavailable"
      frame = Render.frame(%{grid: grid})
      [status | rest] = frame.keys
      assert status.svg =~ "Tickets unavailable"
      assert status.label =~ "Unavailable"
      refute status.svg =~ "progress-track"
      assert Enum.all?(rest, &is_nil/1)
      assert grid.counts.status == "unavailable"
      assert grid.counts.queued == nil
      assert grid.counts.not_queued == nil
      assert hd(frame.strip).label == "Build unavailable"
      assert Enum.at(frame.strip, 1).label == "Counts unavailable"
      assert List.last(frame.strip).label == "Queued unknown; Not queued unknown"
      refute List.last(frame.strip).svg =~ "Queued 0"
    end
  end
end
