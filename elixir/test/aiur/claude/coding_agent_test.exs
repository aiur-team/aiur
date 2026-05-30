defmodule Aiur.Claude.CodingAgentTest do
  @moduledoc """
  Wire-format tests for the Claude backend's JSON-RPC frames.

  These tests pin the field names + plumbing so a future rename
  (`permissionMode` -> `permission_mode`, `model` -> `model_id`, etc.)
  trips a test instead of silently breaking the integration with
  claude-app-server.
  """

  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Workflow

  describe "thread_start_request/1" do
    test "emits permissionMode + cwd in params from the configured workflow" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_permission_mode: "acceptEdits"
      )

      assert %{
               "method" => "thread/start",
               "id" => id,
               "params" => %{
                 "permissionMode" => "acceptEdits",
                 "cwd" => "/tmp/workspace"
               }
             } = ClaudeAgent.thread_start_request("/tmp/workspace")

      assert is_integer(id)
    end

    test "defaults permissionMode to bypassPermissions when the workflow omits it" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_permission_mode: nil
      )

      assert %{"params" => %{"permissionMode" => "bypassPermissions"}} =
               ClaudeAgent.thread_start_request("/tmp/workspace")
    end
  end

  describe "send_operator_message/2 — model plumbing" do
    test "includes params.model when claude.model is set in the workflow" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_model: "claude-sonnet-4-6"
      )

      port = open_cat_port!()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace"
      }

      try do
        assert {:ok, _request_id} =
                 ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello"})

        frame = read_one_frame(port)
        assert frame["method"] == "turn/start"
        assert frame["params"]["model"] == "claude-sonnet-4-6"
      after
        close_port(port)
      end
    end

    test "omits params.model when claude.model is absent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_model: nil
      )

      port = open_cat_port!()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace"
      }

      try do
        assert {:ok, _request_id} =
                 ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello"})

        frame = read_one_frame(port)
        assert frame["method"] == "turn/start"
        refute Map.has_key?(frame["params"], "model")
      after
        close_port(port)
      end
    end
  end

  defp open_cat_port! do
    case System.find_executable("cat") do
      nil ->
        flunk("`cat` not found on PATH; test environment is missing a POSIX cat")

      path ->
        Port.open(
          {:spawn_executable, String.to_charlist(path)},
          [:binary, :exit_status, {:line, 64_000}]
        )
    end
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
