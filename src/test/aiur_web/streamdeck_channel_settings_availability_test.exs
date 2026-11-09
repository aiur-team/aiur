defmodule AiurWeb.StreamdeckChannelSettingsAvailabilityTest do
  use AiurWeb.StreamdeckChannelCase
  alias AiurWeb.Streamdeck.Deck.SettingsSnapshot

  test "failed microphone discovery stays unavailable while an observed empty speaker list stays empty" do
    root = Path.join(System.tmp_dir!(), "deck-discovery-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    put_endpoint_config(streamdeck_settings_path: path)
    socket = joined_socket()
    assert_push("frame", _initial, 1_500)
    inventory = %{"mics" => [], "speakers" => [], "availability" => %{"mics" => false, "speakers" => true}}
    input(socket, "devices", inventory)
    assert SettingsSnapshot.read(path).devices["availability"]["mics"] == false
    assert_push("frame", _inventory_updated, 1_500)
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_push("frame", sections, 1_500)
    assert hd(sections.keys).label == "Mic · Unavailable"
    input(socket, "input", %{"kind" => "key_press", "index" => 0})
    assert_push("frame", microphones, 1_500)
    assert hd(microphones.strip).label =~ "Unavailable"
    input(socket, "input", %{"kind" => "dial_long_press", "index" => 3})
    assert_push("frame", _sections_again, 1_500)
    input(socket, "input", %{"kind" => "key_press", "index" => 1})
    assert_push("frame", speakers, 1_500)
    assert hd(speakers.strip).label =~ "No devices"
    invalid = put_in(inventory, ["availability", "mics"], "unknown")
    ref = push(socket, "devices", invalid)
    assert_reply(ref, :error, %{reason: "invalid_devices"}, 1_000)
    assert SettingsSnapshot.read(path).devices["availability"]["mics"] == false
  end

  defp input(socket, event, payload) do
    ref = push(socket, event, payload)
    assert_reply(ref, :ok, _reply, 1_000)
  end
end
