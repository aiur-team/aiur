defmodule Aiur.AgentRunner.TurnLoopNoopBoundTest do
  # #2806: on khala #198 a mislabelled ticket took eleven continuation turns in
  # under two minutes with nothing to act on. `finalize_turn_completion/3`
  # tail-called itself on nothing but the ticket's state label: no no-op
  # counter, no backoff, no dedupe, and `agent.max_turns` nil by default.
  #
  # These tests drive the real `run_turns/10` recursion with a provider stub
  # that changes nothing, and assert the loop stops itself and leaves a durable
  # record — and, in the mirror-image test, that a run of genuinely productive
  # turns is never bounded by this path.
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

    def handle_call({:consume_delivered_queue_items, _identifier}, _from, report), do: {:reply, :ok, report}
    def handle_call({:restore_delivered_queue_items, _identifier}, _from, report), do: {:reply, :ok, report}
    def handle_call({:fail_delivered_queue_items, _identifier, _reason}, _from, report), do: {:reply, :ok, report}
  end

  setup do
    test_root = Aiur.TestSupport.tmp_root!("turn-loop-noop-bound")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    # Pick a state the workflow config actually treats as active, so the loop's
    # decision is made by the no-op bound rather than by an inactive label.
    active_state = Enum.at(Aiur.Config.settings!().tracker.active_states, 0)

    identifier = "TL-2806-#{System.unique_integer([:positive])}"

    issue = %Aiur.Issue{
      id: "gid-#{identifier}",
      identifier: identifier,
      state: active_state,
      labels: ["agent:#{active_state}"]
    }

    {:ok, orchestrator} = FakeOrchestrator.start_link(self())

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace: workspace, issue: issue, orchestrator: orchestrator}
  end

  describe "a run of consecutive no-op turns" do
    test "stops itself instead of re-prompting forever", ctx do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      run_turn = fn _session, prompt, _issue, _opts ->
        Agent.update(calls, &[prompt | &1])
        {:ok, %{session_id: "noop-turn"}}
      end

      # max_turns: nil is the shipped default — the absolute cap cannot end this
      # run, so only the no-op bound can.
      assert {:completed, _issue} =
               run_loop(ctx,
                 run_turn: run_turn,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0
               )

      prompts = Agent.get(calls, &Enum.reverse(&1))

      # Bounded, and bounded tightly: turn 1 does the work, turn 2 is the first
      # comparable continuation prompt, then three consecutive no-op turns trip
      # the cap. Eleven-plus turns is what this test exists to forbid.
      assert length(prompts) == 5

      assert Enum.at(prompts, 1) =~ "continuation turn #2"
      # The loop tells the agent its turns are changing nothing instead of
      # handing it the same prompt harder.
      assert Enum.at(prompts, 3) =~ "Aiur observed that the last"
    end

    test "leaves a durable needs-attention record naming the ticket", ctx do
      assert {:completed, _issue} =
               run_loop(ctx,
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-turn"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0
               )

      log = File.read!(Path.join([ctx.workspace, "logs", "agent.ndjson"]))

      assert log =~ "ticket.#{ctx.issue.identifier}.agent.noop_turns_bounded"
      assert log =~ "\"needs_attention\":true"
      assert log =~ "consecutive turn(s) that changed nothing"
      # The record says what to do about it, so the stop is actionable rather
      # than just observable.
      assert log =~ "Check the state label"
    end
  end

  describe "a run of productive turns" do
    test "is never bounded by the no-op cap", ctx do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # Every turn moves the workspace on, exactly as a turn that commits does.
      probe = fn _workspace, _worker_host ->
        {:ok, "digest-" <> Integer.to_string(Agent.get_and_update(calls, &{&1, &1 + 1}))}
      end

      {:ok, turns} = Agent.start_link(fn -> 0 end)

      run_turn = fn _session, _prompt, _issue, _opts ->
        Agent.update(turns, &(&1 + 1))
        {:ok, %{session_id: "productive-turn"}}
      end

      # max_turns ends this run; the no-op cap must not.
      assert {:completed, _issue} =
               run_loop(ctx,
                 run_turn: run_turn,
                 max_turns: 8,
                 workspace_probe: probe,
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0
               )

      assert Agent.get(turns, & &1) == 8

      log_path = Path.join([ctx.workspace, "logs", "agent.ndjson"])
      log = if File.exists?(log_path), do: File.read!(log_path), else: ""
      refute log =~ "noop_turns_bounded"
    end
  end

  defp unchanging_probe, do: fn _workspace, _worker_host -> {:ok, "unchanged-workspace"} end

  defp run_loop(ctx, opts) do
    {max_turns, opts} = Keyword.pop!(opts, :max_turns)
    # `resumed: true` keeps turn 1 on the inline resumed prompt instead of
    # rebuilding the full cold-start prompt, exactly as the sibling
    # `turn_loop_agent_support_test` does.
    opts = Keyword.put(opts, :resumed, true)

    TurnLoop.run_turns(
      %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
      ctx.workspace,
      ctx.issue,
      nil,
      opts,
      fn _ids -> {:ok, [ctx.issue]} end,
      ctx.orchestrator,
      nil,
      1,
      max_turns
    )
  end
end
