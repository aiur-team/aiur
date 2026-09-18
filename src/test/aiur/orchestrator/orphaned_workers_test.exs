defmodule Aiur.Orchestrator.OrphanedWorkersTest do
  use Aiur.TestSupport

  alias Aiur.AlertLedger
  alias Aiur.Workspace.Ownership

  # #2705: an Orchestrator crash leaves its runner tasks (and their workspace
  # leases) alive under `:rest_for_one`. The restarted Orchestrator must stop
  # them and redispatch the ticket, not refuse it as a live session forever.
  test "a restarted Orchestrator stops the runner its predecessor left holding a lease and redispatches the ticket" do
    %{issue: %Issue{id: issue_id, identifier: identifier}} = prepare_workflow!("restart")
    name = Module.concat(__MODULE__, "Restart#{System.unique_integer([:positive])}")

    # The initial poll dispatches the in-progress ticket to a real runner that
    # parks on the failing before_run hook while holding its lease.
    start_supervised!(Supervisor.child_spec({Orchestrator, name: name}, restart: :permanent))
    first = Process.whereis(name)

    orphan = await_runner_holding_lease(first, issue_id, identifier)
    {:ok, orphan_lease} = Ownership.current(identifier)
    orphan_ref = Process.monitor(orphan)

    # Kill the Orchestrator. The test supervisor restarts it from the same
    # child spec, as `Aiur.Supervisor` does after a crash.
    Process.exit(first, :kill)
    second = await_restart(name, first)

    assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _reason}, 5_000
    refute orphan in Task.Supervisor.children(Aiur.TaskSupervisor)

    # The ticket is redispatched onto a fresh lease without a poll request:
    # the lease release alone wakes the new Orchestrator.
    runner = await_runner_holding_lease(second, issue_id, identifier)
    assert runner != orphan
    assert {:ok, %{generation: generation}} = Ownership.current(identifier)
    assert generation != orphan_lease.generation

    assert live_session_alerts(identifier) == 0
  end

  test "a runner that reports to a live Orchestrator without a running entry is stopped and redispatched" do
    %{issue: issue} = prepare_workflow!("rollback")
    %Issue{id: issue_id, identifier: identifier} = issue
    orchestrator = start_supervised!({Orchestrator, initial_poll?: false})

    # A crashed control call that rolls the state back leaves exactly this: a
    # runner that reports to the running Orchestrator, with no running entry.
    {:ok, orphan} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        AgentRunner.run(issue, orchestrator, orchestrator: orchestrator, worker_host: nil)
      end)

    on_exit(fn -> if Process.alive?(orphan), do: Process.exit(orphan, :kill) end)

    assert eventually(fn -> match?({:ok, %{phase: :provisioning}}, Ownership.current(identifier)) end, 5_000)
    refute Map.has_key?(:sys.get_state(orchestrator).running, issue_id)
    orphan_ref = Process.monitor(orphan)

    Orchestrator.request_refresh(orchestrator)

    assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _reason}, 5_000
    runner = await_runner_holding_lease(orchestrator, issue_id, identifier)
    assert runner != orphan

    assert live_session_alerts(identifier) == 0
  end

  test "a runner that reports to another live process is left running" do
    %{issue: issue} = prepare_workflow!("foreign")
    %Issue{identifier: identifier} = issue
    recipient = self()

    {:ok, runner} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        AgentRunner.run(issue, recipient, orchestrator: recipient, worker_host: nil)
      end)

    on_exit(fn -> if Process.alive?(runner), do: Process.exit(runner, :kill) end)

    assert eventually(fn -> match?({:ok, %{phase: :provisioning}}, Ownership.current(identifier)) end, 5_000)
    {:ok, lease} = Ownership.current(identifier)

    orchestrator = start_supervised!({Orchestrator, initial_poll?: false})
    _ = Orchestrator.request_refresh(orchestrator)
    _ = :sys.get_state(orchestrator)

    assert Process.alive?(runner)
    assert {:ok, ^lease} = Ownership.current(identifier)
  end

  # Waits until `orchestrator` tracks a live runner for the ticket and that
  # runner holds the ticket's lease with `orchestrator` as its update target.
  defp await_runner_holding_lease(orchestrator, issue_id, identifier) do
    assert eventually(fn -> tracked_lease_holder(orchestrator, issue_id, identifier) != nil end, 10_000)
    tracked_lease_holder(orchestrator, issue_id, identifier)
  end

  defp tracked_lease_holder(orchestrator, issue_id, identifier) do
    with %{pid: pid} when is_pid(pid) <- :sys.get_state(orchestrator).running[issue_id],
         {:ok, lease} <- Ownership.current(identifier),
         {:ok, %{owner: ^pid, holder: %{update_recipient: ^orchestrator}}} <- Ownership.holder(lease) do
      pid
    else
      _other -> nil
    end
  end

  defp live_session_alerts(identifier) do
    topic = "ticket.#{identifier}.workspace.live_session"

    case File.read(AlertLedger.path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.count(&(Jason.decode!(&1)["topic"] == topic))

      {:error, _missing} ->
        0
    end
  end

  defp await_restart(name, previous) do
    assert eventually(
             fn ->
               pid = Process.whereis(name)
               is_pid(pid) and pid != previous
             end,
             5_000
           )

    Process.whereis(name)
  end

  defp eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end

  defp prepare_workflow!(name) do
    test_root = Aiur.TestSupport.tmp_root!("orphaned-workers-#{name}")
    workspace_root = Path.join(test_root, "workspaces")
    identifier = "ORPH-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Orphaned runner",
      state: "In Progress",
      labels: ["agent:in-progress"]
    }

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    # A failing before_run hook parks the runner in a paused provisioning
    # state that holds its workspace lease until something stops it.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: """
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      touch initialized
      git add initialized
      git commit --quiet -m initial
      """,
      hook_before_run: "exit 7"
    )

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    %{issue: issue}
  end
end
