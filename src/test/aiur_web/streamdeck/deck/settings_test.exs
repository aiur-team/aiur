defmodule AiurWeb.Streamdeck.Deck.SettingsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.{Settings, SettingsMenu}
  alias AiurWeb.Streamdeck.SettingsUpdates

  setup do
    root = Path.join(System.tmp_dir!(), "deck-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "streamdeck-settings.json")}
  end

  test "mic selection survives reloading and settings files are private", %{path: path} do
    assert {:ok, saved} = Settings.set(%{"mic_id" => "usb-yeti"}, path)
    assert saved["mic_id"] == "usb-yeti"
    assert {:ok, loaded} = Settings.read(path)
    assert loaded["mic_id"] == "usb-yeti"
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "failed write preserves the previous complete file", %{root: root, path: path} do
    assert {:ok, _saved} = Settings.set(%{"mic_id" => "old-mic"}, path)
    original = File.read!(path)
    File.chmod!(root, 0o500)

    try do
      assert {:error, :eacces} = Settings.set(%{"mic_id" => "new-mic"}, path)
      assert File.read!(path) == original
    after
      File.chmod!(root, 0o700)
    end

    assert File.ls!(root) == ["streamdeck-settings.json"]
  end

  test "validates settings and clamps brightness before persisting", %{path: path} do
    assert {:ok, saved} = Settings.set(%{"brightness" => 190, "dim_after_seconds" => 0}, path)
    assert saved["brightness"] == 100
    assert {:ok, saved} = Settings.set(%{"brightness" => -1}, path)
    assert saved["brightness"] == 0

    for patch <- [%{"unknown" => 1}, %{"default_view" => "bad"}, %{"brightness" => "30"}, %{"dim_after_seconds" => -1}, %{"alerts" => %{}}] do
      assert {:error, :invalid_settings} = Settings.set(patch, path)
    end

    assert {:ok, loaded} = Settings.read(path)
    assert loaded["brightness"] == 0
  end

  test "unknown saved microphone remains marked missing" do
    settings = Map.put(Settings.defaults(), "mic_id", "unplugged")
    devices = %{"mics" => [%{"id" => "first", "label" => "First microphone"}]}
    assert SettingsMenu.summary("mic_id", settings, devices) == "missing: unplugged"
    assert SettingsMenu.choices("mic_id", settings, devices) == [%{label: "missing: unplugged", value: "unplugged"}, %{label: "First microphone", value: "first"}]
  end

  test "state and priority sorts retain canonical bucket and queue order within groups" do
    agents = [
      %{identifier: "AIUR-3", bucket: :alert, priority: false},
      %{identifier: "AIUR-9", bucket: :stuck, priority: true},
      %{identifier: "AIUR-10", bucket: :running, priority: true},
      %{identifier: "AIUR-2", bucket: :queued, priority: false},
      %{identifier: "AIUR-1", bucket: :queued, priority: false}
    ]

    assert SettingsUpdates.sort(agents, %{"default_sort" => "state"}) == agents
    sorted = SettingsUpdates.sort(agents, %{"default_sort" => "priority"})
    assert Enum.map(sorted, & &1.identifier) == ["AIUR-9", "AIUR-10", "AIUR-3", "AIUR-2", "AIUR-1"]
  end
end
