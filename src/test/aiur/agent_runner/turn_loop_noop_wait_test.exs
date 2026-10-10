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
