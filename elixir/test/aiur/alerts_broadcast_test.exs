defmodule Aiur.AlertsBroadcastTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Alerts}

  test "emit_custom broadcasts an alert on the agent topic when an identifier is supplied" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alerts-bc-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf!(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    :ok = AgentPubSub.subscribe_agent("MT-ALERT-BC")

    assert :ok =
             Alerts.emit_custom("demo.heads_up", "look here", identifier: "MT-ALERT-BC")

    assert_receive {:alert, %{name: "demo.heads_up", message: "look here"}}, 500
  end

  test "alerts without an identifier do not broadcast on a per-agent topic" do
    workspace_root =
      Path.join(System.tmp_dir!(), "aiur-alerts-nobc-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf!(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    :ok = AgentPubSub.subscribe_agent("MT-ALERT-OTHER")

    assert :ok = Alerts.emit_custom("demo.heads_up", "no target")

    refute_receive {:alert, _}, 100
  end
end
