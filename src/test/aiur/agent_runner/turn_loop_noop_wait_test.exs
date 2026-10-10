defmodule Aiur.AgentRunner.TurnLoopNoopWaitTest do
  # U4-T02: the first no-op turn parks the worker in the wait-for-operator-message
  # state instead of starting another continuation turn; a wake for this ticket
  # (or an operator resume) ends the wait.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, state), do: {:reply, :empty, state}
    def handle_call({:consume_delivered_queue_items, _identifier}, _from, state), do: {:reply, :ok, state}
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("turn-loop-noop-wait")
    workspace = Path.join(root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    active_state = Enum.at(Aiur.Config.settings!().tracker.active_states, 0)
    identifier = "TL-U4T02-#{System.unique_integer([:positive])}"

    issue = %Aiur.Issue{
      id: "gid-#{identifier}",
      identifier: identifier,
      state: active_state,
      labels: ["agent:#{active_state}"]
    }

    {:ok, orchestrator} = FakeOrchestrator.start_link(nil)
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> File.rm_rf(root) end)

    %{workspace: workspace, issue: issue, orchestrator: orchestrator, turns: turns}
  end

  test "first no-op turn waits instead of continuing", ctx do
    task = start_loop(ctx)

    assert eventually(fn -> Agent.get(ctx.turns, & &1) == 3 end)
    Process.sleep(150)
    assert Agent.get(ctx.turns, & &1) == 3
    assert Task.yield(task, 0) == nil

    send(task.pid, {:resume_agent, 1})
    assert eventually(fn -> Agent.get(ctx.turns, & &1) == 4 end)
    stop(task)
  end

  test "an event for another ticket does not wake", ctx do
    task = start_loop(ctx)
    assert eventually(fn -> Agent.get(ctx.turns, & &1) == 3 end)

    send(task.pid, {:agent_queue_updated, "SOME-OTHER-TICKET", 1, true})
    Process.sleep(150)
    assert Agent.get(ctx.turns, & &1) == 3
    stop(task)
  end

  test "a wake already in the mailbox is not lost", ctx do
    task = start_loop(ctx, wake_first: true)

    assert eventually(fn -> Agent.get(ctx.turns, & &1) == 4 end)
    Process.sleep(150)
    assert Agent.get(ctx.turns, & &1) == 4
    stop(task)
  end

  test "a park with no wake times out and the no-op bound still ends the run", ctx do
    task = start_loop(ctx, park_timeout_ms: 50)

    # No wake is ever sent: only the timer resumes the worker, and the
    # surviving no-op count must still end the run at the cap.
    assert {:ok, result} = Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill)
    refute match?({:error, _}, result)
    turns = Agent.get(ctx.turns, & &1)
    assert turns >= 4
    Process.sleep(200)
    assert Agent.get(ctx.turns, & &1) == turns
  end

  # #3971 on the park path: fixes pushed by an earlier run must hand back to
  # review at the first no-op, not park waiting for a review event that never comes.
  test "a rework whose head is newer than its blocking review hands off instead of parking", ctx do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress", "rework"])
    Aiur.WorkflowStore.force_reload()
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}
    review = %{"state" => "CHANGES_REQUESTED", "commit_id" => "reviewed-head", "user" => %{"login" => "r"}, authoritative: true}

    task =
      Task.async(fn ->
        TurnLoop.run_turns(
          %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
          ctx.workspace,
          issue,
          nil,
          [
            resumed: true,
            run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-park-rework"}} end,
            workspace_probe: fn _workspace, _worker_host -> {:ok, "unchanged-workspace"} end,
            max_consecutive_noop_turns: 3,
            noop_park_timeout_ms: 0,
            rework_head_sha: "fixed-head",
            open_pr_fetcher: fn _ -> {:ok, %{"number" => 42, "head" => %{"sha" => "fixed-head"}}} end,
            reviews_fetcher: fn 42 -> {:ok, [review]} end,
            commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
          ],
          fn _ids -> {:ok, [issue]} end,
          ctx.orchestrator,
          nil,
          1,
          nil
        )
      end)

    assert {:ok, {:completed, %{state: "human-review"}}} = Task.yield(task, 3000) || Task.shutdown(task, :brutal_kill)
  end

  defp start_loop(ctx, opts \\ []) do
    turns = ctx.turns

    Task.async(fn ->
      if opts[:wake_first], do: send(self(), {:resume_agent, 1})

      TurnLoop.run_turns(
        %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
        ctx.workspace,
        ctx.issue,
        nil,
        [
          resumed: true,
          run_turn: fn _s, _p, _i, _o ->
            Agent.update(turns, &(&1 + 1))
            {:ok, %{session_id: "noop-wait"}}
          end,
          workspace_probe: fn _workspace, _worker_host -> {:ok, "unchanged-workspace"} end,
          max_consecutive_noop_turns: 3,
          noop_park_timeout_ms: Keyword.get(opts, :park_timeout_ms, 0),
          open_pr_fetcher: fn _ -> {:ok, nil} end
        ],
        fn _ids -> {:ok, [ctx.issue]} end,
        ctx.orchestrator,
        nil,
        1,
        nil
      )
    end)
  end

  defp stop(task), do: Task.shutdown(task, :brutal_kill)

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
