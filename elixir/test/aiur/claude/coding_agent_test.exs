defmodule Aiur.Claude.CodingAgentWorkspaceTest do
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Workflow

  test "spawned claude shell receives the AIUR_AGENT_WORKSPACE guard var" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_env_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    marker = Path.join(workspace, "env_marker")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      # The fake app-server records the guard var the spawned shell sees,
      # then idles so the initialize handshake reads back nothing and
      # start_session returns a timeout error. The marker is written first.
      command: "printenv AIUR_AGENT_WORKSPACE > #{marker}; sleep 2",
      agent_read_timeout_ms: 300
    )

    assert {:error, _reason} = ClaudeAgent.start_session(workspace)
    assert File.exists?(marker)
    assert String.trim(File.read!(marker)) == workspace
  end

  test "turn/start carries the configured model and completes a turn" do
    root = Path.join(System.tmp_dir!(), "aiur_claude_model_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      claude_model: "claude-opus-4-8",
      command: fake_app_server(frames)
    )

    issue = %{id: 1, identifier: "test:1", title: "demo"}

    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    assert {:ok, result} = ClaudeAgent.run_turn(session, "do the thing", issue)
    assert result.result == :turn_completed
    ClaudeAgent.stop_session(session)

    turn_frame =
      frames
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "turn/start"))

    assert turn_frame["params"]["model"] == "claude-opus-4-8"
  end

  # Minimal bash stand-in for the Claude app-server: records every frame
  # it receives to `frames`, and replies to the fixed initialize(1) /
  # thread/start(2) / turn/start(3) request ids so a full turn completes.
  # Single line + echo (no backslash escapes) so it survives YAML scalar
  # round-tripping in the generated WORKFLOW file.
  defp fake_app_server(frames) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{completed}' ;; " <>
      "esac; done"
  end
end
