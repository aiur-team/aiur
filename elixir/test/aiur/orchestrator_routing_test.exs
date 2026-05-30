defmodule Aiur.OrchestratorRoutingTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Workflow

  describe "default_running_control/1 honors per-issue routing" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude", "5" => "claude"}
      )

      :ok
    end

    test "claude-routed issue gets Claude's safe_checkpoints" do
      issue = %Issue{identifier: "215", labels: ["complexity:4"]}

      control = Orchestrator.default_running_control_for_test(issue)

      assert control.can_interrupt == true
      assert control.safe_checkpoints == [:notification]
      assert control.status == :working
    end

    test "codex-routed issue (no match) gets Codex's safe_checkpoints" do
      issue = %Issue{identifier: "100", labels: ["complexity:2"]}

      control = Orchestrator.default_running_control_for_test(issue)

      assert control.can_interrupt == true
      assert control.safe_checkpoints == [:notification, :tool_result]
      assert control.status == :working
    end

    test "nil issue falls back to the global default (codex)" do
      control = Orchestrator.default_running_control_for_test(nil)

      assert control.can_interrupt == true
      assert control.safe_checkpoints == [:notification, :tool_result]
    end
  end
end
