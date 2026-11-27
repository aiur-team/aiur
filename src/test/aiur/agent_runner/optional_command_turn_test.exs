defmodule Aiur.AgentRunner.OptionalCommandTurnTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.DecisionStore
  alias Aiur.Workspace.Provisioner

  setup do
    test_root = Aiur.TestSupport.tmp_root!("optional-command-turn")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    active_state = Enum.at(Aiur.Config.settings!().tracker.active_states, 0)
    identifier = "OCT-#{System.unique_integer([:positive])}"

    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: active_state, labels: ["agent:#{active_state}"]}
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

    %{workspace: workspace, issue: issue}
  end

  test "an open optional Command keeps the ticket active after a no-op turn", ctx do
    configure_memory_tracker!(self())
    issue = %{ctx.issue | state: "in-progress", labels: ["agent:in-progress"]}
    configure_memory_tracker!(self())

    assert {:ok, %{decision: optional}} =
             DecisionStore.request(
               %{
                 "question" => "Which option do you prefer?",
                 "blocking" => false,
                 "recommendation" => %{"option_id" => "ship", "label" => "Ship"},
                 "options" => [%{"id" => "ship", "label" => "Ship"}, %{"id" => "hold", "label" => "Hold"}]
               },
               ticket: %{identifier: issue.identifier},
               source: %{agent_id: "worker", session_id: "session", event_id: nil}
             )

    for _ <- 1..10, do: send(self(), {:resume_agent, 1})

    assert {:completed, %{state: "in-progress"}} =
             TurnLoop.run_turns(
               %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
               ctx.workspace,
               issue,
               nil,
               [
                 resumed: true,
                 run_turn: fn _session, _prompt, _issue, _opts -> {:ok, %{session_id: "optional-command-noop"}} end,
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 workspace_probe: fn _workspace, _host -> %{changed?: false, head: "same"} end,
                 open_pr_fetcher: fn _ -> {:ok, nil} end
               ],
               fn _ids -> {:ok, [issue]} end,
               nil,
               nil,
               1,
               nil
             )

    assert {:ok, retained} = DecisionStore.get(optional.decision_id)
    assert retained.decision_status == :open
    assert retained.default_applied.option_id == "ship"
    refute_receive {:memory_tracker_state_update, _, "human-review"}, 50
  end

  test "a productive turn records the optional Command default before continuing", ctx do
    configure_memory_tracker!(self())
    issue = %{ctx.issue | state: "in-progress", labels: ["agent:in-progress"]}

    assert {:ok, %{decision: optional}} =
             DecisionStore.request(
               %{
                 "question" => "Which option do you prefer?",
                 "blocking" => false,
                 "recommendation" => %{"option_id" => "ship", "label" => "Ship"},
                 "options" => [%{"id" => "ship", "label" => "Ship"}, %{"id" => "hold", "label" => "Hold"}]
               },
               ticket: %{identifier: issue.identifier},
               source: %{agent_id: "worker", session_id: "session", event_id: nil}
             )

    assert {:completed, %{state: "in-progress"}} =
             TurnLoop.run_turns(
               %{backend: "claude", workspace: ctx.workspace, worker_host: nil},
               ctx.workspace,
               issue,
               nil,
               [
                 resumed: true,
                 run_turn: fn _session, _prompt, _issue, _opts ->
                   File.write!(Path.join(ctx.workspace, "progress.txt"), "made progress")
                   {:ok, %{session_id: "optional-command-productive"}}
                 end,
                 max_consecutive_noop_turns: 3,
                 noop_backoff_ms: 0,
                 workspace_probe: fn _workspace, _host ->
                   case Process.get(:optional_probe_calls, 0) do
                     0 ->
                       Process.put(:optional_probe_calls, 1)
                       %{changed?: false, head: "before"}

                     _ ->
                       %{changed?: true, head: "after"}
                   end
                 end,
                 open_pr_fetcher: fn _ -> {:ok, nil} end
               ],
               fn _ids -> {:ok, [issue]} end,
               nil,
               nil,
               1,
               nil
             )

    assert {:ok, %{default_applied: %{option_id: "ship", at: %DateTime{}}}} = DecisionStore.get(optional.decision_id)
  end

  defp configure_memory_tracker!(recipient) do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Process.put(:memory_tracker_recipient, recipient)
  end
end
