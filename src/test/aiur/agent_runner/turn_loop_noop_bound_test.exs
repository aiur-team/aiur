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
  alias Aiur.Orchestrator.{RetryEngine, State}
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
    test "hands off a pushed rework PR after three no-op turns", ctx do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      Aiur.WorkflowStore.force_reload()
      Application.put_env(:aiur, :memory_tracker_recipient, self())
      issue = %{ctx.issue | title: "Retry push handoff", state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "human-review"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-rework"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "before-push",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "after-push"}}} end,
                 commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
               )

      assert_receive {:memory_tracker_state_update, identifier, "human-review"}
      assert identifier == issue.identifier
    end

    test "keeps the pre-push head across retry dispatch until the no-op handoff", ctx do
      use_memory_tracker!(self())
      issue = %{ctx.issue | title: "Retry push handoff", state: "rework", labels: ["agent:rework"]}
      parent = self()

      assert {:noreply, _retry_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
                 issue.id,
                 2,
                 %{worker_host: nil, prior_work: true, rework_head_sha: "before-push"},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn state, _issue, _attempt, _worker_host, dispatch_opts ->
                   send(parent, {:retry_dispatch_opts, dispatch_opts})
                   put_in(state.running[issue.id], %{pid: parent})
                 end
               )

      assert_receive {:retry_dispatch_opts, dispatch_opts}, 1000
      assert dispatch_opts[:rework_head_sha] == "before-push"

      assert {:completed, %{state: "human-review"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "retry-after-push"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: dispatch_opts[:rework_head_sha],
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "after-push"}}} end,
                 commit_ci_status_fetcher: fn _ ->
                   {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}}
                 end
               )

      assert_receive {:memory_tracker_state_update, identifier, "human-review"}
      assert identifier == issue.identifier
    end

    test "uses ci-wait when checks are pending after the push", ctx do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      Aiur.WorkflowStore.force_reload()
      Application.put_env(:aiur, :memory_tracker_recipient, self())
      issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "ci-wait"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-rework-pending"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "before-push",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "after-push"}}} end,
                 commit_ci_status_fetcher: fn _ ->
                   {:ok, %{check_runs: [%{"status" => "queued"}], commit_status: %{"state" => "pending"}}}
                 end
               )

      assert_receive {:memory_tracker_state_update, identifier, "ci-wait"}
      assert identifier == issue.identifier
    end

    test "hands off for review when the PR head lookup fails", ctx do
      use_memory_tracker!(self())
      issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "human-review"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-pr-read-failed"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "before-push",
                 open_pr_fetcher: fn _ -> {:error, :rate_limited} end
               )

      assert_receive {:memory_tracker_state_update, identifier, "human-review"}
      assert identifier == issue.identifier
    end

    test "keeps the ticket in ci-wait when CI status cannot be read", ctx do
      use_memory_tracker!(self())
      issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "ci-wait"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-ci-read-failed"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "before-push",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "after-push"}}} end,
                 commit_ci_status_fetcher: fn _ -> {:error, :rate_limited} end
               )

      assert_receive {:memory_tracker_state_update, identifier, "ci-wait"}
      assert identifier == issue.identifier
    end

    test "hands uncertain rework to review when the initial head lookup failed", ctx do
      use_memory_tracker!(self())
      issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "human-review"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-baseline-unknown"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: :lookup_failed,
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end,
                 commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end
               )

      assert_receive {:memory_tracker_state_update, identifier, "human-review"}
      assert identifier == issue.identifier
    end

    test "marks a rework with no pushed head as error after three no-op turns", ctx do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      Aiur.WorkflowStore.force_reload()
      Application.put_env(:aiur, :memory_tracker_recipient, self())
      issue = %{ctx.issue | state: "rework"}

      assert {:completed, %{state: "error"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-rework-no-push"}} end,
                 max_turns: nil,
                 workspace_probe: unchanging_probe(),
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 rework_head_sha: "same-head",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "same-head"}}} end
               )

      assert_receive {:memory_tracker_state_update, identifier, "error"}
      assert identifier == issue.identifier
    end

    test "hands off a pushed rework PR when the normal turn limit stops the run", ctx do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      Aiur.WorkflowStore.force_reload()
      Application.put_env(:aiur, :memory_tracker_recipient, self())
      issue = %{ctx.issue | state: "rework", labels: ["agent:rework"]}

      assert {:completed, %{state: "human-review"}} =
               run_loop(%{ctx | issue: issue},
                 run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "rework-at-turn-limit"}} end,
                 max_turns: 1,
                 workspace_probe: unchanging_probe(),
                 rework_head_sha: "before-push",
                 open_pr_fetcher: fn _ -> {:ok, %{"head" => %{"sha" => "after-push"}}} end,
                 commit_ci_status_fetcher: fn _ ->
                   {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}}
                 end
               )

      assert_receive {:memory_tracker_state_update, identifier, "human-review"}
      assert identifier == issue.identifier
    end

    test "stops itself instead of re-prompting forever", ctx do
      use_memory_tracker!(self())
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
      use_memory_tracker!(self())

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
      assert log =~ "Review the agent's result before redispatching"
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

  defp use_memory_tracker!(recipient) do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Application.put_env(:aiur, :memory_tracker_recipient, recipient)
  end

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
