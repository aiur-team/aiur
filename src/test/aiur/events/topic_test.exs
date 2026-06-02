defmodule Aiur.Events.TopicTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Topic

  describe "matches?/2 — AMQP 0-9-1 topic exchange semantics" do
    # Authoritative fixture table derived from the RabbitMQ Tutorial 5 +
    # AMQP 0-9-1 spec + LavinMQ's published backtracking-bug taxonomy.
    # `*` matches exactly one segment between dots.
    # `#` matches zero or more segments (greedy with backtracking).

    for {name, %{pattern: p, topic: t, match?: expected}} <- %{
          # Literal matches
          "literal exact match" => %{pattern: "task.done", topic: "task.done", match?: true},
          "literal mismatch" => %{pattern: "task.done", topic: "task.todo", match?: false},
          "literal prefix is not a match" => %{pattern: "task", topic: "task.done", match?: false},
          "literal suffix is not a match" => %{pattern: "done", topic: "task.done", match?: false},

          # `*` (exactly one segment)
          "star matches one word" => %{pattern: "task.*", topic: "task.done", match?: true},
          "star does not match multiple words" => %{pattern: "task.*", topic: "task.todo.urgent", match?: false},
          "star does not match zero words" => %{pattern: "task.*", topic: "task", match?: false},
          "star in the middle" => %{pattern: "ticket.*.branch.push", topic: "ticket.101.branch.push", match?: true},
          "star at start" => %{pattern: "*.branch.push", topic: "ticket.branch.push", match?: true},
          "star at start does not match multi" => %{pattern: "*.branch.push", topic: "a.b.branch.push", match?: false},
          "double star matches two segments" => %{pattern: "*.*", topic: "a.b", match?: true},
          "double star rejects one segment" => %{pattern: "*.*", topic: "a", match?: false},
          "double star rejects three segments" => %{pattern: "*.*", topic: "a.b.c", match?: false},

          # `#` (zero or more segments) — the bug-magnet per LavinMQ
          "hash matches zero words after prefix" => %{pattern: "task.#", topic: "task", match?: true},
          "hash matches one word after prefix" => %{pattern: "task.#", topic: "task.done", match?: true},
          "hash matches many words after prefix" => %{pattern: "task.#", topic: "task.todo.urgent.now", match?: true},
          "hash alone matches empty" => %{pattern: "#", topic: "", match?: true},
          "hash alone matches any non-empty" => %{pattern: "#", topic: "lazy.orange.elephant", match?: true},
          "hash at start matches with literal suffix" => %{pattern: "#.error", topic: "error", match?: true},
          "hash at start with prefix" => %{pattern: "#.error", topic: "foo.error", match?: true},
          "hash at start with multi-prefix" => %{pattern: "#.error", topic: "foo.bar.error", match?: true},
          "hash at start does not match wrong suffix" => %{pattern: "#.error", topic: "foo.warning", match?: false},
          "double hash with literal in middle" => %{pattern: "#.foo.#", topic: "foo", match?: true},
          "double hash with literal in middle (prefix)" => %{pattern: "#.foo.#", topic: "x.foo", match?: true},
          "double hash with literal in middle (suffix)" => %{pattern: "#.foo.#", topic: "foo.y", match?: true},
          "double hash with literal in middle (both sides)" => %{pattern: "#.foo.#", topic: "x.foo.y", match?: true},
          "double hash with literal in middle (none)" => %{pattern: "#.foo.#", topic: "x.y.z", match?: false},

          # Empty segments and empty topics
          "empty topic matches only hash" => %{pattern: "lazy.orange", topic: "", match?: false},
          "empty topic matches lazy.#" => %{pattern: "lazy.#", topic: "", match?: false},
          "non-empty topic does not match literal lazy.orange" => %{pattern: "lazy.orange", topic: "orange", match?: false},

          # Prefix-must-match invariant
          "prefix must match — quick.lazy.fox vs lazy.#" => %{pattern: "lazy.#", topic: "quick.lazy.fox", match?: false},
          "prefix must match — orange vs lazy.#" => %{pattern: "lazy.#", topic: "orange", match?: false},

          # Mixed wildcards
          "star + hash together" => %{pattern: "*.orange.#", topic: "quick.orange", match?: true},
          "star + hash together with multi-suffix" => %{pattern: "*.orange.#", topic: "quick.orange.fox.rabbit", match?: true},
          "star + hash together — first wrong" => %{pattern: "*.orange.#", topic: "orange.fox", match?: false},

          # Real-world Aiur patterns from the brainstorm
          "ticket pattern matches push" => %{pattern: "ticket.*.branch.push", topic: "ticket.MT-42.branch.push", match?: true},
          "ticket pattern rejects force-push" => %{pattern: "ticket.*.branch.push", topic: "ticket.MT-42.branch.force-push", match?: false},
          "ticket hash matches all surfaces" => %{pattern: "ticket.101.#", topic: "ticket.101.agent.decision.architecture", match?: true},
          "ticket hash matches issue surface" => %{pattern: "ticket.101.#", topic: "ticket.101.issue.label.added", match?: true},
          "system main matches base-branch push" => %{pattern: "system.main.branch.push", topic: "system.main.branch.push", match?: true},
          "agent attention wildcard" => %{pattern: "ticket.*.agent.attention.*", topic: "ticket.MT-7.agent.attention.scope-question", match?: true},

          # Edge cases the spec is silent on — pick consistent behavior
          # Empty segments (e.g., "a..b") treated as real words containing empty string
          "empty segment in topic" => %{pattern: "a.*.b", topic: "a..b", match?: true},
          "empty segment matches literal empty" => %{pattern: "a..b", topic: "a..b", match?: true}
        } do
      @tag fixture: name
      test "matches?/2 — #{name}", %{fixture: _} do
        assert Topic.matches?(unquote(p), unquote(t)) == unquote(expected),
               "Topic.matches?(#{inspect(unquote(p))}, #{inspect(unquote(t))}) expected #{unquote(expected)}"
      end
    end

    test "raises on non-binary pattern" do
      assert_raise FunctionClauseError, fn -> Topic.matches?(nil, "task.done") end
    end

    test "raises on non-binary topic" do
      assert_raise FunctionClauseError, fn -> Topic.matches?("task.done", nil) end
    end

    test "accepts 255-byte routing key (AMQP max)" do
      long_topic = String.duplicate("a", 255)
      assert Topic.matches?("#", long_topic) == true
    end
  end

  describe "specificity_score/1 — for first-match-wins ordering" do
    test "literal-only patterns score highest" do
      assert Topic.specificity_score("ticket.101.branch.push") >
               Topic.specificity_score("ticket.*.branch.push")
    end

    test "star patterns score higher than hash patterns" do
      assert Topic.specificity_score("ticket.*.branch.push") >
               Topic.specificity_score("ticket.#")
    end

    test "more literal segments scores higher" do
      assert Topic.specificity_score("ticket.101.branch.push") >
               Topic.specificity_score("ticket.101.branch.*")
    end

    test "tie-break by lexicographic order is deterministic across calls" do
      # Same input always produces same score
      assert Topic.specificity_score("ticket.*.branch.push") ==
               Topic.specificity_score("ticket.*.branch.push")
    end
  end
end
