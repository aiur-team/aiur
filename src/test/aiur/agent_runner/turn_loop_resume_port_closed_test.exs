defmodule Aiur.AgentRunner.TurnLoopResumePortClosedTest do
  # #4561: the runner must count a resumed session's turn-start port loss, but
  # only on a dispatch's first turn — a later turn's loss is not a resume failure.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.SessionResume
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.AppServer.Rpc.StreamDiagnostics
  alias Aiur.SessionHandle
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, state), do: {:reply, :empty, state}
    def handle_call(_request, _from, state), do: {:reply, :ok, state}
  end

  @port_closed {:error, {:turn_start_failed, :port_closed}}

  setup do
    test_root = Aiur.TestSupport.tmp_root!("turn-loop-resume-port-closed")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    identifier = "TL-4561-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "In Progress"}
    {:ok, orchestrator} = FakeOrchestrator.start_link(nil)
    :ok = SessionHandle.save(identifier, %{backend: "codex", thread_id: "big"})

    on_exit(fn ->
      SessionHandle.clear(identifier)
      Aiur.TestCleanup.rm_rf!(test_root)
    end)

    %{workspace: workspace, issue: issue, orchestrator: orchestrator}
  end

  test "future regression guard: repeated resumed closes make the next dispatch fresh", ctx do
    StreamDiagnostics.record(self(), "provider startup banner: thread transport closed")

    log =
      capture_log(fn ->
        assert @port_closed = dispatch(ctx, fn _turn -> @port_closed end)
        assert {:ok, %{thread_id: "big"}} = SessionHandle.load(ctx.issue.identifier, "codex")

        assert @port_closed = dispatch(ctx, fn _turn -> @port_closed end)
      end)

    assert SessionHandle.load(ctx.issue.identifier, "codex") == :none
    assert SessionHandle.abandoned_thread?(ctx.issue.identifier)
    assert log =~ ~s(stream_diagnostics="provider startup banner: thread transport closed")

    resume_thread_id = SessionResume.load_resume_thread_id("codex", nil, ctx.issue.identifier)
    assert is_nil(resume_thread_id)

    fresh_session = %{backend: "codex", resumed: false, thread_id: resume_thread_id, workspace: ctx.workspace, worker_host: nil}
    first_turn_opts = SessionResume.put_first_turn_opts([], fresh_session, ctx.issue.identifier)

    run_fresh_turn = fn _session, prompt, _issue, _opts ->
      assert prompt =~ "previous agent thread was abandoned after it repeatedly lost its transport"
      {:ok, %{thread_id: "fresh"}}
    end

    assert {:completed, %Aiur.Issue{identifier: identifier}} =
             TurnLoop.run_turns(
               fresh_session,
               ctx.workspace,
               ctx.issue,
               nil,
               Keyword.put(first_turn_opts, :run_turn, run_fresh_turn),
               fn _ids -> {:ok, [ctx.issue]} end,
               ctx.orchestrator,
               nil,
               1,
               1
             )

    assert identifier == ctx.issue.identifier
    assert {:ok, %{thread_id: "fresh"}} = SessionHandle.load(ctx.issue.identifier, "codex")
    StreamDiagnostics.clear(self())
  end

  test "a port loss after the first turn completed does not count", ctx do
    later_loss = fn
      1 -> {:ok, %{thread_id: "big"}}
      _turn -> @port_closed
    end

    capture_log(fn ->
      for _ <- 1..3, do: assert(@port_closed = dispatch(ctx, later_loss))
    end)

    assert {:ok, %{thread_id: "big"}} = SessionHandle.load(ctx.issue.identifier, "codex")
  end

  test "a successful fresh turn clears the abandoned marker", ctx do
    :ok = SessionHandle.drop_thread(ctx.issue.identifier)
    assert SessionHandle.abandoned_thread?(ctx.issue.identifier)

    run_turn = fn _session, _prompt, _issue, _opts -> {:ok, %{thread_id: "fresh"}} end

    assert {:completed, %Aiur.Issue{identifier: identifier}} =
             TurnLoop.run_turns(
               %{backend: "codex", resumed: false, thread_id: "fresh", workspace: ctx.workspace, worker_host: nil},
               ctx.workspace,
               ctx.issue,
               nil,
               [resumed: false, run_turn: run_turn],
               fn _ids -> {:ok, [ctx.issue]} end,
               ctx.orchestrator,
               nil,
               1,
               1
             )

    assert identifier == ctx.issue.identifier

    refute SessionHandle.abandoned_thread?(ctx.issue.identifier)
  end

  # One dispatch of a resumed codex session, with up to two turns.
  defp dispatch(ctx, turn_result) do
    run_turn = fn _session, prompt, _issue, _opts ->
      turn_result.(if prompt =~ "continuation turn #2", do: 2, else: 1)
    end

    TurnLoop.run_turns(
      %{backend: "codex", resumed: true, thread_id: "big", port: self(), workspace: ctx.workspace, worker_host: nil},
      ctx.workspace,
      ctx.issue,
      nil,
      [resumed: true, run_turn: run_turn],
      fn _ids -> {:ok, [ctx.issue]} end,
      ctx.orchestrator,
      nil,
      1,
      2
    )
  end
end
