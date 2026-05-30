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
end
