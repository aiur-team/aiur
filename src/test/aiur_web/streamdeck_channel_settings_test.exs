defmodule AiurWeb.StreamdeckChannelSettingsTest do
  use AiurWeb.StreamdeckChannelCase
  alias AiurWeb.Streamdeck.Deck.Settings
  alias AiurWeb.Streamdeck.FrameUpdates
  @moduletag timeout: 15_000

  setup do
    root = Path.join(System.tmp_dir!(), "deck-channel-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    put_endpoint_config(streamdeck_settings_path: path)
    %{path: path}
  end

  test "section keys and dial choice save a mic and reconnect reads it back", %{path: path} do
    socket = joined_socket()
    ref = push(socket, "devices", inventory())
    assert_reply(ref, :ok, %{}, 1_000)
    ref = push(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_reply(ref, :ok, %{}, 1_000)
    state = :sys.get_state(socket.channel_pid)
    frame = FrameUpdates.frame(state)
    assert Enum.map_join(frame.keys, " ", & &1.label) =~ "Brightness"
    refute Enum.any?(frame.keys, &String.contains?(&1.label, "TestMic"))
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{}, 1_000)
    ref = push(socket, "input", %{"kind" => "dial_turn", "index" => 0, "ticks" => 1})
    assert_reply(ref, :ok, %{}, 1_000)
    ref = push(socket, "input", %{"kind" => "dial_press", "index" => 0})
    assert_reply(ref, :ok, %{"mic_id" => "second"}, 1_000)
    assert {:ok, saved} = Settings.read(path)
    assert saved["mic_id"] == "second"
    second = joined_socket()
    assert :sys.get_state(second.channel_pid).assigns.deck_settings["mic_id"] == "second"
  end

  test "legacy migration is once and settings pushes apply persisted view", %{path: path} do
    socket = joined_socket()
    ref = push(socket, "devices", Map.put(inventory(), "legacy_mic_id", "old-mic"))
    assert_reply(ref, :ok, %{}, 1_000)
    assert {:ok, saved} = Settings.read(path)
    assert saved["mic_id"] == "old-mic"
    ref = push(socket, "settings_set", %{"mic_id" => "second", "default_view" => "epic", "brightness" => 30})
    assert_reply(ref, :ok, %{"mic_id" => "second", "brightness" => 30}, 1_000)
    ref = push(socket, "devices", Map.put(inventory(), "legacy_mic_id", "old-mic"))
    assert_reply(ref, :ok, %{}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.deck_settings["mic_id"] == "second"
    second = joined_socket()
    assert :sys.get_state(second.channel_pid).assigns.deck_nav.view == :epic
  end

  test "malformed device inventory cannot mutate settings" do
    socket = joined_socket()
    ref = push(socket, "devices", %{"mics" => [%{"id" => 123}], "speakers" => []})
    assert_reply(ref, :error, %{reason: "invalid_devices"}, 1_000)
    ref = push(socket, "settings_set", %{"brightness" => "full"})
    assert_reply(ref, :error, %{reason: "not_saved"}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.deck_settings["brightness"] == nil
  end

  test "a real failed write leaves the file and applied settings unchanged and renders not saved", %{path: path} do
    assert {:ok, _settings} = Settings.set(%{"brightness" => 70}, path)
    original = File.read!(path)
    socket = joined_socket()
    ref = push(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_reply(ref, :ok, %{}, 1_000)
    File.chmod!(Path.dirname(path), 0o500)

    try do
      ref = push(socket, "settings_set", %{"brightness" => 30})
      assert_reply(ref, :error, %{reason: "not_saved"}, 1_000)
      assert File.read!(path) == original
      state = :sys.get_state(socket.channel_pid)
      assert state.assigns.deck_settings["brightness"] == 70
      frame = FrameUpdates.frame(state)
      assert hd(frame.strip).label =~ "Not saved"
      assert hd(frame.strip).svg =~ "Not saved"
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

    socket = joined_socket()
    ref = push(socket, "settings_set", %{"default_sort" => "title"})
    assert_reply(ref, :ok, %{"default_sort" => "title"}, 1_000)
    state = :sys.get_state(socket.channel_pid)
    frame = FrameUpdates.frame(state)
    assert hd(frame.keys).label =~ "AIUR-2"
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket"}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.deck_effects == [{:open_ticket, "AIUR-2"}]
  end

  test "hold dial four backs out of choices then returns to the prior view" do
    socket = joined_socket()

    for input <- [%{"kind" => "dial_long_press", "index" => 3}, %{"kind" => "key_press", "index" => 4}] do
      ref = push(socket, "input", input)
      assert_reply(ref, :ok, %{}, 1_000)
    end

    assert :sys.get_state(socket.channel_pid).assigns.settings_menu.section == "brightness"
    ref = push(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_reply(ref, :ok, %{}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.settings_menu.section == nil
    ref = push(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_reply(ref, :ok, %{}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.settings_menu == nil
  end

  test "device removal clamps choice paging so missing selection remains visible" do
    socket = joined_socket()
    inventory = %{inventory() | "mics" => Enum.map(1..20, &%{"id" => "mic-#{&1}", "label" => "Microphone #{&1}"})}
    ref = push(socket, "devices", inventory)
    assert_reply(ref, :ok, %{}, 1_000)
    ref = push(socket, "settings_set", %{"mic_id" => "mic-20"})
    assert_reply(ref, :ok, %{"mic_id" => "mic-20"}, 1_000)

    for input <- [%{"kind" => "dial_long_press", "index" => 3}, %{"kind" => "key_press", "index" => 0}, %{"kind" => "dial_turn", "index" => 0, "ticks" => 19}] do
      ref = push(socket, "input", input)
      assert_reply(ref, :ok, %{}, 1_000)
    end

    ref = push(socket, "devices", %{inventory | "mics" => [%{"id" => "first", "label" => "First"}]})
    assert_reply(ref, :ok, %{}, 1_000)
    state = :sys.get_state(socket.channel_pid)
    assert state.assigns.settings_menu.cursor == 1
    frame = FrameUpdates.frame(state)
    assert hd(frame.keys).label == "missing: mic-20 · Selected"
    assert hd(frame.keys).svg =~ ">missing:"
  end

  test "ticket key input focuses the agent and starts its transcript relay" do
    socket = joined_socket()
    ref = push(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_reply(ref, :ok, %{"view" => "ticket"}, 1_000)
    state = :sys.get_state(socket.channel_pid)
    assert state.assigns.focused_agent == "AIUR-1"
    assert is_pid(state.assigns.transcript_relay)
    assert Process.alive?(state.assigns.transcript_relay)
    ref = push(socket, "input", %{"kind" => "key", "index" => 0, "action" => "up"})
    assert_reply(ref, :ok, %{}, 1_000)
    assert :sys.get_state(socket.channel_pid).assigns.focus_token == state.assigns.focus_token
  end

  test "voice status is rendered on the strip and oversized status is refused" do
    socket = joined_socket()
    ref = push(socket, "voice_status", %{"text" => "Listening"})
    assert_reply(ref, :ok, %{}, 1_000)
    # Drain the initial frame first, then inspect the actual pushed status frame.
    assert_push("frame", _initial)
    assert_push("frame", %{strip: [region | _rest]})
    assert region.label == "Listening"
    assert region.svg =~ ">Listening<"
    ref = push(socket, "voice_status", %{"text" => String.duplicate("x", 201)})
    assert_reply(ref, :error, %{reason: "invalid_status"}, 1_000)
  end

  defp inventory, do: %{"mics" => [%{"id" => "first", "label" => "First"}, %{"id" => "second", "label" => "Second"}], "speakers" => [], "instances" => ["pc"]}
end
