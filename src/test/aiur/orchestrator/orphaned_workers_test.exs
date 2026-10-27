defmodule Aiur.Orchestrator.OrphanedWorkersTest do
  use Aiur.TestSupport

  alias Aiur.AlertLedger
  alias Aiur.Orchestrator.{OrphanedWorkers, State}
  alias Aiur.Workspace.Ownership

  # #2705: after a crash, stop orphaned lease-holding runners and redispatch their ticket.
  test "a restarted Orchestrator stops the runner its predecessor left holding a lease and redispatches the ticket" do
    %{issue: %Issue{id: issue_id, identifier: identifier} = issue} = prepare_workflow!("restart", "Todo")
    name = Module.concat(__MODULE__, "Restart#{System.unique_integer([:positive])}")
    # The initial poll's runner parks on the failing before_run hook while holding its lease.
    start_supervised!(Supervisor.child_spec({Orchestrator, name: name}, restart: :permanent))
    first = Process.whereis(name)

    orphan = await_runner_holding_lease(first, issue_id, identifier)
    kill_on_exit(orphan)
    {:ok, orphan_lease} = Ownership.current(identifier)
    orphan_ref = Process.monitor(orphan)
    # The tracker claim survives the crash; the staged redispatch must not wait out orphan recovery grace.
    Application.put_env(:aiur, :memory_tracker_issues, [%{issue | state: "In Progress", labels: ["agent:in-progress"]}])
    # Restart completion waits for init cleanup; process registration alone is too early.
    Process.exit(first, :kill)
    second = await_restart(name, first)

    assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _reason}, 15_000
    refute orphan in Task.Supervisor.children(Aiur.TaskSupervisor)
    await_generation_released(identifier, orphan_lease.generation)

    # The release notification wakes the restarted Orchestrator to redispatch.
    runner = await_runner_holding_lease(second, issue_id, identifier)
    kill_on_exit(runner)
    assert runner != orphan
    assert {:ok, %{generation: generation}} = Ownership.current(identifier)
    assert generation != orphan_lease.generation

    assert live_session_alerts(identifier) == []
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

    kill_on_exit(orphan)

    assert eventually(fn -> match?({:ok, %{phase: :provisioning}}, Ownership.current(identifier)) end, 15_000)
    refute Map.has_key?(:sys.get_state(orchestrator).running, issue_id)
    {:ok, orphan_lease} = Ownership.current(identifier)
    orphan_ref = Process.monitor(orphan)

    Orchestrator.request_refresh(orchestrator)

    assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _reason}, 15_000
    await_generation_released(identifier, orphan_lease.generation)

    # The release notification wakes the Orchestrator to redispatch.
    runner = await_runner_holding_lease(orchestrator, issue_id, identifier)
    kill_on_exit(runner)
    assert runner != orphan

    assert live_session_alerts(identifier) == []
  end

  test "a runner that reports to another live process is left running" do
    %{issue: issue} = prepare_workflow!("foreign")
    %Issue{identifier: identifier} = issue
    recipient = self()

    {:ok, runner} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        AgentRunner.run(issue, recipient, orchestrator: recipient, worker_host: nil)
      end)

    kill_on_exit(runner)

    assert eventually(fn -> match?({:ok, %{phase: :provisioning}}, Ownership.current(identifier)) end, 15_000)
    {:ok, lease} = Ownership.current(identifier)

    orchestrator = start_supervised!({Orchestrator, initial_poll?: false})
    _ = Orchestrator.request_refresh(orchestrator)
    _ = :sys.get_state(orchestrator)

    assert Process.alive?(runner)
    assert {:ok, ^lease} = Ownership.current(identifier)
  end

  test "a tracked runner survives repeated ticks on the same lease generation" do
    %{issue: %Issue{id: issue_id, identifier: identifier}} =
      prepare_workflow!("tracked", "Todo", tracker_active_states: ["todo", "in-progress"])

    orchestrator = start_supervised!({Orchestrator, []})

    runner = await_runner_holding_lease(orchestrator, issue_id, identifier)
    kill_on_exit(runner)
    runner_ref = Process.monitor(runner)
    {:ok, %{generation: generation}} = Ownership.current(identifier)
    cycles = :sys.get_state(orchestrator).poll_cycles_completed

    # The runner reports to this Orchestrator and has no dead recipient, so
    # only its running entry protects it from the scan.
    for tick <- 1..2 do
      _ = Orchestrator.request_refresh(orchestrator)
      assert eventually(fn -> :sys.get_state(orchestrator).poll_cycles_completed >= cycles + tick end, 15_000)
    end

    if not Process.alive?(runner) do
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, reason}, 1_000
      flunk("tracked runner exited during refreshes: #{inspect(reason)}")
    end

    assert Process.alive?(runner)
    assert %{pid: ^runner} = :sys.get_state(orchestrator).running[issue_id]
    assert {:ok, %{generation: ^generation}} = Ownership.current(identifier)
  end

  test "a remote runner whose recipient died is left to release its own lease" do
    identifier = "ORPH-REMOTE-#{System.unique_integer([:positive])}"
    dead_recipient = spawn(fn -> :ok end)
    ref = Process.monitor(dead_recipient)
    assert_receive {:DOWN, ^ref, :process, ^dead_recipient, _reason}, 1000

    name = unique_name("Remote")

    owner =
      claim_in_process(identifier, %{
        issue_id: "issue-#{identifier}",
        update_recipient: dead_recipient,
        update_recipient_name: name,
        worker_host: "remote-a"
      })

    {:ok, lease} = Ownership.current(identifier)

    orchestrator = start_supervised!({Orchestrator, name: name, initial_poll?: false})
    _ = Orchestrator.request_refresh(orchestrator)
    state = :sys.get_state(orchestrator)

    assert Process.alive?(owner)
    assert {:ok, ^lease} = Ownership.current(identifier)
    refute Map.has_key?(state.dispatch_recovery.workspace_ownership.waits, identifier)
  end

  test "a guardian that does not answer cannot stall the Orchestrator" do
    dead_recipient = spawn(fn -> :ok end)
    ref = Process.monitor(dead_recipient)
    assert_receive {:DOWN, ^ref, :process, ^dead_recipient, _reason}, 1000

    orphan_id = "ORPH-STALL-#{System.unique_integer([:positive])}"
    tracked_id = "ORPH-BUSY-#{System.unique_integer([:positive])}"
    name = unique_name("Stall")

    orphan =
      claim_in_process(orphan_id, %{
        issue_id: "issue-#{orphan_id}",
        update_recipient: dead_recipient,
        update_recipient_name: name,
        worker_host: nil
      })

    busy = claim_in_process(tracked_id, %{issue_id: "issue-#{tracked_id}", update_recipient: self(), worker_host: nil})
    {:ok, orphan_lease} = Ownership.current(orphan_id)
    {:ok, busy_lease} = Ownership.current(tracked_id)

    # Freeze both guardians, as a guardian blocked in the ownership store is.
    guardians = [orphan_lease.guardian, busy_lease.guardian]
    Enum.each(guardians, &:erlang.suspend_process/1)
    on_exit(fn -> Enum.each(guardians, &resume_if_alive/1) end)

    orphan_ref = Process.monitor(orphan)
    {init_us, orchestrator} = :timer.tc(fn -> start_supervised!({Orchestrator, name: name, initial_poll?: false}) end)
    assert init_us < 2_000_000
    assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _reason}, 1_000

    # A full tick and poll cycle completes. The GitHub poll floor delays the
    # tick by about a second; a guardian call per lease would add 5s each.
    cycles = :sys.get_state(orchestrator).poll_cycles_completed

    {tick_us, completed?} =
      :timer.tc(fn ->
        _ = Orchestrator.request_refresh(orchestrator)
        eventually(fn -> :sys.get_state(orchestrator).poll_cycles_completed > cycles end, 15_000)
      end)

    assert completed?
    assert tick_us < 4_000_000
    assert Process.alive?(busy)

    # Once the guardian answers again, it releases the stopped generation.
    Enum.each(guardians, &resume_if_alive/1)
    assert eventually(fn -> Ownership.current(orphan_id) == :none end, 15_000)
    assert eventually(fn -> not Map.has_key?(:sys.get_state(orchestrator).dispatch_recovery.workspace_ownership.waits, orphan_id) end, 15_000)
  end

  test "a dead predecessor's runner belongs only to an Orchestrator with the same name" do
    dead_recipient = spawn(fn -> :ok end)
    ref = Process.monitor(dead_recipient)
    assert_receive {:DOWN, ^ref, :process, ^dead_recipient, _reason}, 1000

    identifier = "ORPH-OTHER-#{System.unique_integer([:positive])}"

    owner =
      claim_in_process(identifier, %{
        issue_id: "issue-#{identifier}",
        update_recipient: dead_recipient,
        update_recipient_name: unique_name("SomeoneElse"),
        worker_host: nil
      })

    {:ok, lease} = Ownership.current(identifier)

    named = start_supervised!({Orchestrator, name: unique_name("Other"), initial_poll?: false}, id: :named_other)
    unnamed = start_supervised!({Orchestrator, initial_poll?: false}, id: :unnamed_other)
    _ = :sys.get_state(named)
    _ = :sys.get_state(unnamed)

    assert Process.alive?(owner)
    assert {:ok, ^lease} = Ownership.current(identifier)
  end

  test "test ticket scope reaps pinned orphans without stopping unrelated runners" do
    Aiur.TestScopeGuard.put_ticket_scope!("99")

    pinned = claim_in_process("99", %{issue_id: "issue-99", update_recipient: self(), worker_host: nil})
    unrelated = claim_in_process("2413", %{issue_id: "issue-2413", update_recipient: self(), worker_host: nil})
    pinned_ref = Process.monitor(pinned)
    {:ok, unrelated_lease} = Ownership.current("2413")

    _state = OrphanedWorkers.stop_untracked_runners(%State{})

    assert_receive {:DOWN, ^pinned_ref, :process, ^pinned, _reason}, 5_000
    assert Process.alive?(unrelated)
    assert {:ok, ^unrelated_lease} = Ownership.current("2413")
  end

  defp kill_on_exit(pid) do
    on_exit(fn -> Process.exit(pid, :kill) end)
  end

  defp unique_name(label), do: Module.concat(__MODULE__, "#{label}#{System.unique_integer([:positive])}")

  defp await_generation_released(identifier, generation) do
    assert eventually(fn -> not match?({:ok, %{generation: ^generation}}, Ownership.current(identifier)) end, 15_000)
  end

  defp claim_in_process(identifier, holder) do
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(identifier, Aiur.Workspace.Ownership.Registry, holder: holder)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, _lease}}, 5_000
    on_exit(fn -> Process.exit(owner, :kill) end)
    owner
  end

  defp resume_if_alive(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  # Waits until `orchestrator` tracks a live runner for the ticket and that
  # runner holds the ticket's lease with `orchestrator` as its update target.
  defp await_runner_holding_lease(orchestrator, issue_id, identifier) do
    assert eventually(fn -> tracked_lease_holder(orchestrator, issue_id, identifier) != nil end, 15_000)
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
        |> Enum.filter(&(Jason.decode!(&1)["topic"] == topic))

      {:error, _missing} ->
        []
    end
  end

  defp await_restart(name, previous) do
    assert eventually(
             fn ->
               pid = Process.whereis(name)
               is_pid(pid) and pid != previous
             end,
             15_000
           )

    Process.whereis(name) |> tap(fn pid -> :sys.get_state(pid, 15_000) end)
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

  defp prepare_workflow!(name, state \\ "In Progress", opts \\ []) do
    test_root = Aiur.TestSupport.tmp_root!("orphaned-workers-#{name}")
    workspace_root = Path.join(test_root, "workspaces")
    identifier = "ORPH-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Orphaned runner",
      state: state,
      labels: ["agent:" <> String.replace(String.downcase(state), " ", "-")]
    }

    File.mkdir_p!(test_root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

    # A failing before_run hook parks the runner in a paused provisioning
    # state that holds its workspace lease until something stops it.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: Keyword.get(opts, :tracker_active_states, ["Todo", "In Progress"]),
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
