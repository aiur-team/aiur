defmodule Aiur.AgentLogTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentLog

  describe "workspace_log_path/1" do
    test "joins workspace path with logs/agent.md" do
      assert AgentLog.workspace_log_path("/tmp/ws") == "/tmp/ws/logs/agent.md"
    end

    test "returns nil for nil input" do
      assert AgentLog.workspace_log_path(nil) == nil
    end

    test "returns nil for non-binary input" do
      assert AgentLog.workspace_log_path(123) == nil
    end
  end

  describe "workspace_structured_log_path/1" do
    test "joins workspace path with logs/agent.ndjson" do
      assert AgentLog.workspace_structured_log_path("/tmp/ws") == "/tmp/ws/logs/agent.ndjson"
    end

    test "returns nil for invalid input" do
      assert AgentLog.workspace_structured_log_path(nil) == nil
      assert AgentLog.workspace_structured_log_path(123) == nil
    end
  end

  describe "read_workspace/1" do
    test "prefers structured ndjson events over markdown projection" do
      workspace = tmp_workspace()
      File.mkdir_p!(Path.join(workspace, "logs"))

      File.write!(
        Path.join(workspace, "logs/agent.md"),
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "from markdown"}
        })
      )

      File.write!(
        Path.join(workspace, "logs/agent.ndjson"),
        ndjson(%{
          "event" => "notification",
          "timestamp" => "2026-05-10T22:46:39Z",
          "raw" =>
            Jason.encode!(%{
              "method" => "item/agentMessage/delta",
              "params" => %{"delta" => "from ndjson"}
            })
        })
      )

      assert %{path: path, messages: [%{role: "assistant", body: "from ndjson"}]} =
               AgentLog.read_workspace(workspace)

      assert path == Path.join(workspace, "logs/agent.ndjson")
    end

    test "falls back to markdown when structured log is missing" do
      workspace = tmp_workspace()
      File.mkdir_p!(Path.join(workspace, "logs"))

      File.write!(
        Path.join(workspace, "logs/agent.md"),
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "from markdown"}
        })
      )

      assert %{path: path, messages: [%{role: "assistant", body: "from markdown"}]} =
               AgentLog.read_workspace(workspace)

      assert path == Path.join(workspace, "logs/agent.md")
    end

    test "returns no-workspace placeholder when no workspace path is available" do
      assert %{path: nil, messages: [%{role: "system", body: body}]} = AgentLog.read_workspace(nil)
      assert body == "No local workspace path is available for this session."
    end
  end

  describe "read/1" do
    test "returns placeholder when path is nil" do
      assert AgentLog.read(nil) == "No local workspace path is available for this session."
    end

    test "returns placeholder when file does not exist" do
      assert AgentLog.read("/nonexistent/path/agent.md") == "Agent log has not been written yet."
    end

    test "returns read error details for other file errors" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_dir")
      File.mkdir_p!(path)

      try do
        assert AgentLog.read(path) =~ "Unable to read agent log:"
      after
        File.rmdir!(path)
      end
    end

    test "returns placeholder for empty file" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_empty") <> ".md"
      File.write!(path, "")

      try do
        assert AgentLog.read(path) == "Agent log is empty."
      after
        File.rm!(path)
      end
    end

    test "returns file content when readable" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_content") <> ".md"
      File.write!(path, "hello world")

      try do
        assert AgentLog.read(path) == "hello world"
      after
        File.rm!(path)
      end
    end
  end

  defp entry(event, payload) do
    """
    ## 2026-05-10T22:46:39.307486Z #{event}

    ```text
    #{Jason.encode!(payload)}
    ```


    """
  end

  defp ndjson(payload), do: Jason.encode!(payload) <> "\n"

  defp tmp_workspace do
    path = Aiur.TestSupport.tmp_root!("aiur-agent-log")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
