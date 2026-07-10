defmodule Aiur.Config.RoutingValueTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.RoutingValue

  describe "split_routing_value/1" do
    test "splits a bare backend into {backend, nil}" do
      assert RoutingValue.split_routing_value("claude") == {"claude", nil}
    end

    test "splits backend:model" do
      assert RoutingValue.split_routing_value("claude:sonnet") == {"claude", "sonnet"}
    end

    test "splits backend:model:effort and drops effort" do
      assert RoutingValue.split_routing_value("claude:sonnet:high") == {"claude", "sonnet"}
    end

    test "handles effort-only backend::effort (no model)" do
      assert RoutingValue.split_routing_value("claude::high") == {"claude", nil}
    end

    test "strips +remote flag before splitting" do
      assert RoutingValue.split_routing_value("claude:haiku+remote") == {"claude", "haiku"}
      assert RoutingValue.split_routing_value("claude+remote") == {"claude", nil}
    end

    test "handles models with hyphens and dots" do
      assert RoutingValue.split_routing_value("codex:gpt-5.5") == {"codex", "gpt-5.5"}
    end
  end

  describe "routing_effort/1" do
    test "returns nil when no effort segment is present" do
      assert RoutingValue.routing_effort("claude:sonnet") == nil
      assert RoutingValue.routing_effort("claude") == nil
    end

    test "returns the effort segment for backend:model:effort" do
      assert RoutingValue.routing_effort("claude:sonnet:high") == "high"
    end

    test "returns the effort segment for backend::effort (no model)" do
      assert RoutingValue.routing_effort("claude-repl::xhigh") == "xhigh"
    end

    test "strips +remote flag before extracting effort" do
      assert RoutingValue.routing_effort("claude:sonnet:high+remote") == "high"
    end
  end

  describe "routing_remote_flag?/1" do
    test "returns true when the value ends with +remote" do
      assert RoutingValue.routing_remote_flag?("claude:haiku+remote") == true
      assert RoutingValue.routing_remote_flag?("claude+remote") == true
    end

    test "returns false when +remote is absent" do
      refute RoutingValue.routing_remote_flag?("claude:haiku")
      refute RoutingValue.routing_remote_flag?("claude")
    end
  end

  describe "routing_backend/1" do
    test "returns the backend portion of a routing value" do
      assert RoutingValue.routing_backend("claude:sonnet:high") == "claude"
      assert RoutingValue.routing_backend("codex") == "codex"
    end

    test "strips +remote before extracting backend" do
      assert RoutingValue.routing_backend("claude+remote") == "claude"
    end

    test "returns nil for non-binary input" do
      assert RoutingValue.routing_backend(nil) == nil
      assert RoutingValue.routing_backend(42) == nil
    end
  end

  describe "strip_remote_flag/1" do
    test "removes trailing +remote" do
      assert RoutingValue.strip_remote_flag("claude:sonnet+remote") == "claude:sonnet"
    end

    test "leaves values without +remote unchanged" do
      assert RoutingValue.strip_remote_flag("claude:sonnet") == "claude:sonnet"
    end
  end
end
