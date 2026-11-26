defmodule Aiur.Experiments.AnalystTriggerTest do
  use Aiur.TestSupport
  alias Aiur.Events.Exchange
  alias Aiur.Experiments.AnalystTrigger

  test "component-owned subscriber accepts X3 events, skips release specs and routes confirmatory reports" do
    parent = self()
    pid = start_supervised!({AnalystTrigger, start_paused?: true, enabled: fn -> true end, request: fn id, opts -> send(parent, {:request, id, opts}) end})
    event = %{experiment_id: "feature-exp", kind: "feature", topic: "experiment.created"}
    Exchange.publish(event.topic, event)
    :sys.get_state(pid)
    assert_receive {:request, "feature-exp", opts}, 1_000
    assert opts[:mode] == "spec"
    assert opts[:trigger] == "created"
    Exchange.publish(event.topic, %{event | kind: "release"})
    :sys.get_state(pid)
    refute_received {:request, _, _}

    for topic <- ["system.experiment.feature-exp.preregister", "experiment.sample_guard_met", "experiment.planned_n_met"] do
      Exchange.publish(topic, Map.put(event, :topic, topic))
      :sys.get_state(pid)
      assert_receive {:request, "feature-exp", received}, 1_000
      assert received[:mode] == if(String.ends_with?(topic, "preregister"), do: "spec", else: "report")
      if String.ends_with?(topic, "planned_n_met"), do: assert(received[:analysis_type] == "confirmatory")
    end
  end

  test "auto_request false prevents requests through the real subscriber" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path)
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  analyst:\n    auto_request: false\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Config.settings!().experiments.analyst.auto_request == false
    assert Aiur.Config.telemetry_enabled?() == true
    parent = self()
    pid = start_supervised!({AnalystTrigger, start_paused?: true, request: fn id, opts -> send(parent, {:request, id, opts}) end})
    Exchange.publish("experiment.created", %{topic: "experiment.created", experiment_id: "feature-exp", kind: "feature"})
    :sys.get_state(pid)
    refute_received {:request, _, _}
  end
end
