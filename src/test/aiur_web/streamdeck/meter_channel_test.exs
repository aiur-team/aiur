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
    socket = joined_socket()

    assert %{"page" => 0, "frame" => %{keys: [first, second | empty], strip: strip}} = open_detail(socket)
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
    # The state call proves the flush completed before checking the transport mailbox.
    :sys.get_state(socket.channel_pid)
    assert_received %Message{event: "frame", payload: %{keys: [updated | _]}}
    assert updated.svg =~ "40% left"

    assert %{"page" => 1, "frame" => %{keys: [meter | _]}} = request(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert meter.svg =~ "claude usage"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == []
  end

  test "unavailable Fleet still exposes provider keys on their own page" do
    inputs = I.inputs(%{families: [:claude], accounts: %{"personal" => account(50, nil, DateTime.utc_now())}})

    put_endpoint_config(
      streamdeck_usage_load_fun: fn _, _ -> inputs end,
      streamdeck_build_window_fun: fn _, _, _ -> {:error, :offline} end
    )

    socket = joined_socket()
    assert %{"frame" => %{keys: [account | _]}} = open_detail(socket)
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

    socket = joined_socket()
    assert %{"focused" => "AIUR-1"} = request(socket, "focus", %{"identifier" => "AIUR-1"})
    assert %{"frame" => %{keys: [first | _]}} = open_detail(socket)
    assert first.label == "a01"
    assert %{"page" => 1, "frame" => %{keys: [last | empty]}} = request(socket, "input", %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert last.label == "a09"
    assert last.svg =~ "81% left"
    assert empty == List.duplicate(nil, 7)
    assert %{"page" => 1} = request(socket, "input", %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert %{reason: "disabled", frame: %{keys: [preserved | _]}} = request(socket, "priority", %{"identifier" => "AIUR-1", "direction" => "up"}, :error)
    assert preserved.label == "a09"
    assert preserved.svg =~ "81% left"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.stack == [{:meter_detail, "claude"}]
    assert %{"page" => 1, "frame" => %{keys: [meter | _]}} = request(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert meter.svg =~ "claude usage"
  end

  defp open_detail(socket) do
    for view <- ["feature", "epic", "fleet"] do
      assert %{"view" => ^view} = request(socket, "input", %{"kind" => "dial_press", "index" => 3})
    end

    assert %{"page" => 1, "frame" => %{keys: [meter | _]}} = request(socket, "input", %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert meter.svg =~ "claude usage"
    request(socket, "input", %{"kind" => "key_press", "index" => 0})
  end

  defp request(socket, event, payload, status \\ :ok) do
    ref = push(socket, event, payload)
    %Reply{payload: response} = receive_barrier(%Reply{ref: ^ref, status: ^status})
    response
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
