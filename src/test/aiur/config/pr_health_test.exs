defmodule Aiur.Config.PrHealthTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  # #2346 review: the whole pr_health config surface had no test — deleting the
  # `cast_embed(:pr_health, ...)` line left every test green, so a user's
  # `pr_health:` block would be silently discarded and `enabled: true` would
  # never take effect. Mirrors pr_watch_test.exs: round-trips the block from
  # YAML and asserts the validation rejections.
  describe "pr_health config block" do
    test "defaults to disabled with the 30-minute cadence and 24h threshold when absent" do
      {:ok, settings} = Schema.parse(%{})

      assert settings.pr_health.enabled == false
      assert settings.pr_health.interval_seconds == 1800
      assert settings.pr_health.stale_hours == 24
    end

    test "parses the enabled flag and interval/threshold overrides" do
      {:ok, settings} =
        Schema.parse(%{
          "pr_health" => %{
            "enabled" => true,
            "interval_seconds" => 900,
            "stale_hours" => 48
          }
        })

      assert settings.pr_health.enabled == true
      assert settings.pr_health.interval_seconds == 900
      assert settings.pr_health.stale_hours == 48
    end

    test "rejects a non-positive interval_seconds" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"pr_health" => %{"interval_seconds" => 0}})

      assert message =~ "interval_seconds"
    end

    test "rejects a non-positive stale_hours" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"pr_health" => %{"stale_hours" => 0}})

      assert message =~ "stale_hours"
    end
  end
end
