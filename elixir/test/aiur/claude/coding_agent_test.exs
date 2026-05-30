defmodule Aiur.Claude.CodingAgent.ModelPlumbingTest do
  @moduledoc """
  Verifies that the Claude `turn/start` frame surfaces `claude.model` from
  the workflow when set, and omits the field when the workflow is silent
  (lets claude-app-server fall back to its own default).
  """

  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Workflow

  describe "send_operator_message/2 — model plumbing" do
    test "includes params.model when claude.model is set in the workflow" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_model: "claude-sonnet-4-6"
      )

      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace"
      }

      assert {:ok, _request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello"})

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["params"]["model"] == "claude-sonnet-4-6"

      close_port(port)
    end

    test "omits params.model when claude.model is absent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_model: nil
      )

      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace"
      }

      assert {:ok, _request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello"})

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      refute Map.has_key?(frame["params"], "model")

      close_port(port)
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
