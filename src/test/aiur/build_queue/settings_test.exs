defmodule Aiur.BuildQueue.SettingsTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildQueue.Settings
  alias Aiur.Config.Schema

  test "null observation age derives twice the default polling interval" do
    assert {:ok, settings} = Schema.parse(%{"build_queue" => %{"observation_max_age_seconds" => nil}})
    assert Settings.observation_max_age_ms(settings) == 240_000
  end

  test "derived observation age follows the configured polling interval" do
    assert {:ok, settings} = Schema.parse(%{"polling" => %{"interval_seconds" => 300}})
    assert Settings.observation_max_age_ms(settings) == 600_000
  end

  test "explicit observation age overrides the polling derivation" do
    assert {:ok, settings} = Schema.parse(%{"polling" => %{"interval_seconds" => 300}, "build_queue" => %{"observation_max_age_seconds" => 30}})
    assert Settings.observation_max_age_ms(settings) == 30_000
  end
end
