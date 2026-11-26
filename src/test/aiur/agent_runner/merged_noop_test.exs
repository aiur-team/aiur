defmodule Aiur.AgentRunner.MergedNoopTest do
  # Open-games #480 (2026-11-15): PR #517 merged while the ticket stayed open.
  # With no open PR the worker could not hand back, every no-op stop kept
  # `agent:in-progress`, and the ticket was dispatched six times in 25 minutes
  # before a rework relabel ended it in `agent:error`. #432, #511, #518 and #520
  # did the same. Drives the real `run_turns/10` recursion.
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

  @branch "aiur/480-mode-screen"
  @worker_says "No agent work remains. PR #517 is merged; the character screen waits on a creator pick."

  setup do
    test_root = Aiur.TestSupport.tmp_root!("merged-noop")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", @branch, workspace])
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    File.mkdir_p!(Path.join(workspace, "logs"))
    File.write!(Path.join(workspace, "logs/agent.ndjson"), Jason.encode!(%{"event" => "agent_message", "last_message" => @worker_says}) <> "\n")

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Process.put(:memory_tracker_recipient, self())

    identifier = "480#{System.unique_integer([:positive])}"
    {:ok, orchestrator} = FakeOrchestrator.start_link(self())
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

    %{workspace: workspace, identifier: identifier, orchestrator: orchestrator}
  end

  for state <- ["in-progress", "rework"] do
    test "a no-op turn after the PR merged hands a #{state} ticket to human review with the worker's reason", ctx do
      parent = self()
      issue = issue(ctx, unquote(state))

      assert {:completed, %{state: "human-review"}} =
               run_loop(ctx, issue,
                 merged_pr_fetcher: fn branch ->
                   send(parent, {:merged_lookup, branch})
                   {:ok, %{"number" => 517, "merged_at" => "2026-11-15T19:04:54Z"}}
                 end
               )

      assert_received {:merged_lookup, @branch}
      identifier = issue.identifier
      assert_received {:memory_tracker_state_update, ^identifier, "human-review"}
      refute_received {:memory_tracker_state_update, ^identifier, "error"}
      assert_received {:memory_tracker_comment, ^identifier, comment}
      assert comment =~ "PR #517 is merged"
      assert comment =~ @worker_says
      # Handed back at the first unchanged turn, not after the no-op limit.
      assert comment =~ "the worker's last turn changed nothing"
      refute_received {:memory_tracker_comment, ^identifier, _limit_comment}
    end
  end

  test "a ticket whose branch has no merged PR keeps the earlier no-PR stop", ctx do
    issue = issue(ctx, "in-progress")

    assert {:completed, %{state: "in-progress"}} = run_loop(ctx, issue, merged_pr_fetcher: fn _branch -> {:ok, nil} end)

    identifier = issue.identifier
    refute_received {:memory_tracker_state_update, ^identifier, "human-review"}
    assert_received {:memory_tracker_comment, ^identifier, comment}
    assert comment =~ "no-op turn limit"
  end

  defp issue(ctx, state), do: %Aiur.Issue{id: "gid-#{ctx.identifier}", identifier: ctx.identifier, state: state, labels: ["agent:#{state}"]}

  defp run_loop(ctx, issue, opts) do
    for _ <- 1..10, do: send(self(), {:resume_agent, 1})

    opts =
      Keyword.merge(
        [
          run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "noop-after-merge"}} end,
          workspace_probe: fn _workspace, _worker_host -> {:ok, "unchanged-workspace"} end,
          max_consecutive_noop_turns: 3,
          noop_backoff_ms: 0,
          open_pr_fetcher: fn _ -> {:ok, nil} end,
          resumed: true
        ],
        opts
      )

    TurnLoop.run_turns(
      %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
      ctx.workspace,
      issue,
      nil,
      opts,
      fn _ids -> {:ok, [issue]} end,
      ctx.orchestrator,
      nil,
      1,
      nil
    )
  end
end
