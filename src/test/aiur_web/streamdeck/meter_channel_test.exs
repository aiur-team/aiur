defmodule AiurWeb.Streamdeck.MeterChannelTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I

  test "real Fleet paging opens two account images, refreshes usage and hold returns to provider keys" do
    now = DateTime.utc_now()
    personal = account(50, 30, now)
    work = account(88, nil, now) |> Map.put(:freshness, :stale)
    inputs = I.inputs(%{families: [:claude], meters: %{claude: I.snapshot(:claude, %{"primary" => I.window(50)}, %{observed_at: now})}, accounts: %{"work" => work, "personal" => personal}})
    source = start_supervised!({Agent, fn -> inputs end})
    put_endpoint_config(streamdeck_usage_load_fun: fn _, _ -> Agent.get(source, & &1) end)
    socket = joined_socket()

    for view <- ["feature", "epic", "fleet"] do
      ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
      assert_reply(ref, :ok, %{"view" => ^view})
    end

    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert_reply(ref, :ok, %{"page" => 1, "frame" => %{keys: [meter | _]}})
    assert meter.svg =~ "claude usage"
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"page" => 0, "frame" => %{keys: [first, second | empty], strip: strip}})
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
    assert_push("frame", %{keys: [updated | _]}, 1_500)
    assert updated.svg =~ "40% left"

    ref = push(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_reply(ref, :ok, %{"page" => 1, "frame" => %{keys: [meter | _]}})
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

    for _ <- 1..3 do
      ref = push(socket, "input", %{"kind" => "dial_press", "index" => 3})
      assert_reply(ref, :ok, %{"view" => view})
      assert view in ["feature", "epic", "fleet"]
    end

    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 3, "ticks" => 1})
    assert_reply(ref, :ok, %{"page" => 1, "frame" => %{keys: [meter | _]}})
    assert meter.svg =~ "claude usage"
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"frame" => %{keys: [account | _]}})
    assert account.label == "personal"
    assert account.svg =~ "50% left"
  end

  defp account(session, weekly, now) do
    entry = I.account(session, weekly) |> Map.put(:observed_at, now)
    update_in(entry, [:reading, :windows], &Enum.map(&1, fn window -> %{window | resets_at: DateTime.add(now, 7200)} end))
  end
end
