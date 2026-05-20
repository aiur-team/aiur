defmodule Aiur.Opencode.ConfigTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Opencode.Config

  describe "workflow settings" do
    test "uses defaults when opencode section is omitted" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), opencode_command: nil)

      assert Config.command() == "opencode"
      assert Config.bridge_host() == "127.0.0.1"
      assert Config.bridge_port() == 4097
      assert Config.model_prefix() == "aiur"
      assert Config.serve_args() == []
    end

    test "reads overrides from WORKFLOW.md" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        opencode_command: "/tmp/opencode",
        opencode_bridge_port: 5000,
        opencode_bridge_host: "127.0.0.2",
        opencode_serve_args: ["--log-level", "debug"],
        opencode_model_prefix: "custom"
      )

      assert Config.command() == "/tmp/opencode"
      assert Config.bridge_port() == 5000
      assert Config.bridge_host() == "127.0.0.2"
      assert Config.serve_args() == ["--log-level", "debug"]
      assert Config.model_prefix() == "custom"
    end

    test "blank command falls back to default" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), opencode_command: "")

      assert Config.command() == "opencode"
    end
  end

  test "model_for_issue uses workspace-safe identifiers" do
    assert Config.model_for_issue("MT-123") == "aiur/issue-MT-123"
    assert Config.model_for_issue("MT 123/unsafe") == "aiur/issue-MT_123_unsafe"
  end

  test "validate! reports missing executable" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), opencode_command: "definitely-not-opencode")

    assert {:error, message} = Config.validate!()
    assert message =~ "opencode.command"
  end

  test "Aiur.Config.validate! surfaces missing opencode executable" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), opencode_command: "definitely-not-opencode")

    assert {:error, message} = Aiur.Config.validate!()
    assert message =~ "opencode.command"
  end
end
