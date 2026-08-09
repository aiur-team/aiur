defmodule Aiur.ConfigTest do
  use ExUnit.Case, async: true

  alias Aiur.Config

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
