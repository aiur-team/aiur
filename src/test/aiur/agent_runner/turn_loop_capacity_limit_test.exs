defmodule Aiur.AgentRunner.TurnLoopCapacityLimitTest do
  # #7958: a hard USD limit crossed while an agent runs stops new turns on that
  # source at the next turn boundary. Drives the real `run_turns/10` recursion.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(report), do: GenServer.start_link(__MODULE__, report)

    @impl true
    def init(report), do: {:ok, report}
    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, report), do: {:reply, :empty, report}
    def handle_call({:control_capabilities, _identifier}, _from, report), do: {:reply, {:ok, %{queue_depth: 0}}, report}
    def handle_call({:consume_delivered_queue_items, _identifier}, _from, report), do: {:reply, :ok, report}
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, report), do: {:reply, :ok, report}
    def handle_call({:fail_delivered_queue_items, _identifier, _reason}, _from, report), do: {:reply, :ok, report}
  end

  @policy %{sources: %{"claude" => %{billing: "metered", limits: %{daily_usd: 5}}}}

  setup do
    test_root = Aiur.TestSupport.tmp_root!("turn-loop-capacity-limit")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    active_state = Enum.at(Aiur.Config.settings!().tracker.active_states, 0)
    identifier = "TL-7958-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: active_state, labels: ["agent:#{active_state}"]}
    {:ok, orchestrator} = FakeOrchestrator.start_link(self())
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

    %{workspace: workspace, issue: issue, orchestrator: orchestrator}
  end

  test "a running agent on a source past its daily limit starts no new turn", ctx do
    assert {{:completed, _issue}, 1} = run(ctx, %{"claude" => %{daily_usd: 5.0}})
  end

  test "unknown spend under a limit stops too", ctx do
    assert {{:completed, _issue}, 1} = run(ctx, %{})
  end

  test "an agent under the limit keeps taking turns", ctx do
    assert {{:completed, _issue}, 3} = run(ctx, %{"claude" => %{daily_usd: 4.99}})
  end

  defp run(ctx, spend) do
    {:ok, turns} = Agent.start_link(fn -> 0 end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # Every turn moves the workspace on, so the no-op bound never decides.
    probe = fn _workspace, _worker_host -> {:ok, "digest-#{Agent.get_and_update(calls, &{&1, &1 + 1})}"} end

    run_turn = fn _session, _prompt, _issue, _opts ->
      Agent.update(turns, &(&1 + 1))
      {:ok, %{session_id: "capacity-turn"}}
    end

    opts = [
      run_turn: run_turn,
      resumed: true,
      workspace_probe: probe,
      noop_backoff_ms: 0,
      capacity_policy: @policy,
      capacity_spend: spend,
      ledger_store: nil
    ]

    result =
      TurnLoop.run_turns(%{backend: "claude", workspace: ctx.workspace, worker_host: nil}, ctx.workspace, ctx.issue, nil, opts, fn _ids -> {:ok, [ctx.issue]} end, ctx.orchestrator, nil, 1, 3)

    {result, Agent.get(turns, & &1)}
  end
end
