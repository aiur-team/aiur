defmodule Aiur.AgentRunner.EventsDigestTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.Config

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

    test "includes known agent-source event messages in rendered output" do
      event = %{id: 1, topic: "ticket.T-001.agent.progress", source: :agent, message: "first update"}

      result = EventsDigest.render([event], "T-001")

      assert result =~ "first update"
      assert result =~ "ticket.T-001.agent.progress"
    end

    test "includes known orchestrator and system-source events in rendered output" do
      orchestrator = %{id: 15, topic: "ticket.T-001.orchestrator.notice", source: :orchestrator, message: "orchestrator update"}
      system = %{id: 16, topic: "ticket.T-001.system.notice", source: :system, message: "system update"}

      result = EventsDigest.render([orchestrator, system], "T-001")

      assert result =~ "orchestrator update"
      assert result =~ "system update"
    end

    test "includes replayed string-keyed internal sources" do
      events = [
        %{"id" => 18, "topic" => "ticket.T-001.agent.notice", "source" => "agent", "message" => "agent replay"},
        %{"id" => 19, "topic" => "ticket.T-001.orchestrator.notice", "source" => "orchestrator", "message" => "orchestrator replay"},
        %{"id" => 20, "topic" => "ticket.T-001.system.notice", "source" => "system", "message" => "system replay"}
      ]

      result = EventsDigest.render(events, "T-001")

      assert result =~ "agent replay"
      assert result =~ "orchestrator replay"
      assert result =~ "system replay"
    end

    test "suppresses events from an unrecognized source" do
      event = %{id: 17, topic: "ticket.T-001.comment.created", source: :linear, message: "untrusted source"}

      refute EventsDigest.render([event], "T-001") =~ "untrusted source"
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

    test "passes CI lifecycle events through without an author trust stamp" do
      event = %{
        id: 31,
        topic: "ticket.T-001.ci.failed",
        source: :github,
        message: "CI failed: lint"
      }

      result = EventsDigest.render([event], "T-001")

      assert result =~ "CI failed: lint"
      assert result =~ ~s(<external-content source="github">)
    end

    test "suppresses CI-shaped events from an unrecognized source" do
      event = %{id: 32, topic: "ticket.T-001.ci.failed", source: :linear, message: "forged CI failure"}

      refute EventsDigest.render([event], "T-001") =~ "forged CI failure"
    end

    test "includes trusted agent attention events while retaining the alert display source" do
      event = %{
        "source" => "alert",
        id: 33,
        topic: "ticket.T-001.agent.attention.scope-question",
        message: "operator decision required",
        source: :agent
      }

      assert EventsDigest.render([event], "T-001") =~ "operator decision required"
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

    test "treats a string \"github\" source the same as the :github atom" do
      untrusted = %{id: 10, topic: "ticket.T.issue.commented", source: "github", message: "hidden"}
      trusted = %{id: 11, topic: "ticket.T.issue.commented", source: "github", author_trusted?: true, message: "shown"}

      result = EventsDigest.render([untrusted, trusted], "T")

      refute result =~ "hidden"
      assert result =~ "shown"
    end

    test "escapes attribute-breaking characters in the github author name" do
      event = %{
        id: 12,
        topic: "ticket.T.issue.commented",
        source: "github",
        author_trusted?: true,
        author: ~s(ev"il<a>&b),
        message: "payload"
      }

      result = EventsDigest.render([event], "T")

      assert result =~ ~s(author="ev&quot;il&lt;a&gt;&amp;b")
      # The raw, unescaped author must never reach the prompt.
      refute result =~ ~s(author="ev"il<a>)
    end

    test "renders an event with neither message nor summary as a bare id/topic line" do
      event = %{id: 13, topic: "ticket.T.agent.progress", source: :agent}

      result = EventsDigest.render([event], "T")

      assert result =~ "[id=13] ticket.T.agent.progress"
      # No trailing ": <summary>" suffix when the summary is empty.
      refute result =~ "ticket.T.agent.progress:"
    end

    test "falls back to the summary field when no message is present" do
      event = %{id: 14, topic: "ticket.T.agent.progress", source: :agent, summary: "from summary field"}

      assert EventsDigest.render([event], "T") =~ "from summary field"
    end

    test "suppresses non-map events" do
      refute EventsDigest.render([:raw_atom_event], "T") =~ ":raw_atom_event"
    end
  end

  describe "render/2 block-state debounce" do
    test "coalesces a block/unblock oscillation on one ticket to the latest state" do
      blocked = %{id: 1, topic: "ticket.T-1.agent.blocked", source: :agent, message: "EARLY-BLOCK-MSG"}
      unblocked = %{id: 2, topic: "ticket.T-1.agent.unblocked", source: :agent, message: "LATE-UNBLOCK-MSG"}

      result = EventsDigest.render([blocked, unblocked], "T-1")

      # Latest event in the chain wins; the earlier one collapses.
      assert result =~ "LATE-UNBLOCK-MSG"
      refute result =~ "EARLY-BLOCK-MSG"
    end

    test "does not coalesce block-state events across different tickets" do
      t1 = %{id: 1, topic: "ticket.T-1.agent.blocked", source: :agent, message: "t1 blocked"}
      t2 = %{id: 2, topic: "ticket.T-2.agent.blocked", source: :agent, message: "t2 blocked"}

      result = EventsDigest.render([t1, t2], "obs")

      assert result =~ "t1 blocked"
      assert result =~ "t2 blocked"
    end

    test "keeps both events when their timestamps fall outside the debounce window" do
      timestamp = ~U[2026-01-01 00:00:00Z]
      outside_window = Config.events_block_state_debounce_seconds() + 1

      earlier = %{
        id: 1,
        topic: "ticket.T-1.agent.blocked",
        source: :agent,
        message: "old block",
        emitted_at: timestamp
      }

      later = %{
        id: 2,
        topic: "ticket.T-1.agent.unblocked",
        source: :agent,
        message: "new unblock",
        emitted_at: DateTime.add(timestamp, outside_window, :second)
      }

      result = EventsDigest.render([earlier, later], "T-1")

      assert result =~ "old block"
      assert result =~ "new unblock"
    end

    test "coalesces block-state events at the exact debounce boundary" do
      timestamp = ~U[2026-01-01 00:00:00Z]
      window = Config.events_block_state_debounce_seconds()

      earlier = %{
        id: 1,
        topic: "ticket.T-1.agent.blocked",
        source: :agent,
        message: "boundary block",
        emitted_at: timestamp
      }

      later = %{
        id: 2,
        topic: "ticket.T-1.agent.unblocked",
        source: :agent,
        message: "boundary unblock",
        emitted_at: DateTime.add(timestamp, window, :second)
      }

      result = EventsDigest.render([earlier, later], "T-1")

      refute result =~ "boundary block"
      assert result =~ "boundary unblock"
    end

    test "coalesces block-state events whose timestamps fall inside the debounce window" do
      earlier = %{
        id: 1,
        topic: "ticket.T-1.agent.blocked",
        source: :agent,
        message: "quick block",
        emitted_at: ~U[2026-01-01 00:00:00Z]
      }

      later = %{
        id: 2,
        topic: "ticket.T-1.agent.unblocked",
        source: :agent,
        message: "quick unblock",
        emitted_at: ~U[2026-01-01 00:00:03Z]
      }

      result = EventsDigest.render([earlier, later], "T-1")

      # 3s apart is inside the window; only the latest survives.
      assert result =~ "quick unblock"
      refute result =~ "quick block"
    end

    test "non-standard block-state topics group by full topic" do
      # A topic that isn't the canonical ticket.<id>.agent.<kind> shape falls
      # into the topic-keyed grouping branch of block_state_group_key/1.
      e = %{id: 1, topic: "custom.agent.blocked", source: :agent, message: "custom blocked"}

      assert EventsDigest.render([e], "T") =~ "custom blocked"
    end
  end
end
