defmodule AiurWeb.Streamdeck.Deck.TicketsProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.BuildOrder.Index
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckLive.{Components, Surface}
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

    grid = AiurWeb.StreamdeckFleet.grid(%{})
    assert [%{id: "77", label: "Waiting for CI", pct: nil}] = grid.agents
    assert grid.total == 1
    assert grid.windows == 1
    assert grid.counts.live == 0
    assert_received :window_read
    refute_received :window_read
    html = render_component(&Components.grid_keys/1, grid: grid, grid_page: 0, grid_column_offset: 0, grid_dial_value: 0, selected_identifier: nil, keys: Surface.key_descriptors(grid.agents, 0))
    assert html =~ "Waiting for CI"
    refute html =~ ~s(role="progressbar")

    socket = joined_socket()
    assert_reply(push(socket, "input", %{"kind" => "key_press", "index" => 0}), :ok)
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "77"}]
    updated = put_in(window, [:sections, :now], [%{row | agent: %{state: "command"}, pct: 40}])
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, updated} end)
    Index.broadcast(%{})
    assert_push("fleet", %{"grid" => %{agents: [%{label: "Awaiting command", progress_percent: 40}]}}, 1_000)
  end

  test "Build facts win while control metadata and stale progress survive merging" do
    row = %{num: 77, id: "77", title: "Build title", sec: "now", agent: %{state: "retrying", model: "codex"}, pct: 40}
    window = %{sources: %{agents: %{state: "ok", observed_at: 123}}, sections: %{now: [row], plan: [], nq: []}}
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, window} end)
    snapshot = %{running: [%{identifier: "77", title: "Old title", work_state: :working, progress_percent: 30, progress_freshness: :stale, priority: 1}], retrying: [], idle: []}
    [key] = AiurWeb.StreamdeckFleet.grid(snapshot).agents
    assert key.title == "Build title"
    assert key.label == "Retrying"
    assert key.progress_percent == 40
    assert key.progress_freshness == "stale"
    assert key.bucket == :running
    assert key.priority == true
    [pause | _] = AiurWeb.StreamdeckLive.CommandKeys.command_keys(key, false)
    assert pause.label == "Pause"
    assert Render.key(key).label =~ "40% stale"

    stale = put_in(window, [:sources, :agents, :state], "stale")
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, stale} end)
    [key] = AiurWeb.StreamdeckFleet.grid(%{}).agents
    assert key.progress_freshness == "stale"
    assert key.bucket == :stuck

    for state <- ["retrying", "mystery"] do
      [key] = AiurWeb.Streamdeck.Deck.Tickets.keys(%{now: [%{row | agent: %{state: state}}]})
      [pause | _] = AiurWeb.StreamdeckLive.CommandKeys.command_keys(key, false)
      assert pause.label == "Pause"
    end
  end

  test "failed window publishes an unavailable empty ticket list rather than legacy running state" do
    for read <- [fn _, _, _ -> {:error, :offline} end, fn _, _, _ -> raise "offline" end, fn _, _, _ -> exit(:offline) end] do
      EndpointStubs.put(streamdeck_build_window_fun: read)
      grid = AiurWeb.StreamdeckFleet.grid(%{running: [%{identifier: "77", title: "Old running fact"}]})
      assert grid.agents == []
      assert grid.total == 0
      assert grid.tickets_status == "unavailable"
    end
  end
end
