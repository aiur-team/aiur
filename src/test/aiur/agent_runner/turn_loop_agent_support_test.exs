defmodule Aiur.AgentRunner.TurnLoopAgentSupportTest do
  # #2697: a live session starts later turns without re-running before_run:
  # continuation turns, and the turn after a pause is resumed. Each turn must
  # repair the workspace's agent GitHub support before the provider is called,
  # or refuse the turn without calling the provider at all.
  use Aiur.TestSupport

  alias Aiur.AgentGitHubGuard
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Workspace.Provisioner

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(report), do: GenServer.start_link(__MODULE__, report)

    @impl true
    def init(report), do: {:ok, report}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, report), do: {:reply, :empty, report}

    def handle_call({:consume_delivered_queue_items, identifier}, _from, report) do
      send(report, {:queue_item_consumed, identifier})
      {:reply, :ok, report}
    end

    def handle_call({:restore_delivered_queue_items, identifier}, _from, report) do
      send(report, {:queue_item_restored, identifier})
      {:reply, :ok, report}
    end

    def handle_call({:fail_delivered_queue_items, identifier, reason}, _from, report) do
      send(report, {:queue_item_failed, identifier, reason})
      {:reply, :ok, report}
    end
  end

  setup do
    test_root = Aiur.TestSupport.tmp_root!("turn-loop-agent-support")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    assert AgentGitHubGuard.missing_workspace_support(workspace) == []

    identifier = "TL-2697-#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "In Progress"}
    {:ok, orchestrator} = FakeOrchestrator.start_link(self())

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace: workspace, issue: issue, orchestrator: orchestrator}
  end

  describe "a workspace that lost .aiur-runtime/bin and gh/" do
    setup %{workspace: workspace} do
      File.rm_rf!(Path.join(workspace, ".aiur-runtime/bin"))
      File.rm_rf!(AgentGitHubGuard.gh_config_dir(workspace))
      assert ".aiur-runtime/gh" in AgentGitHubGuard.missing_workspace_support(workspace)
      :ok
    end

    test "the first turn repairs it before the provider is called", ctx do
      assert {:completed, _issue} = run_first_turn(ctx, report_missing_run_turn(ctx.workspace))

      assert_receive {:provider_called, 1, []}
    end

    test "the turn after a resume repairs it before the provider is called", ctx do
      assert {:completed, _issue} = continue_after_resume(ctx, report_missing_run_turn(ctx.workspace))

      assert_receive {:provider_called, 2, []}
    end
  end

  describe "a gh config dir replaced by a symlink" do
    setup %{workspace: workspace, test_root: test_root} do
      operator_config = Path.join(test_root, "operator-gh")
      File.mkdir_p!(operator_config)
      File.rm_rf!(AgentGitHubGuard.gh_config_dir(workspace))
      File.ln_s!(operator_config, AgentGitHubGuard.gh_config_dir(workspace))
      :ok
    end

    test "the first turn is refused without a provider call", ctx do
      assert {:error, {:agent_support_repair_failed, workspace, missing, {:agent_gh_config_dir_unavailable, _, _}}} =
               run_first_turn(ctx, refusing_run_turn())

      assert workspace == ctx.workspace
      assert ".aiur-runtime/gh" in missing
      refute_received {:provider_called, _turn, _missing}
      identifier = ctx.issue.identifier
      assert_receive {:queue_item_restored, ^identifier}
      refute_received {:queue_item_failed, ^identifier, _reason}
    end

    test "the turn after a resume is refused without a provider call", ctx do
      assert {:error, {:agent_support_repair_failed, _workspace, missing, _reason}} =
               continue_after_resume(ctx, refusing_run_turn())

      assert ".aiur-runtime/gh" in missing
      refute_received {:provider_called, _turn, _missing}
    end
  end

  defp run_first_turn(ctx, run_turn) do
    TurnLoop.run_turns(
      %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
      ctx.workspace,
      ctx.issue,
      nil,
      [resumed: true, run_turn: run_turn],
      fn _ids -> {:ok, []} end,
      ctx.orchestrator,
      nil,
      1,
      1
    )
  end

  # The resume path (`wait_for_resume/3` -> `continue_after_resume/2`) starts
  # turn 2 in the same live session without re-running before_run.
  defp continue_after_resume(ctx, run_turn) do
    turn_context = %{
      workspace: ctx.workspace,
      issue: ctx.issue,
      codex_update_recipient: nil,
      opts: [run_turn: run_turn],
      issue_state_fetcher: fn _ids -> {:ok, [ctx.issue]} end,
      orchestrator: ctx.orchestrator,
      worker_host: nil,
      turn_number: 1,
      max_turns: 2
    }

    TurnLoop.continue_after_resume(turn_context, %{backend: "claude", workspace: ctx.workspace, worker_host: nil})
  end

  defp report_missing_run_turn(workspace) do
    parent = self()

    fn _session, prompt, _issue, _opts ->
      turn = if prompt =~ "continuation turn #2", do: 2, else: 1
      send(parent, {:provider_called, turn, AgentGitHubGuard.missing_workspace_support(workspace)})
      {:ok, %{session_id: "turn-#{turn}"}}
    end
  end

  defp refusing_run_turn do
    parent = self()

    fn _session, _prompt, _issue, _opts ->
      send(parent, {:provider_called, 0, :must_not_run})
      {:ok, %{session_id: "must-not-run"}}
    end
  end
end
