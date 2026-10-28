defmodule AiurWeb.Streamdeck.Deck.SettingsSnapshotTest do
  use ExUnit.Case, async: false
  alias AiurWeb.Streamdeck.Deck.{Settings, SettingsSnapshot}

  setup do
    root = Path.join(System.tmp_dir!(), "deck-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "settings.json")}
  end

  test "retained reads do not reload preferences or invent an unobserved inventory", %{path: path} do
    assert SettingsSnapshot.read(path).status == :unavailable
    assert {:ok, _saved} = Settings.set(%{"mic_id" => "chosen"}, path)
    loaded = SettingsSnapshot.load(path)
    assert loaded.settings["mic_id"] == "chosen"
    assert loaded.devices == nil
    File.rm!(path)
    retained = SettingsSnapshot.attach(%{agents: []}, path).settings_snapshot
    assert retained.settings["mic_id"] == "chosen"
    assert retained.status == :ok
    assert retained.devices == nil
  end

  test "a failed save cannot publish or replace the previously committed snapshot", %{root: root, path: path} do
    SettingsSnapshot.load(path)
    :ok = SettingsSnapshot.subscribe(path)
    assert {:ok, saved} = SettingsSnapshot.save(%{"brightness" => 30}, path)
    assert saved.settings["brightness"] == 30
    assert_receive {:streamdeck_settings_changed, ^path}, 1_000
    original = File.read!(path)
    assert Jason.decode!(original)["brightness"] == 30
    File.chmod!(root, 0o500)
    try do
      assert {:error, :eacces} = SettingsSnapshot.save(%{"brightness" => 80}, path)
      assert File.read!(path) == original
      assert SettingsSnapshot.read(path).settings["brightness"] == 30
      refute_receive {:streamdeck_settings_changed, ^path}, 50
    after
      File.chmod!(root, 0o700)
    end
  end

  test "inventory becomes unavailable when the reporting PC connection exits", %{path: path} do
    SettingsSnapshot.load(path)
    :ok = SettingsSnapshot.subscribe(path)
    observer = self()
    inventory = %{"mics" => [%{"id" => "usb", "label" => "USB mic"}], "speakers" => [], "instances" => ["local"]}
    owner = spawn(fn ->
      SettingsSnapshot.devices(inventory, path)
      send(observer, :inventory_reported)
      receive do
        :stop -> :ok
      end
    end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :inventory_reported, 1_000
    assert_receive {:streamdeck_settings_changed, ^path}, 1_000
    assert SettingsSnapshot.read(path).devices == inventory
    send(owner, :stop)
    assert_receive {:streamdeck_settings_changed, ^path}, 1_000
    assert SettingsSnapshot.read(path).devices == nil
  end

  test "retention is bounded and evicted paths become unavailable", %{root: root} do
    paths = Enum.map(1..33, &Path.join(root, "settings-#{&1}.json"))
    Enum.each(paths, &SettingsSnapshot.load/1)
    assert SettingsSnapshot.read(hd(paths)).status == :unavailable
    assert SettingsSnapshot.read(List.last(paths)).status == :ok
  end
  test "only successful explicit instance saves renew ephemeral selection tokens", %{root: root, path: path} do
    assert SettingsSnapshot.load(path).selection_id == nil
    assert {:ok, first} = SettingsSnapshot.save(%{"instance" => "local"}, path)
    assert is_binary(first.selection_id)
    assert first.selection_id != ""
    assert first.settings["instance"] == "local"
    persisted = Jason.decode!(File.read!(path))
    assert persisted["instance"] == "local"
    refute Map.has_key?(persisted, "instance_selection_id")
    refute Map.has_key?(persisted, "selection_id")
    assert {:ok, brightness} = SettingsSnapshot.save(%{"brightness" => 40}, path)
    assert brightness.selection_id == first.selection_id
    assert {:ok, repeated} = SettingsSnapshot.save(%{"instance" => "local"}, path)
    assert repeated.selection_id != first.selection_id
    old_file = File.read!(path)
    File.chmod!(root, 0o500)
    try do
      assert {:error, :eacces} = SettingsSnapshot.save(%{"instance" => "remote"}, path)
      assert SettingsSnapshot.read(path).selection_id == repeated.selection_id
      assert SettingsSnapshot.read(path).settings["instance"] == "local"
      assert File.read!(path) == old_file
    after
      File.chmod!(root, 0o700)
    end
  end

end
