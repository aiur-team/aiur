defmodule AiurWeb.Streamdeck.MeterChannelTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias Phoenix.Socket.Reply

  test "real Fleet paging opens two account images, refreshes usage and hold returns to provider keys" do
    now = DateTime.utc_now()
    personal = account(50, 30, now)
    work = account(88, nil, now) |> Map.put(:freshness, :stale)
    inputs = inputs(%{"work" => work, "personal" => personal}, now)
    source = start_supervised!({Agent, fn -> inputs end})
    put_endpoint_config(streamdeck_usage_load_fun: fn _, _ -> Agent.get(source, & &1) end)
    socket = meter_socket()

    assert %{"page" => 0, :frame => %{keys: [first, second | empty], strip: strip}} = open_detail(socket)
    assert first.label == "personal"
    assert first.svg =~ "50% left"
    assert second.label == "work stale"
    assert second.svg =~ "12% left"
    assert second.svg =~ "unknown-hatch"
    assert empty == List.duplicate(nil, 6)
    assert hd(strip).label =~ "claude"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:meter_detail, "claude"}]

    Agent.update(source, &put_in(&1, [:accounts, "personal", :reading, :windows, Access.at(0), :used_percent], 60))
    send(socket.channel_pid, {:provider_meter_changed, inputs.meters.claude})
    token = :sys.get_state(socket.channel_pid).assigns.usage_flush
    if is_reference(token), do: send(socket.channel_pid, {:flush_usage, token})
    %{keys: [updated | _]} = flush_frame(socket)
    assert updated.svg =~ "40% left"

    assert %{"page" => 1, :frame => %{keys: [meter | _]}} = input_frame(socket, %{"kind" => "dial_long_press", "index" => 3})
    assert meter.svg =~ "claude usage"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == []
  end

  test "unavailable Fleet still exposes provider keys on their own page" do
    inputs = I.inputs(%{families: [:claude], accounts: %{"personal" => account(50, nil, DateTime.utc_now())}})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn _, _ -> inputs end,
      streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end
    )

    socket = meter_socket()
    assert %{:frame => %{keys: [account | _]}} = open_detail(socket)
    assert account.label == "personal"
    assert account.svg =~ "50% left"
  end

  test "priority replies preserve the second account page without closing detail" do
    now = DateTime.utc_now()
    accounts = Map.new(1..9, fn index -> {"a#{String.pad_leading(to_string(index), 2, "0")}", account(10 + index, 30, now)} end)
    inputs = inputs(accounts, now)

    put_endpoint_config(
      dashboard_writable: true,
      streamdeck_usage_load_fun: fn _, _ -> inputs end,
      streamdeck_build_queue_fun: fn -> %{status: :disabled, queues: []} end
    )

    socket = meter_socket()
    assert %{"focused" => "AIUR-1"} = request(socket, "focus", %{"identifier" => "AIUR-1"})
    assert %{:frame => %{keys: [first | _]}} = open_detail(socket)
    assert first.label == "a01"
    assert %{"page" => 1, :frame => %{keys: [last | empty]}} = input_frame(socket, %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert last.label == "a09"
    assert last.svg =~ "81% left"
    assert empty == List.duplicate(nil, 7)
    assert %{"page" => 1} = input_frame(socket, %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert %{reason: "disabled"} = reply = request(socket, "priority", %{"identifier" => "AIUR-1", "direction" => "up"}, :error)
    refute Map.has_key?(reply, :frame)
    %{keys: [preserved | _]} = flush_frame(socket)
    assert preserved.label == "a09"
    assert preserved.svg =~ "81% left"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:meter_detail, "claude"}]
    assert %{"page" => 1, :frame => %{keys: [meter | _]}} = input_frame(socket, %{"kind" => "dial_long_press", "index" => 3})
    assert meter.svg =~ "claude usage"
  end

  test "unavailable Fleet stays explicit when a category drill loses its source" do
    data = %{
      sources: %{agents: %{state: "ok"}},
      sections: %{now: [%{num: 17, id: "17", sec: "now", title: "CI source", agent: %{state: "ci_wait"}}], plan: [], nq: []},
      capacity: %{max: 4, stale: false},
      daemon: %{state: "live", heartbeat_at: System.system_time(:millisecond)}
    }

    window = start_supervised!({Agent, fn -> {:ok, data} end})
    put_endpoint_config(streamdeck_build_window_fun: fn _, _, _ -> Agent.get(window, & &1) end)
    socket = meter_socket()
    open_fleet(socket)
    assert %{:frame => %{keys: [ci | _]}} = input_frame(socket, %{"kind" => "key_press", "index" => 3})
    assert ci.svg =~ "CI source"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:fleet, "ci_wait"}]
    Agent.update(window, fn _ -> {:error, :offline} end)
    send(socket.channel_pid, :fleet_changed)
    :sys.get_state(socket.channel_pid)
    flush_frame(socket)
    assert %{:frame => %{keys: [unavailable | _]}} = input_frame(socket, %{"kind" => "dial_turn", "index" => 0, "ticks" => 1})
    assert :sys.get_state(socket.channel_pid).assigns.deck_grid.fleet.status == "unavailable"
    assert unavailable.svg =~ "Fleet unavailable"
  end

  test "physical inputs open account detail and return through the shared frame pipeline" do
    now = DateTime.utc_now()
    put_endpoint_config(streamdeck_usage_load_fun: fn _, _ -> inputs(%{"personal" => account(37, nil, now)}, now) end)
    socket = meter_socket()

    for view <- ["feature", "epic", "fleet"] do
      assert %{"view" => ^view} = input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "press"})
    end

    assert %{"page" => 1} = input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})
    assert %{:frame => %{keys: [account | _]}} = input_frame(socket, %{"kind" => "key", "index" => 0, "action" => "down"})
    assert account.label == "personal"
    assert account.svg =~ "63% left"
    assert account.svg =~ "unknown-hatch"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:meter_detail, "claude"}]
    assert %{"page" => 1, :frame => %{keys: [meter | _]}} = input_frame(socket, %{"kind" => "dial", "index" => 3, "action" => "long_press"})
    assert meter.svg =~ "claude usage"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == []
  end

  test "input replies contain navigation only and cached provider usage is not reloaded" do
    now = DateTime.utc_now()
    inputs = inputs(%{"personal" => account(37, nil, now)}, now)
    calls = start_supervised!({Agent, fn -> 0 end})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn _, _ ->
        Agent.update(calls, &(&1 + 1))
        inputs
      end
    )

    socket = meter_socket()
    before = Agent.get(calls, & &1)
    open_fleet(socket)
    input_frame(socket, %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert Agent.get(calls, & &1) == before
    input_frame(socket, %{"kind" => "key_press", "index" => 0})
    assert Agent.get(calls, & &1) == before + 1
  end

  defp open_detail(socket) do
    open_fleet(socket)

    assert %{"page" => 1, :frame => %{keys: [meter | _]}} = input_frame(socket, %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert meter.svg =~ "claude usage"
    input_frame(socket, %{"kind" => "key_press", "index" => 0})
  end

  defp open_fleet(socket) do
    for view <- ["feature", "epic", "fleet"] do
      assert %{"view" => ^view} = input_frame(socket, %{"kind" => "dial_press", "index" => 3})
    end
  end

  defp request(socket, event, payload, status \\ :ok) do
    ref = push(socket, event, payload)
    %Reply{payload: response} = receive_barrier(%Reply{ref: ^ref, status: ^status})
    response
  end

  defp input_frame(socket, payload) do
    reply = request(socket, "input", payload)
    refute Map.has_key?(reply, "frame")
    Map.put(reply, :frame, flush_frame(socket))
  end

  defp meter_socket do
    socket = joined_socket()
    receive_barrier(%Message{event: "frame"})
    socket
  end

  defp flush_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    if is_reference(state.assigns.fleet_flush), do: send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    %Message{payload: frame} = receive_barrier(%Message{event: "frame"})
    frame
  end

  defp inputs(accounts, now) do
    primary = I.window(50) |> Map.put(:resets_at, DateTime.add(now, 3600))
    I.inputs(%{families: [:claude], meters: %{claude: I.snapshot(:claude, %{"primary" => primary}, %{observed_at: now})}, accounts: accounts})
  end

  defp account(session, weekly, now) do
    entry = I.account(session, weekly) |> Map.put(:observed_at, now)
    update_in(entry, [:reading, :windows], &Enum.map(&1, fn window -> %{window | resets_at: DateTime.add(now, 7200)} end))
  end
end
