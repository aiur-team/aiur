defmodule Aiur.OperatorRelayConfigTest do
  use Aiur.TestSupport
  alias Aiur.Events.Exchange

  test "enabling the relay gate on reload alerts once and preserves the disabled default" do
    ensure_workflow_store_running()
    :ok = Exchange.subscribe("system.config.operator_relay.enabled")
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    refute Config.relay_operator_answers?()

    File.write!(path, original <> "\nexecutor: {relay_operator_answers: true}\n")
    assert :ok = WorkflowStore.force_reload()
    assert Config.relay_operator_answers?()
    assert_receive {:event, event}, 2_000
    assert event.topic == "system.config.operator_relay.enabled"
    assert event["message"] =~ "executor.relay_operator_answers enabled"
    assert event["severity"] == "info"

    assert :ok = WorkflowStore.force_reload()
    refute_receive {:event, _event}, 100
    File.write!(path, original)
    assert :ok = WorkflowStore.force_reload()
    refute Config.relay_operator_answers?()
    refute_receive {:event, _event}, 100
  end
end
