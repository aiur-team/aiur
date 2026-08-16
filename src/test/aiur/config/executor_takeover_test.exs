defmodule Aiur.Config.ExecutorTakeoverTest do
  use ExUnit.Case, async: true

  alias Aiur.Config
  alias Aiur.Config.Schema

  describe "executor takeover alert thresholds" do
    test "defaults to an 8h first alert and 1h continuous cadence" do
      assert {:ok, settings} = Schema.parse(%{})

      assert settings.executor_takeover_first_alert_hours == 8
      assert settings.executor_takeover_continuous_alert_hours == 1
    end

    test "accepts explicit thresholds" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "executor_takeover_first_alert_hours" => 24,
                 "executor_takeover_continuous_alert_hours" => 2
               })

      assert settings.executor_takeover_first_alert_hours == 24
      assert settings.executor_takeover_continuous_alert_hours == 2
    end

    test "zero disables the corresponding alert" do
      assert {:ok, settings} = Schema.parse(%{"executor_takeover_first_alert_hours" => 0})
      assert settings.executor_takeover_first_alert_hours == 0

      assert {:ok, settings} =
               Schema.parse(%{
                 "executor_takeover_first_alert_hours" => 8,
                 "executor_takeover_continuous_alert_hours" => 0
               })

      assert settings.executor_takeover_continuous_alert_hours == 0
    end

    test "rejects negative or non-integer thresholds with a clear config error" do
      for attrs <- [
            %{"executor_takeover_first_alert_hours" => -1},
            %{"executor_takeover_continuous_alert_hours" => -1},
            %{"executor_takeover_first_alert_hours" => 1.5},
            %{"executor_takeover_continuous_alert_hours" => "1"}
          ] do
        assert {:error, {:invalid_workflow_config, message}} = Schema.parse(attrs)

        assert message =~ "executor_takeover"
      end
    end

    test "Config accessors surface the configured thresholds" do
      # Accessors fall back to the schema defaults when no workflow config is
      # loaded in the test env (empty map), matching the safe-default pattern.
      assert is_integer(Config.executor_takeover_first_alert_hours())
      assert is_integer(Config.executor_takeover_continuous_alert_hours())
    end
  end
end
