defmodule Aiur.Claude.ConfigTest do
  use Aiur.TestSupport

  alias Aiur.Claude.Config, as: ClaudeConfig
  alias Aiur.Workflow

  test "model and version default to nil when unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      command: "aiur-claude"
    )

    assert ClaudeConfig.model() == nil
    assert ClaudeConfig.version() == nil
  end

  test "model and version read from the claude section" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      command: "aiur-claude",
      claude_model: "claude-opus-4-8",
      claude_version: "opus-4-8"
    )

    assert ClaudeConfig.model() == "claude-opus-4-8"
    assert ClaudeConfig.version() == "opus-4-8"
  end

  test "command falls back to the aiur-claude default" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", command: nil)

    assert ClaudeConfig.command() == "aiur-claude"
  end

  test "permission_mode defaults to bypassPermissions when unset" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", command: "aiur-claude")

    assert ClaudeConfig.permission_mode() == "bypassPermissions"
  end

  test "permission_mode reads a valid value from the claude section" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      command: "aiur-claude",
      claude_permission_mode: "acceptEdits"
    )

    assert ClaudeConfig.permission_mode() == "acceptEdits"
  end

  test "permission_mode falls back to the default for an invalid value" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      command: "aiur-claude",
      claude_permission_mode: "wideOpen"
    )

    assert ClaudeConfig.permission_mode() == "bypassPermissions"
  end
end
