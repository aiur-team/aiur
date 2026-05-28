defmodule Aiur.Opencode.EventRowTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.EventRow

  describe "matches?/2" do
    test "matches when entry has explicit identifier equal to rendering identifier" do
      assert EventRow.matches?(%{identifier: "101", topic: "anything"}, "101")
    end

    test "falls back to topic prefix when entry identifier is nil" do
      assert EventRow.matches?(%{identifier: nil, topic: "ticket.101.pr.opened"}, "101")
    end

    test "topic-prefix match is anchored — '10' does not match ticket '101'" do
      refute EventRow.matches?(%{topic: "ticket.101.pr.opened"}, "10")
    end

    test "non-matching identifier and non-matching topic returns false" do
      refute EventRow.matches?(%{identifier: "100", topic: "ticket.100.pr.opened"}, "101")
    end
  end

  describe "from/2 — first-person rendering for own :publish events" do
    test "PR opened by this agent renders without a 'Ticket N' prefix" do
      out =
        EventRow.from(
          %{kind: :publish, topic: "ticket.99.pr.opened", id: 1, body: %{"title" => "Add function_a"}},
          "99"
        )

      assert out == "> 📤 opened a PR: \"Add function_a\""
    end

    test "branch push uses 'pushed to its branch' verb phrase" do
      out =
        EventRow.from(
          %{kind: :publish, topic: "ticket.99.branch.push", id: 2, body: %{"message" => "abc123"}},
          "99"
        )

      assert out == "> 📤 pushed to its branch: \"abc123\""
    end

    test "label.added.agent.<state> renders the state inline" do
      out =
        EventRow.from(
          %{kind: :publish, topic: "ticket.99.issue.label.added.agent.in-progress", id: 3, body: nil},
          "99"
        )

      assert out == "> 📤 was labeled in-progress"
    end
  end

  describe "from/2 — third-person rendering for :receive events" do
    test "incoming PR-opened event names the source ticket" do
      out =
        EventRow.from(
          %{
            kind: :receive,
            topic: "ticket.100.pr.opened",
            id: 10,
            identifier: "99",
            body: %{"title" => "Add function_b"}
          },
          "99"
        )

      assert out == "> 📬 Ticket 100 opened a PR: \"Add function_b\""
    end

    test "incoming push event includes commit summary from body 'message'" do
      out =
        EventRow.from(
          %{
            kind: :receive,
            topic: "ticket.100.branch.push",
            id: 11,
            identifier: "99",
            body: %{"message" => "Add abc function"}
          },
          "99"
        )

      assert out == "> 📬 Ticket 100 pushed to its branch: \"Add abc function\""
    end

    test "no body means no summary suffix" do
      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.agent.blocked", id: 12, identifier: "99", body: nil},
          "99"
        )

      assert out == "> 📬 Ticket 100 declared itself blocked"
    end

    test "long body summary is truncated with an ellipsis" do
      long = String.duplicate("x", 200)

      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 13, body: %{"title" => long}},
          "99"
        )

      assert String.contains?(out, "…\"")
      assert byte_size(out) < byte_size("> 📬 Ticket 100 opened a PR: \"") + 200
    end
  end

  describe "from/2 — :read rendering" do
    test "ingested event from source ticket" do
      out =
        EventRow.from(
          %{kind: :read, topic: "ticket.100.pr.opened", id: 20, identifier: "99", body: nil},
          "99"
        )

      assert out == "> 📄 Ingested event from Ticket 100"
    end
  end

  describe "from/2 — verb-phrase coverage" do
    for {topic, expected} <- [
          {"ticket.42.pr.opened", "opened a PR"},
          {"ticket.42.pr.merged", "merged its PR"},
          {"ticket.42.pr.review_comment", "got a PR review comment"},
          {"ticket.42.branch.push", "pushed to its branch"},
          {"ticket.42.issue.commented", "got an issue comment"},
          {"ticket.42.agent.paused", "was paused"},
          {"ticket.42.agent.unpaused", "was resumed"},
          {"ticket.42.agent.blocked", "declared itself blocked"},
          {"ticket.42.agent.error.tokens_exhausted", "ran out of tokens"},
          {"ticket.42.issue.label.added.agent.todo", "was labeled todo"},
          {"ticket.42.agent.phase.work.start", "phase work: start"},
          {"ticket.42.agent.custom_thing", "emitted custom_thing"}
        ] do
      @topic topic
      @expected expected

      test "#{@topic} → #{@expected}" do
        out = EventRow.from(%{kind: :receive, topic: @topic, id: 1, body: nil}, "99")
        assert String.contains?(out, @expected)
      end
    end
  end

  describe "from/2 — body summary key precedence" do
    test "prefers 'message' over 'title'" do
      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 1, body: %{"message" => "M", "title" => "T"}},
          "99"
        )

      assert String.contains?(out, "\"M\"")
      refute String.contains?(out, "\"T\"")
    end

    test "atom keys work as a fallback" do
      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 1, body: %{message: "atom-key-msg"}},
          "99"
        )

      assert String.contains?(out, "\"atom-key-msg\"")
    end

    test "empty string body summary is treated as no summary" do
      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 1, body: %{"message" => ""}},
          "99"
        )

      refute String.contains?(out, ":")
    end
  end

  describe "from/2 — fallback behavior" do
    test "unknown topic shape falls through to the raw suffix" do
      out =
        EventRow.from(
          %{kind: :publish, topic: "ticket.99.something.entirely.new", id: 1, body: nil},
          "99"
        )

      assert out == "> 📤 something.entirely.new"
    end

    test "non-ticket topic falls back gracefully" do
      out = EventRow.from(%{kind: :publish, topic: "system.health", id: 1, body: nil}, "99")
      # No source-id parseable from the topic; no subject prefix.
      assert is_binary(out)
      assert String.starts_with?(out, "> 📤 ")
    end

    test "returns nil for malformed entries" do
      assert is_nil(EventRow.from(%{}, "99"))
      assert is_nil(EventRow.from(%{kind: :publish}, "99"))
    end
  end

  describe "from/2 — body-summary edge cases" do
    test "whitespace-only body summary produces no suffix (no dangling colon)" do
      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 1, body: %{"title" => "   \n  "}},
          "99"
        )

      refute String.contains?(out, ":")
    end

    test "multi-byte UTF-8 truncation at the codepoint boundary stays valid" do
      # 200 grapheme clusters of a 4-byte emoji — way past the 120-char cap.
      long = String.duplicate("🚀", 200)

      out =
        EventRow.from(
          %{kind: :receive, topic: "ticket.100.pr.opened", id: 1, body: %{"title" => long}},
          "99"
        )

      assert String.valid?(out)
      assert String.contains?(out, "…\"")
    end

    test "multi-line body summary keeps the blockquote bar on every line" do
      out =
        EventRow.from(
          %{
            kind: :receive,
            topic: "ticket.100.pr.opened",
            id: 1,
            body: %{"title" => "line one\nline two"}
          },
          "99"
        )

      assert out =~ ~r/\A> /
      assert String.contains?(out, "\n> ")
    end
  end
end
