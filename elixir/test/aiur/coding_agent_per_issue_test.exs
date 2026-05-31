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

  describe "modules_for/1" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        agent_routing_by_complexity: %{"4" => "claude"}
      )

      :ok
    end

    test "returns the adapter and transcript module from a single snapshot" do
      issue = %Issue{identifier: "215", labels: ["complexity:4"]}
      assert {Aiur.Claude.CodingAgent, Aiur.Claude.Transcript} = CodingAgent.modules_for(issue)
    end

    test "always returns a matching adapter/transcript pair" do
      # The whole point of `modules_for/1` is that it can never return
      # a mismatched pair like {Claude.CodingAgent, Codex.Transcript}
      # even under a mid-resolve workflow reload. Verifying on a few
      # representative issues here; the resolver tests cover the
      # complexity-label routing surface.
      for issue <- [
            %Issue{identifier: "1", labels: ["complexity:4"]},
            %Issue{identifier: "2", labels: ["complexity:2"]},
            %Issue{identifier: "3", labels: []},
            nil
          ] do
        {adapter, transcript_module} = CodingAgent.modules_for(issue)

        case adapter do
          Aiur.Claude.CodingAgent -> assert transcript_module == Aiur.Claude.Transcript
          Aiur.Codex.CodingAgent -> assert transcript_module == Aiur.Codex.Transcript
        end
      end
    end
  end

  describe "AgentRunner session pinning" do
    test "pin_backend round-trip recovers the adapter and transcript module" do
      session = %{port: :fake_port, thread_id: "thread-1", workspace: "/tmp/ws"}

      pinned =
        Aiur.AgentRunner.pin_backend_for_test(
          session,
          Aiur.Claude.CodingAgent,
          Aiur.Claude.Transcript
        )

      assert Aiur.AgentRunner.session_adapter_for_test(pinned) == Aiur.Claude.CodingAgent
      assert Aiur.AgentRunner.session_transcript_module_for_test(pinned) == Aiur.Claude.Transcript

      # Original session fields survive — backend pattern-matches that
      # depend on :port, :thread_id, :workspace still see them.
      assert pinned.port == :fake_port
      assert pinned.thread_id == "thread-1"
      assert pinned.workspace == "/tmp/ws"
    end

    test "session_adapter/1 raises loudly when called on an unpinned session" do
      # If a future code path constructs an `app_session` without going
      # through `pin_backend/3` and hands it to a runner helper, we want
      # a fast KeyError, not a silent fallback to the global adapter.
      assert_raise KeyError, fn ->
        Aiur.AgentRunner.session_adapter_for_test(%{port: :fake_port})
      end

      assert_raise KeyError, fn ->
        Aiur.AgentRunner.session_transcript_module_for_test(%{port: :fake_port})
      end
    end
  end
end
