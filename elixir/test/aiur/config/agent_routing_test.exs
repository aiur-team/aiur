defmodule Aiur.Config.AgentRoutingTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Workflow

  describe "agent_routing/0" do
    test "returns empty by_complexity when no routing block is present" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

      assert Config.agent_routing() == %{by_complexity: %{}}
    end

    test "exposes the configured routing map with string keys" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude", "5" => "claude"}
      )

      assert Config.agent_routing() == %{
               by_complexity: %{"4" => "claude", "5" => "claude"}
             }
    end

    test "normalizes integer YAML keys to strings" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{4 => "claude"}
      )

      assert Config.agent_routing() == %{by_complexity: %{"4" => "claude"}}
    end

    test "rejects unsupported agent kinds in the routing map" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "weasel"}
      )

      assert_raise ArgumentError, ~r/unsupported agent kind/, fn ->
        Config.agent_routing()
      end
    end
  end

  describe "agent_kind_for_issue/1" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude", "5" => "claude"}
      )

      :ok
    end

    test "routes a complexity:4 issue to claude" do
      issue = %Issue{identifier: "215", labels: ["agent:in-progress", "complexity:4"]}
      assert Config.agent_kind_for_issue(issue) == "claude"
    end

    test "routes a complexity:5 issue to claude" do
      issue = %Issue{identifier: "300", labels: ["complexity:5"]}
      assert Config.agent_kind_for_issue(issue) == "claude"
    end

    test "falls back to the global default when complexity is unmapped" do
      issue = %Issue{identifier: "100", labels: ["complexity:2"]}
      assert Config.agent_kind_for_issue(issue) == "codex"
    end

    test "falls back when the issue has no complexity label" do
      issue = %Issue{identifier: "10", labels: ["agent:in-progress"]}
      assert Config.agent_kind_for_issue(issue) == "codex"
    end

    test "falls back for a nil issue" do
      assert Config.agent_kind_for_issue(nil) == "codex"
    end

    test "falls back when the issue is missing the labels field" do
      assert Config.agent_kind_for_issue(%{identifier: "99"}) == "codex"
    end

    test "picks the highest complexity when an issue carries multiple complexity labels" do
      # If a tracker reordered the labels payload, first-match would
      # silently demote a complexity:5 ticket to whatever complexity:1
      # appeared first. Highest-N wins keeps the routing safe under
      # any label ordering.
      issue = %Issue{identifier: "215", labels: ["complexity:2", "complexity:4"]}
      assert Config.agent_kind_for_issue(issue) == "claude"

      reversed = %Issue{identifier: "215", labels: ["complexity:4", "complexity:2"]}
      assert Config.agent_kind_for_issue(reversed) == "claude"
    end

    test "trims whitespace in the complexity label value" do
      issue = %Issue{identifier: "215", labels: ["complexity:4 "]}
      assert Config.agent_kind_for_issue(issue) == "claude"
    end

    test "ignores blank or non-integer complexity values" do
      blank = %Issue{identifier: "10", labels: ["complexity:"]}
      assert Config.agent_kind_for_issue(blank) == "codex"

      word = %Issue{identifier: "10", labels: ["complexity:high"]}
      assert Config.agent_kind_for_issue(word) == "codex"

      mixed = %Issue{identifier: "10", labels: ["complexity:high", "complexity:4"]}
      assert Config.agent_kind_for_issue(mixed) == "claude"
    end
  end

  describe "agent_kind_for_issue/1 with no routing block" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")
      :ok
    end

    test "ignores complexity labels and uses the global default" do
      issue = %Issue{identifier: "215", labels: ["complexity:4"]}
      assert Config.agent_kind_for_issue(issue) == "codex"
    end
  end
end
