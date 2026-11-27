defmodule Aiur.AgentRunner.NoopFreshThreadTest do
  # OGM core #1433 and its siblings: every requeue resumed the ticket's stored
  # thread, each resumed turn ended in seconds having changed nothing, and the
  # no-op bound sent the ticket to `agent:error`. A thread whose last turn did
  # no work must not be resumed, and a resumed thread that keeps doing nothing
  # must give way to a fresh thread before the bound fails the ticket.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.SessionHandle
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

  setup do
    test_root = Aiur.TestSupport.tmp_root!("noop-fresh-thread")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress", "rework"])
    Aiur.WorkflowStore.force_reload()
    Process.put(:memory_tracker_recipient, self())

    identifier = "NFT-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "rework", labels: ["agent:rework"]}
    :ok = SessionHandle.save(identifier, %{backend: "codex", thread_id: "concluded-thread"})
    {:ok, orchestrator} = FakeOrchestrator.start_link(self())

    on_exit(fn ->
      SessionHandle.clear(identifier)
      Aiur.TestCleanup.rm_rf!(test_root)
    end)

    %{workspace: workspace, issue: issue, orchestrator: orchestrator}
  end

  test "a resumed thread with two empty turns returns for a fresh thread instead of failing the ticket", ctx do
    {result, log} = with_log(fn -> run_loop(ctx, true) end)

    assert {:completed, %{state: "rework"}} = result
    assert log =~ "phase=fresh_thread_restart"
    refute log =~ "phase=noop_bound_reached"
    refute_received {:memory_tracker_state_update, _, "error"}

    # The stored thread is forgotten, so the redispatch cannot resume it.
    assert SessionHandle.load(ctx.issue.identifier, "codex") == :none
    assert SessionHandle.abandoned_thread?(ctx.issue.identifier)
  end

  test "a fresh thread with empty turns still reaches the ordinary no-op bound", ctx do
    log = capture_log(fn -> run_loop(ctx, false) end)

    assert log =~ "phase=noop_bound_reached"
    refute log =~ "phase=fresh_thread_restart"
    assert SessionHandle.load(ctx.issue.identifier, "codex") == :none
  end

  test "rework feedback on an idle ticket forgets the stored thread", ctx do
    idle = %{ctx.issue | state: "human-review", labels: ["agent:human-review"]}
    state = %Aiur.Orchestrator.State{running: %{}, completed: MapSet.new(), claimed: MapSet.new(), retry_attempts: %{}}

    event = %{
      author_trusted?: true,
      comment: %{"body" => "the scope changed: also cover the empty case"},
      issue_state_fetcher: fn _ids -> {:ok, [idle]} end,
      open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
      unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end,
      comment_update_issue_state_fun: fn issue_id, to ->
        send(self(), {:comment_state_write, issue_id, to})
        :ok
      end
    }

    capture_log(fn -> Aiur.Orchestrator.CommentWake.maybe_transition_idle_issue_to_rework(state, ctx.issue.identifier, "issue comment", event, 1) end)

    identifier = ctx.issue.identifier
    assert_received {:comment_state_write, ^identifier, "rework"}
    assert SessionHandle.load(identifier, "codex") == :none
  end

  defp run_loop(ctx, resumed?) do
    for _ <- 1..10, do: send(self(), {:resume_agent, 1})

    TurnLoop.run_turns(
      %{backend: "codex", workspace: ctx.workspace, worker_host: nil, resumed: resumed?},
      ctx.workspace,
      ctx.issue,
      nil,
      [
        resumed: true,
        run_turn: fn _s, _p, _i, _o -> {:ok, %{session_id: "empty-turn"}} end,
        workspace_probe: fn _workspace, _host -> {:ok, "unchanged-workspace"} end,
        max_consecutive_noop_turns: 3,
        noop_backoff_ms: 0,
        open_pr_fetcher: fn _ -> {:ok, nil} end
      ],
      fn _ids -> {:ok, [ctx.issue]} end,
      ctx.orchestrator,
      nil,
      1,
      nil
    )
  end
end
