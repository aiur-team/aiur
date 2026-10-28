defmodule Aiur.AgentRunner.NoopBoundOpenFindingsTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, nil)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:claim_next_queue_item, _}, _, state), do: {:reply, :empty, state}
    def handle_call({:control_capabilities, _}, _, state), do: {:reply, {:ok, %{queue_depth: 0}}, state}
    def handle_call({:consume_delivered_queue_items, _}, _, state), do: {:reply, :ok, state}
    def handle_call({:restore_delivered_queue_items, _}, _, state), do: {:reply, :ok, state}
  end

  test "no-op bound keeps the ticket in rework while findings are open" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress", "rework"])
    Aiur.WorkflowStore.force_reload()
    root = Aiur.TestSupport.tmp_root!("noop-bound-open-findings")
    workspace = Path.join(root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    issue = %Aiur.Issue{id: "gid-5746-noop", identifier: "5746-noop-#{System.unique_integer([:positive])}", state: "rework", labels: ["agent:rework"]}
    {:ok, orchestrator} = FakeOrchestrator.start_link()

    review = %{
      "state" => "CHANGES_REQUESTED",
      "body" => "1. turn_completion.ex:162 keep the finding open",
      "commit_id" => "same-head",
      "submitted_at" => "2026-10-22T05:46:21Z",
      "id" => 1,
      "user" => %{"login" => "r"},
      authoritative: true
    }

    for _ <- 1..10, do: send(self(), {:resume_agent, 1})

    assert {:completed, %{state: "rework"}} =
             TurnLoop.run_turns(
               %{backend: "claude", workspace: workspace, worker_host: nil},
               workspace,
               issue,
               nil,
               [
                 resumed: true,
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-open-findings"}} end,
                 workspace_probe: fn _workspace, _worker_host -> {:ok, "unchanged"} end,
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "same-head",
                 open_pr_fetcher: fn _ -> {:ok, %{"number" => 42, "head" => %{"sha" => "same-head"}}} end,
                 reviews_fetcher: fn 42 -> {:ok, [review]} end
               ],
               fn _ -> {:ok, [issue]} end,
               orchestrator,
               nil,
               1,
               nil
             )
  end
end
