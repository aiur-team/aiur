defmodule Aiur.AgentRunner.EventsDigestTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.EventsDigest

  describe "event_field/2" do
    test "retrieves atom key from atom-keyed map" do
      assert EventsDigest.event_field(%{id: 42}, :id) == 42
    end

    test "retrieves atom key from string-keyed map via MapAccess" do
      assert EventsDigest.event_field(%{"id" => 99}, :id) == 99
    end

    test "returns nil for missing key" do
      assert EventsDigest.event_field(%{}, :id) == nil
    end
  end

  describe "render/2" do
    test "returns the aiur:events XML wrapper even for an empty list" do
      result = EventsDigest.render([], "T-001")

      assert String.starts_with?(result, "<aiur:events>")
      assert String.ends_with?(result, "</aiur:events>")
    end

    test "includes non-github event message in rendered output" do
      event = %{id: 1, topic: "ticket.T-001.agent.progress", message: "first update"}

      result = EventsDigest.render([event], "T-001")

      assert result =~ "first update"
      assert result =~ "ticket.T-001.agent.progress"
    end

    test "suppresses github event without author_trusted?: true" do
      event = %{
        id: 2,
        topic: "ticket.T-001.issue.commented",
        source: :github,
        message: "should be hidden"
      }

      result = EventsDigest.render([event], "T-001")

      refute result =~ "should be hidden"
    end

    test "passes github event through when author_trusted? is true" do
      event = %{
        id: 3,
        topic: "ticket.T-001.issue.commented",
        source: :github,
        author_trusted?: true,
        message: "trusted content"
      }

      result = EventsDigest.render([event], "T-001")

      assert result =~ "trusted content"
    end

    test "wraps trusted github content in external-content tag" do
      event = %{
        id: 4,
        topic: "ticket.T-001.issue.commented",
        source: :github,
        author_trusted?: true,
        author: "alice",
        message: "wrapped"
      }

      result = EventsDigest.render([event], "T-001")

      assert result =~ ~s(<external-content source="github" author="alice">)
    end
  end
end
