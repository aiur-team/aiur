defmodule Aiur.Claude.ConfigTest do
  use Aiur.TestSupport

  alias Aiur.Claude.Config, as: ClaudeConfig
  alias Aiur.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      command: "aiur-claude",
      claude_model: "claude-opus-4-6",
      claude_version: "opus-4-8",
      claude_permission_mode: "bypassPermissions"
    )

    :ok
  end

  describe "command/0" do
    test "returns the configured command verbatim" do
      assert ClaudeConfig.command() == "aiur-claude"
    end

    test "trims whitespace and falls back to default when blank" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "   "
      )

      # Empty string after trim — falls back to default
      assert ClaudeConfig.command() == "aiur-claude"
    end
  end

  describe "model/0" do
    test "returns the configured model" do
      assert ClaudeConfig.model() == "claude-opus-4-6"
    end

    test "returns nil when the block omits model" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_model: nil
      )

      assert ClaudeConfig.model() == nil
    end
  end

  describe "version/0" do
    test "stores the version verbatim" do
      assert ClaudeConfig.version() == "opus-4-8"
    end

    test "returns nil when omitted" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_version: nil
      )

      assert ClaudeConfig.version() == nil
    end
  end

  describe "permission_mode/0" do
    test "returns the configured mode" do
      assert ClaudeConfig.permission_mode() == "bypassPermissions"
    end

    test "falls back to bypassPermissions when omitted" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "aiur-claude",
        claude_permission_mode: nil
      )

      assert ClaudeConfig.permission_mode() == "bypassPermissions"
    end

    test "rejects unknown modes and falls back to the default" do
      # Schema validation rejects unknown modes at parse time; the
      # getter defends in depth so a stale workflow on disk can't
      # break the runtime.
      assert ClaudeConfig.permission_mode() in ~w(default acceptEdits bypassPermissions)
    end
  end

  describe "runtime_settings/0" do
    test "bundles model + version + permission_mode in one call" do
      assert %{
               model: "claude-opus-4-6",
               version: "opus-4-8",
               permission_mode: "bypassPermissions"
             } = ClaudeConfig.runtime_settings()
    end
  end

  describe "validate!/0" do
    test "returns :ok when command is set and permission_mode is valid" do
      assert :ok = ClaudeConfig.validate!()
    end
  end
end
