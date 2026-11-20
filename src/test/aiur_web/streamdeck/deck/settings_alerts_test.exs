defmodule AiurWeb.Streamdeck.Deck.SettingsAlertsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.Settings

  test "a partial alert file preserves defaults and subsequent patches preserve saved categories" do
    root = Path.join(System.tmp_dir!(), "deck-alert-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    path = Path.join(root, "settings.json")
    command = %{"flash" => false, "chime" => false}
    ci_red = %{"flash" => false, "chime" => true}
    File.write!(path, Jason.encode!(%{"alerts" => %{"command" => command, "ci_red" => ci_red}}))

    assert {:ok, settings} = Settings.read(path)
    assert settings["alerts"]["command"] == command
    assert settings["alerts"]["ci_red"] == ci_red
    assert settings["alerts"]["error"] == Settings.defaults()["alerts"]["error"]
    assert settings["alerts"]["usage_limited"] == Settings.defaults()["alerts"]["usage_limited"]
    error = %{"flash" => false, "chime" => false}
    assert {:ok, saved} = Settings.set(%{"alerts" => %{"error" => error}}, path)
    assert saved["alerts"]["command"] == command
    assert saved["alerts"]["ci_red"] == ci_red
    assert {:ok, reloaded} = Settings.read(path)
    assert reloaded["alerts"]["error"] == error
    assert reloaded["alerts"]["command"] == command
    assert {:error, :invalid_settings} = Settings.set(%{"alerts" => %{"unknown" => command}}, path)
    assert {:error, :invalid_settings} = Settings.set(%{"alerts" => %{"command" => %{"flash" => "yes", "chime" => false}}}, path)
  end
end
