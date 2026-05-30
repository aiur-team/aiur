defmodule Aiur.CodingAgentPerIssueTest do
  use Aiur.TestSupport

  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Workflow

  describe "adapter_for/1" do
    test "routes complexity:4 to Claude when routing maps 4 -> claude" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      issue = %Issue{identifier: "215", labels: ["complexity:4"]}

      assert CodingAgent.adapter_for(issue) == Aiur.Claude.CodingAgent
    end

    test "falls back to the global codex default when complexity is unmapped" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      issue = %Issue{identifier: "100", labels: ["complexity:2"]}

      assert CodingAgent.adapter_for(issue) == Aiur.Codex.CodingAgent
    end

    test "falls back to the global default for a nil issue" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      assert CodingAgent.adapter_for(nil) == Aiur.Codex.CodingAgent
    end

    test "absent routing block preserves global behavior" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

      issue = %Issue{identifier: "215", labels: ["complexity:4"]}

      assert CodingAgent.adapter_for(issue) == Aiur.Codex.CodingAgent
    end
  end

  describe "transcript_module_for/1" do
    test "mirrors adapter_for/1 — claude-routed issue gets Claude.Transcript" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      issue = %Issue{identifier: "215", labels: ["complexity:4"]}

      assert CodingAgent.transcript_module_for(issue) == Aiur.Claude.Transcript
    end

    test "codex-routed issue gets Codex.Transcript" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      issue = %Issue{identifier: "100", labels: ["complexity:2"]}

      assert CodingAgent.transcript_module_for(issue) == Aiur.Codex.Transcript
    end
  end
end
