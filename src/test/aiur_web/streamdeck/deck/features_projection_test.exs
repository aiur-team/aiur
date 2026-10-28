defmodule AiurWeb.Streamdeck.Deck.FeaturesProjectionTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.{FrameUpdates, Render}
  alias AiurWeb.StreamdeckProjection

  test "one Build read supplies feature facts and input pushes frames without reply images" do
    owner = self()
    put_window(window(), fn -> send(owner, :window_read) end)
    assert [%{"id" => "parent", "pct" => 60, "tickets" => [%{"id" => "88"}]}] = StreamdeckProjection.snapshot()["grid"]["features"]
    assert_received :window_read
    refute_received :window_read
    socket = joined_socket()
    :sys.get_state(socket.channel_pid)
    assert_push("frame", _initial)
    assert_reply(deck_input(socket, %{"kind" => "dial_press", "index" => 3}), :ok, reply)
    assert reply == %{"view" => "feature", "page" => 0}
    frame = flush_frame(socket)
    assert hd(frame.keys).svg =~ ">60%</text>"
    assert hd(frame.strip).svg =~ "age 2m"
    assert_reply(deck_input(socket, %{"kind" => "key_press", "index" => 0}), :ok, reply)
    refute Map.has_key?(reply, "frame")
    assert hd(flush_frame(socket).keys).label =~ "Member"
    assert_reply(deck_input(socket, %{"kind" => "key_press", "index" => 0}), :ok)
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "88"}]
    EndpointStubs.put(streamdeck_build_queue_fun: fn -> %{status: :disabled, queues: []} end)
    assert_reply(deck_input(socket, %{"kind" => "dial_turn", "index" => 1, "ticks" => -1}), :error, priority)
    assert priority == %{reason: "disabled"}
    frame = flush_frame(socket)
    assert hd(frame.keys).label =~ "Member"
    assert hd(frame.strip).label == "queue disabled"
    assert_reply(deck_input(socket, %{"kind" => "dial_long_press", "index" => 3}), :ok, reply)
    refute Map.has_key?(reply, "frame")
    assert hd(flush_frame(socket).keys).svg =~ ">60%</text>"
  end

  test "physical key positions drill into the feature displayed on that key" do
    window = window()

    window =
      Enum.reduce(2..3, window, fn n, window ->
        slug = "parent#{n}"
        lane = "lane#{n}"
        progress = %{window.feature_progress.features["lane"] | feature: slug, label: "Parent #{n}"}
        row = %{id: "#{n}", num: n, title: "Member #{n}", sec: "plan", epic: lane, qpos: n}

        window
        |> put_in([:features, slug], %{label: "Parent #{n}", epics: [lane]})
        |> put_in([:epics, lane], %{feature: slug})
        |> put_in([:feature_progress, :features, lane], progress)
        |> Map.update!(:order, &(&1 ++ [lane]))
        |> update_in([:sections, :plan], &(&1 ++ [row]))
      end)

    put_window(window)
    socket = joined_socket()
    :sys.get_state(socket.channel_pid)
    assert_push("frame", _initial)
    assert_reply(deck_input(socket, %{"kind" => "dial", "index" => 3, "action" => "press"}), :ok)
    frame = flush_frame(socket)
    assert Enum.at(frame.keys, 1).label =~ "Parent 3"
    assert Enum.at(frame.keys, 4).label =~ "Parent 2"
    assert_reply(deck_input(socket, %{"kind" => "key", "index" => 1, "action" => "down"}), :ok)
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:feature, "parent3"}]
    assert hd(flush_frame(socket).keys).label =~ "Member 3"
  end

  test "shared frame composition carries feature state for the browser renderer" do
    put_window(window())
    grid = StreamdeckProjection.grid()
    {nav, model, {faces, regions}} = FrameUpdates.frame(%Nav{view: :feature}, grid, %{}, &Render.compose/1)
    assert model.nav == nav
    assert hd(faces).kind == :feature
    assert hd(faces).pct == 60
    assert Render.key(hd(faces)).svg =~ ">60%</text>"
    assert hd(regions).label =~ "12/20 closed"
  end

  defp deck_input(socket, input) do
    ref = push(socket, "input", input)
    :sys.get_state(socket.channel_pid)
    ref
  end

  defp flush_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", frame)
    refute_received %Message{event: "frame"}
    frame
  end

  defp put_window(window, observed \\ fn -> :ok end) do
    EndpointStubs.put(
      streamdeck_build_window_fun: fn _, _, _ ->
        observed.()
        {:ok, window}
      end
    )
  end

  defp window do
    %{
      sources: %{agents: %{state: "ok"}},
      sections: %{
        now: [],
        plan: [
          %{id: "1", num: 1, title: "Outsider", sec: "plan", epic: "other", qpos: 0},
          %{id: "88", num: 88, title: "Member", sec: "plan", epic: "lane", qpos: 1}
        ],
        nq: []
      },
      order: ["lane"],
      epics: %{"lane" => %{feature: "parent"}},
      features: %{"parent" => %{label: "Parent", epics: ["lane"]}},
      feature_progress: %{
        observed_at: System.system_time(:millisecond) - 120_000,
        features: %{"lane" => %{feature: "parent", label: "Lane", closed: 12, open: 5, unpublished: 3, ci_wait: 0, total: 20}}
      }
    }
  end
end
