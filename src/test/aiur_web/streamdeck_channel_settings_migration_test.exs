defmodule AiurWeb.StreamdeckChannelSettingsMigrationTest do
  use AiurWeb.StreamdeckChannelCase
  alias AiurWeb.Streamdeck.Deck.SettingsSnapshot

  test "a failed legacy microphone import reports not saved and can retry" do
    root = Path.join(System.tmp_dir!(), "deck-migration-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    put_endpoint_config(streamdeck_settings_path: path)
    socket = joined_socket()
    assert_push("frame", _initial, 1_500)
    inventory = %{"mics" => [%{"id" => "saved", "label" => "Saved mic"}], "speakers" => [], "legacy_mic_id" => "saved"}
    File.chmod!(root, 0o500)

    try do
      ref = push(socket, "devices", inventory)
      assert_reply(ref, :error, %{reason: "not_saved"}, 1_000)
      refute File.exists?(path)
      assert SettingsSnapshot.read(path).settings["mic_id"] == nil
      assert_push("frame", frame, 1_500)
      assert hd(frame.strip).label == "Not saved"
      assert hd(frame.strip).svg =~ "Not saved"
    after
      File.chmod!(root, 0o700)
    end

    ref = push(socket, "devices", inventory)
    assert_reply(ref, :ok, %{}, 1_000)
    assert SettingsSnapshot.read(path).settings["mic_id"] == "saved"
    assert Jason.decode!(File.read!(path))["mic_id"] == "saved"
    assert :sys.get_state(socket.channel_pid).assigns.deck_nav.settings.notice == "Saved"
    assert :sys.get_state(socket.channel_pid).assigns.deck_toast == nil
  end
end
