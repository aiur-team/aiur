defmodule Aiur.OrchestratorBroadcastTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Orchestrator, Workflow}

  test "orchestrator broadcasts a running-set change on its first tick" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_seconds: 5
    )

    :ok = AgentPubSub.subscribe_running()

    orchestrator_name = Module.concat(__MODULE__, :BroadcastTestOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    assert_receive {:running_changed, summaries}, 1_000
    assert is_list(summaries)
  end
end
