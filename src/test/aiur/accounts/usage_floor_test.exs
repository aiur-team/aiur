defmodule Aiur.Accounts.UsageFloorTest do
  use ExUnit.Case, async: true

  alias Aiur.Accounts.UsageFloor
  alias Aiur.Config.AgentSettings
  alias Aiur.Config.Schema

  @floor 5
  defp reading(windows, extra \\ %{}), do: Map.merge(%{windows: windows}, extra)

  describe "decision/2 at the floor" do
    test "a window at exactly the floor is held" do
      assert {:held, held} = UsageFloor.decision(reading(%{"seven_day" => 95}), @floor)
      assert held.window == "seven_day"
      assert held.remaining_percent == 5.0
      assert held.floor_percent == @floor
    end

    test "a window above the floor is allowed" do
      assert UsageFloor.decision(reading(%{"seven_day" => 94}), @floor) == :allow
      assert UsageFloor.decision(reading(%{"seven_day" => 94.9}), @floor) == :allow
    end

    test "an exhausted window is held too" do
      assert {:held, held} = UsageFloor.decision(reading(%{"five_hour" => 100}), @floor)
      assert held.remaining_percent == 0.0
    end
  end

  describe "decision/2 across rate windows" do
    test "a floored weekly window holds the route while the 5-hour window is fine" do
      assert {:held, %{window: "seven_day", remaining_percent: 3.0}} =
               UsageFloor.decision(reading(%{"five_hour" => 20, "seven_day" => 97}), @floor)
    end

    test "the tightest window is the one named" do
      assert {:held, %{window: "five_hour"}} = UsageFloor.decision(reading(%{"five_hour" => 96, "seven_day" => 40}), @floor)
    end

    test "both windows comfortable allows the route" do
      assert UsageFloor.decision(reading(%{"five_hour" => 40, "seven_day" => 40}), @floor) == :allow
    end
  end

  describe "decision/2 with no trustworthy number" do
    test "no reading at all is never floored" do
      assert UsageFloor.decision(nil, @floor) == :allow
    end

    test "an unknown reading is never floored" do
      assert UsageFloor.decision(%{source: "meter"}, @floor) == :allow
      assert UsageFloor.decision(reading(%{"seven_day" => nil}), @floor) == :allow
    end

    test "a stale reading is never floored" do
      assert UsageFloor.decision(reading(%{"seven_day" => 97}, %{stale: true, age_seconds: 86_400}), @floor) == :allow
    end

    test "a route the availability gate already refuses is left to that gate" do
      assert UsageFloor.decision(%{limited: true}, @floor) == :allow
    end

    test "a credit key without a known limit is never floored" do
      assert UsageFloor.decision(%{windows: %{"credits" => nil}, source: "provider_meter"}, @floor) == :allow
    end
  end

  describe "decision/2 with the floor disabled" do
    test "zero disables the floor" do
      assert UsageFloor.decision(reading(%{"seven_day" => 100}), 0) == :allow
    end

    test "nil disables the floor" do
      assert UsageFloor.decision(reading(%{"seven_day" => 100}), nil) == :allow
    end
  end

  describe "reading shapes" do
    test "the provider's raw window list is read the same way as the headroom map" do
      raw = %{windows: [%{window: "seven_day", used_percent: 97}, %{window: "five_hour", used_percent: 20}]}
      assert {:held, %{window: "seven_day"}} = UsageFloor.decision(raw, @floor)
    end
  end

  describe "held_line/1" do
    test "names the remaining percent, the floor and the reset" do
      resets_at = DateTime.add(DateTime.utc_now(), 2 * 3_600, :second)
      {:held, held} = UsageFloor.decision(reading(%{"seven_day" => 97}, %{resets: %{"seven_day" => resets_at}}), @floor)
      line = UsageFloor.held_line(held)
      assert line =~ "held: 3% left ≤ 5% floor"
      assert line =~ "resets in 1h 5"
    end

    test "omits the reset when the source does not know it" do
      {:held, held} = UsageFloor.decision(reading(%{"seven_day" => 97}), @floor)
      assert UsageFloor.held_line(held) == "held: 3% left ≤ 5% floor"
    end
  end

  describe "agent.usage_floor_percent" do
    test "defaults to five" do
      assert AgentSettings.usage_floor_percent(%Schema{}) == 5
      assert UsageFloor.default_percent() == 5
    end

    test "a settings struct without the field still reads as the default" do
      assert AgentSettings.usage_floor_percent(%{agent: %{}}) == 5
      assert AgentSettings.usage_floor_percent(:unavailable) == 5
    end

    test "clamps a configured value into 0..100" do
      assert AgentSettings.usage_floor_percent(settings(120)) == 100
      assert AgentSettings.usage_floor_percent(settings(-4)) == 0
      assert AgentSettings.usage_floor_percent(settings(12)) == 12
    end

    test "a per-backend override wins for that backend only" do
      settings =
        %Schema{agent: %Schema.Agent{priority: ["claude", "codex"], backend_configs: %{"claude" => %{"usage_floor_percent" => 2}}}}

      assert AgentSettings.usage_floor_percent_for(settings, "claude") == 2
      assert AgentSettings.usage_floor_percent_for(settings, "codex") == 5
      assert AgentSettings.usage_floor_percent_for(settings, nil) == 5
    end

    test "a backend override of zero disables the floor for that backend" do
      settings = %Schema{agent: %Schema.Agent{priority: ["openrouter"], backend_configs: %{"openrouter" => %{"usage_floor_percent" => 0}}}}

      refute UsageFloor.enabled?(AgentSettings.usage_floor_percent_for(settings, "openrouter"))
      assert UsageFloor.enabled?(AgentSettings.usage_floor_percent_for(settings, "claude"))
    end
  end

  describe "agent.usage_floor_percent from the config file" do
    test "parses the global key and the per-backend override from YAML-shaped input" do
      {:ok, settings} =
        Schema.parse(%{
          "agent" => %{
            "usage_floor_percent" => 7,
            "backend_configs" => %{"codex" => %{"usage_floor_percent" => 2}}
          }
        })

      assert AgentSettings.usage_floor_percent(settings) == 7
      assert AgentSettings.usage_floor_percent_for(settings, "codex") == 2
      assert AgentSettings.usage_floor_percent_for(settings, "claude") == 7
    end

    test "defaults to five when the key is absent" do
      {:ok, settings} = Schema.parse(%{})
      assert AgentSettings.usage_floor_percent(settings) == 5
    end

    test "rejects a value outside 0..100" do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"agent" => %{"usage_floor_percent" => 101}})
      assert message =~ "agent.usage_floor_percent must be less than or equal to 100"
    end
  end

  defp settings(percent), do: %Schema{agent: %Schema.Agent{usage_floor_percent: percent}}
end
