defmodule Aiur.ConfigTest do
  use ExUnit.Case, async: true

  alias Aiur.Config

  describe "avoid_peak_pricing_value/1" do
    test "defaults to true when the pricing policy is absent (the opt-out default)" do
      assert Config.avoid_peak_pricing_value(%{agent: %{}}) == true
      assert Config.avoid_peak_pricing_value(%{}) == true
      assert Config.avoid_peak_pricing_value(nil) == true
    end

    test "honours an explicit setting" do
      assert Config.avoid_peak_pricing_value(%{agent: %{pricing_policy: %{avoid_peak_pricing: true}}}) == true
      assert Config.avoid_peak_pricing_value(%{agent: %{pricing_policy: %{avoid_peak_pricing: false}}}) == false
    end
  end

  describe "base_branch/2" do
    test "returns a configured non-empty branch" do
      assert Config.base_branch(%{base_branch: "develop"}, config_path: "/tmp/aiur/config", cwd: "/tmp/repo") == "develop"
    end

    test "raises with the searched config path and resolved cwd when the branch is missing or empty" do
      config_path = "/tmp/aiur/config"
      cwd = "/tmp/repo"

      for tracker <- [%{}, %{tracker: nil}, %{base_branch: nil}, %{base_branch: ""}, %{base_branch: "   "}] do
        error =
          assert_raise ArgumentError, fn ->
            Config.base_branch(tracker, config_path: config_path, cwd: cwd)
          end

        assert error.message =~ "tracker.base_branch"
        assert error.message =~ config_path
        assert error.message =~ cwd
      end
    end
  end

  describe "rate_limit_fallback_backend/0" do
    test "defaults to claude" do
      assert Config.rate_limit_fallback_backend() == "claude"
    end
  end

  describe "default_max_concurrent_agents/1" do
    test "calibrates the fleet ceiling from measured host capacity (16 cores -> ~20 agents)" do
      # The 2026-07-31 capacity run saturated a 16-core host near 19-20 agents.
      assert Config.default_max_concurrent_agents(16) == 20
      assert Config.default_max_concurrent_agents(8) == 10
      assert Config.default_max_concurrent_agents(4) == 5
      assert Config.default_max_concurrent_agents(1) == 2
    end

    test "floors at two agents for degenerate scheduler counts" do
      assert Config.default_max_concurrent_agents(0) == 2
      assert Config.default_max_concurrent_agents(-1) == 2
    end
  end
end
