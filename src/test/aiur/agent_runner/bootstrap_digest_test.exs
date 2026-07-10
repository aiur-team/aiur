defmodule Aiur.AgentRunner.BootstrapDigestTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.BootstrapDigest
  alias Aiur.Issue

  describe "maybe_enqueue_bootstrap_digest/1" do
    test "returns :ok for a non-Issue argument" do
      assert BootstrapDigest.maybe_enqueue_bootstrap_digest(:not_an_issue) == :ok
      assert BootstrapDigest.maybe_enqueue_bootstrap_digest(nil) == :ok
      assert BootstrapDigest.maybe_enqueue_bootstrap_digest(%{}) == :ok
    end

    test "returns :ok for an Issue without a binary identifier" do
      issue = %Issue{identifier: nil, id: "gid-bd1"}

      assert BootstrapDigest.maybe_enqueue_bootstrap_digest(issue) == :ok
    end
  end

  describe "maybe_attach_universal_subscriptions/1" do
    test "returns :ok for a non-Issue argument" do
      assert BootstrapDigest.maybe_attach_universal_subscriptions(:not_an_issue) == :ok
      assert BootstrapDigest.maybe_attach_universal_subscriptions(nil) == :ok
    end

    test "returns :ok for an Issue without a binary identifier" do
      issue = %Issue{identifier: nil, id: "gid-bd2"}

      assert BootstrapDigest.maybe_attach_universal_subscriptions(issue) == :ok
    end
  end

  describe "bootstrap_event_key/1" do
    test "returns the term unchanged for a non-map" do
      assert BootstrapDigest.bootstrap_event_key(:foo) == :foo
      assert BootstrapDigest.bootstrap_event_key("bar") == "bar"
      assert BootstrapDigest.bootstrap_event_key(42) == 42
    end

    test "returns {topic, id} tuple for a map with topic and id" do
      event = %{topic: "ticket.42.issue.commented", id: 7}

      assert BootstrapDigest.bootstrap_event_key(event) == {"ticket.42.issue.commented", 7}
    end

    test "prefers comment id over event id when comment has an integer id" do
      event = %{topic: "ticket.42.issue.commented", id: 7, comment: %{"id" => 99}}

      assert BootstrapDigest.bootstrap_event_key(event) == {"ticket.42.issue.commented", 99}
    end

    test "falls back to event id when comment has no integer id" do
      event = %{topic: "ticket.42.issue.commented", id: 7, comment: %{"id" => "not-integer"}}

      assert BootstrapDigest.bootstrap_event_key(event) == {"ticket.42.issue.commented", 7}
    end
  end
end
