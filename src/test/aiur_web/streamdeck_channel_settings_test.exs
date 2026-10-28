defmodule AiurWeb.StreamdeckChannelSettingsTest do
  use AiurWeb.StreamdeckChannelCase
  alias AiurWeb.Streamdeck.Deck.{Settings, SettingsSnapshot}

  setup do
    root = Path.join(System.tmp_dir!(), "deck-channel-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    put_endpoint_config(streamdeck_settings_path: path)
    %{path: path}
  end

  test "section keys and dial choice save a mic and reconnect reads it back", %{path: path} do
    socket = settings_socket()
    input(socket, "devices", inventory())
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    frame = pushed_frame(socket)
    assert Enum.map(frame.keys, & &1.label) |> Enum.join(" ") =~ "Brightness"
    refute Enum.any?(frame.keys, &String.contains?(&1.label, "TestMic"))
    input(socket, "input", %{"kind" => "key_press", "index" => 0})
    input(socket, "input", %{"kind" => "dial_turn", "index" => 0, "ticks" => 1})
    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket", "page" => 0} = navigation, 1_000)
    assert Map.keys(navigation) |> Enum.sort() == ["page", "view"]
    assert Enum.any?(pushed_frame(socket).keys, &(&1 && &1.label == "Second · Selected"))
    assert {:ok, saved} = Settings.read(path)
    assert saved["mic_id"] == "second"
    second = settings_socket()
    join_ref = second.join_ref
    assert_receive %Message{event: "settings", join_ref: ^join_ref, payload: %{"mic_id" => "second"}}, 1_500
  end

  test "legacy migration is once and settings pushes apply persisted view", %{path: path} do
    socket = settings_socket()
    input(socket, "devices", Map.put(inventory(), "legacy_mic_id", "old-mic"))
    assert {:ok, saved} = Settings.read(path)
    assert saved["mic_id"] == "old-mic"
    ref = push(socket, "settings_set", %{"mic_id" => "second", "default_view" => "epic", "brightness" => 30})
    assert_reply(ref, :ok, %{"mic_id" => "second", "brightness" => 30}, 1_000)
    input(socket, "devices", Map.put(inventory(), "legacy_mic_id", "old-mic"))
    assert SettingsSnapshot.read(path).settings["mic_id"] == "second"
    second = settings_socket()
    assert :sys.get_state(second.channel_pid).assigns.deck_nav.view == :epic
  end

  test "malformed device inventory cannot mutate settings", %{path: path} do
    socket = settings_socket()
    ref = push(socket, "devices", %{"mics" => [%{"id" => 123}], "speakers" => []})
    assert_reply(ref, :error, %{reason: "invalid_devices"}, 1_000)
    ref = push(socket, "settings_set", %{"brightness" => "full"})
    assert_reply(ref, :error, %{reason: "not_saved"}, 1_000)
    assert hd(pushed_frame(socket).strip).label == "Not saved"
    assert SettingsSnapshot.read(path).settings["brightness"] == nil
  end

  test "a real failed write leaves the file and applied settings unchanged and renders not saved", %{path: path} do
    assert {:ok, _settings} = Settings.set(%{"brightness" => 70}, path)
    original = File.read!(path)
    socket = settings_socket()
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    File.chmod!(Path.dirname(path), 0o500)

    try do
      ref = push(socket, "settings_set", %{"brightness" => 30})
      assert_reply(ref, :error, %{reason: "not_saved"}, 1_000)
      assert File.read!(path) == original
      assert SettingsSnapshot.read(path).settings["brightness"] == 70
      frame = pushed_frame(socket)
      assert hd(frame.strip).label =~ "Not saved"
      assert hd(frame.strip).svg =~ "Not saved"
      assert Enum.any?(frame.keys, &(&1.label == "Brightness · 70%"))
    after
      File.chmod!(Path.dirname(path), 0o700)
    end
  end

  test "sort setting changes rendered ticket order and presses resolve against that order" do
    snapshot = %{running: [AgentEvents.agent_summary("AIUR-1", :running, 0, %{title: "Zulu"}), AgentEvents.agent_summary("AIUR-2", :running, 0, %{title: "Alpha"})], retrying: [], idle: []}

    put_endpoint_config(
      streamdeck_build_queue_fun: fn -> %{status: :disabled} end,
      streamdeck_snapshot_fun: fn -> snapshot end,
      streamdeck_build_window_fun: fn _, _, _ -> Aiur.TestSupport.StreamdeckBuildFixture.window(snapshot) end
    )

    socket = settings_socket()
    input(socket, "settings_set", %{"default_sort" => "title"})
    assert hd(pushed_frame(socket).keys).label =~ "AIUR-2"
    input(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "AIUR-2"}]
  end

  test "hold dial four backs out of choices then returns to the prior view" do
    socket = settings_socket()
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    input(socket, "input", %{"kind" => "key_press", "index" => 4})
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.settings.section == "brightness"
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert Enum.any?(pushed_frame(socket).keys, &(&1.label =~ "Brightness"))
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.settings.section == nil
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.surface == :grid
    assert hd(pushed_frame(socket).keys).label =~ "AIUR-1"
  end

  test "device removal clamps choice paging so missing selection remains visible" do
    socket = settings_socket()
    inventory = %{inventory() | "mics" => Enum.map(1..20, &%{"id" => "mic-#{&1}", "label" => "Microphone #{&1}"})}
    input(socket, "devices", inventory)
    input(socket, "settings_set", %{"mic_id" => "mic-20"})
    for event <- [%{"kind" => "dial_long_press", "index" => 3}, %{"kind" => "key_press", "index" => 0}, %{"kind" => "dial_turn", "index" => 0, "ticks" => 19}], do: input(socket, "input", event)
    input(socket, "devices", %{inventory | "mics" => [%{"id" => "first", "label" => "First"}]})
    frame = pushed_frame(socket)
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.settings.cursor == 1
    assert hd(frame.keys).label == "missing: mic-20 · Selected"
    assert hd(frame.keys).svg =~ ">missing:"
  end

  test "ticket key input focuses the agent and starts its transcript relay" do
    socket = settings_socket()
    input(socket, "input", %{"kind" => "key_press", "index" => 0})
    state = :sys.get_state(socket.channel_pid)
    assert state.assigns.focused_agent == "AIUR-1"
    assert is_pid(state.assigns.transcript_relay)
    assert Process.alive?(state.assigns.transcript_relay)
    input(socket, "input", %{"kind" => "key", "index" => 0, "action" => "up"})
    assert :sys.get_state(socket.channel_pid).assigns.focus_token == state.assigns.focus_token
  end

  test "voice status is rendered on the strip and oversized status is refused" do
    socket = settings_socket()
    input(socket, "voice_status", %{"text" => "Listening"})
    region = hd(pushed_frame(socket).strip)
    assert region.label == "Listening"
    assert region.svg =~ ">Listening<"
    ref = push(socket, "voice_status", %{"text" => String.duplicate("x", 201)})
    assert_reply(ref, :error, %{reason: "invalid_status"}, 1_000)
  end

  test "unknown inventory stays unavailable until observed, with coalesced pushed frames" do
    socket = settings_socket()
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    frame = pushed_frame(socket)
    assert hd(frame.keys).label == "Mic · Unavailable"
    input(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert hd(pushed_frame(socket).strip).label =~ "Unavailable"
    for percent <- [10, 20, 30], do: input(socket, "settings_set", %{"brightness" => percent})
    input(socket, "devices", inventory())
    input(socket, "voice_status", %{"text" => "Ready"})
    state = :sys.get_state(socket.channel_pid)
    assert is_reference(state.assigns.fleet_flush)
    frame = pushed_frame(socket)
    assert hd(frame.strip).label =~ "Ready"
    refute_received %Message{event: "frame"}
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    input(socket, "devices", Map.delete(inventory(), "instances"))
    assert Enum.any?(pushed_frame(socket).keys, &(&1.label == "Instance · Unavailable"))
  end

  test "explicit instance choices push new selection metadata without changing navigation replies" do
    socket = settings_socket()
    join_ref = socket.join_ref
    assert_receive %Message{event: "settings", join_ref: ^join_ref, payload: initial}, 1_500
    refute Map.has_key?(initial, "instance_selection_id")
    input(socket, "settings_set", %{"instance" => "local"})
    assert_push("settings", %{"instance" => "local", "instance_selection_id" => first}, 1_500)
    assert is_binary(first)
    assert first != ""
    input(socket, "settings_set", %{"instance" => "local"})
    assert_receive %Message{event: "settings", join_ref: ^join_ref, payload: %{"instance" => "local", "instance_selection_id" => second}} when second != first, 1_500
    refute second == ""
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert Enum.any?(pushed_frame(socket).keys, &String.starts_with?(&1.label, "Instance ·"))
  end

  defp settings_socket do
    socket = joined_socket()
    assert_push("frame", _frame, 1_500)
    socket
  end

  defp input(socket, event, payload) do
    ref = push(socket, event, payload)
    assert_reply(ref, :ok, _reply, 1_500)
  end

  defp pushed_frame(socket) do
    state = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, {:flush_fleet, state.assigns.fleet_flush})
    :sys.get_state(socket.channel_pid)
    assert_push("frame", frame, 1_500)
    refute_received %Message{event: "frame"}
    frame
  end

  defp inventory, do: %{"mics" => [%{"id" => "first", "label" => "First"}, %{"id" => "second", "label" => "Second"}], "speakers" => [], "instances" => ["pc"]}
end
