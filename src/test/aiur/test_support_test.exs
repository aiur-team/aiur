defmodule Aiur.TestSupportTest do
  use Aiur.TestSupport

  alias Aiur.CurrentRunMembership
  alias Aiur.Events.IdGenerator
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Events.SubscriptionStoreRegistry
  alias Aiur.Events.SubscriptionStoreSupervisor
  alias Aiur.GitHub.ReadCache
  alias Aiur.TestSupport.OrchestratorGuard
  alias Aiur.TestSupport.SupervisorExit

  test "SupervisorExit captures pid monitor reasons for a named supervisor" do
    name = Module.concat(__MODULE__, "ExitProbe#{System.unique_integer([:positive])}")
    assert {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one, name: name)
    Process.unlink(pid)

    on_exit(fn ->
      if replacement = Process.whereis(name), do: Supervisor.stop(replacement, :normal)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      OrchestratorGuard.monitor_supervisor(Aiur.Supervisor)
    end)

    assert :ok = OrchestratorGuard.monitor_supervisor(name, self())
    Process.exit(pid, :kill)
    assert_receive {:supervisor_exit, :killed}, 5_000
    assert SupervisorExit.exit_reason() == :killed

    assert {:ok, replacement} = Supervisor.start_link([], strategy: :one_for_one, name: name)
    Process.unlink(replacement)
    assert_receive {:supervisor_monitor_restored, ^replacement}, 5_000
    assert SupervisorExit.exit_reason() == nil
  end

  test "receive_barrier selectively receives and exports bindings without a clock" do
    send(self(), :unrelated)
    send(self(), {:ready, 42})

    receive_barrier({:ready, value})

    assert value == 42
    assert_received :unrelated
  end

  test "write_workflow_file! waits for the active config reload to finish" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    workspace_root = Aiur.TestSupport.tmp_root!("synced-workflow")

    :sys.suspend(store)
    :erlang.trace(store, true, [:receive])

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
    end)

    writer =
      Task.async(fn ->
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      end)

    assert_receive {:trace, ^store, :receive, {:"$gen_call", _from, :force_reload}}, 1_000

    # The legacy helper swallowed the GenServer.call exit after five seconds
    # and returned while the store was still suspended with its old cache.
    assert Task.yield(writer, 5_100) == nil

    :sys.resume(store)

    assert :ok = Task.await(writer, 1_000)
    assert Config.workspace_root() == workspace_root
  end

  test "write_workflow_file_async! warns when the active config reload times out" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    workspace_root = Aiur.TestSupport.tmp_root!("async-workflow")

    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    log =
      capture_log(fn ->
        assert :ok = write_workflow_file_async!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      end)

    assert log =~ "Best-effort workflow reload failed"
    assert log =~ "WorkflowStore may serve stale test config"

    :sys.resume(store)
  end

  test "ensure_runtime_children_running restores a stopped branch ref store" do
    store = Process.whereis(Aiur.Events.BranchRefStore)
    assert is_pid(store)

    on_exit(fn -> Aiur.TestSupport.ensure_branch_ref_store_running() end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Events.BranchRefStore)
    refute Process.whereis(Aiur.Events.BranchRefStore)

    assert :ok = Aiur.TestSupport.ensure_runtime_children_running()
    assert is_pid(Process.whereis(Aiur.Events.BranchRefStore))
  end

  # The only test in the suite that restarts the whole OTP application, through
  # the synchronous global `:application_controller`. It used to wedge that
  # controller for its whole partition (#2474): with the tree already down,
  # `Aiur.Application.stop/1` re-derived config, and YamlElixir's per-read
  # `Application.start(:yamerl)` waited forever on the controller that was busy
  # stopping `:aiur`. `Aiur.Yaml` removed that call, so this runs in the blocking
  # suite again. The collapse is forced by killing the supervisor: stopping
  # PubSub only topples the tree when dependants exhaust the restart budget
  # inside the wait, which made the old premise itself flaky.
  test "ensure_pubsub_running recovers the whole app after the supervision tree collapsed" do
    codeowners_baseline = OrchestratorGuard.capture_shared_state().codeowners

    on_exit(fn ->
      Aiur.TestSupport.ensure_runtime_children_running()
      OrchestratorGuard.restore_codeowners_state!(codeowners_baseline)
    end)

    collapsing = Enum.map([Aiur.Supervisor, Aiur.PubSub, ReadCache], &Process.whereis/1)
    assert Enum.all?(collapsing, &is_pid/1)

    # Killing the supervisor takes its linked children with it; wait for each
    # one's DOWN rather than guessing how long the exit signals take.
    Process.exit(hd(collapsing), :kill)
    for pid <- collapsing, do: assert(:ok = Aiur.TestSupport.await_process_down(pid, 5_000))

    assert is_nil(Process.whereis(Aiur.Supervisor))
    assert is_nil(Process.whereis(Aiur.PubSub))
    assert is_nil(Process.whereis(ReadCache))

    # The guard restarts the whole app and brings PubSub back before use.
    capture_log(fn -> assert :ok = Aiur.TestSupport.ensure_pubsub_running() end)

    assert is_pid(Process.whereis(Aiur.Supervisor))
    assert is_pid(Process.whereis(Aiur.PubSub))
    assert Aiur.Supervisor in process_ancestors(Process.whereis(Aiur.PubSub))
    assert is_pid(Process.whereis(ReadCache))
    assert :ok = CurrentRunMembership.subscribe()
    Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed")
    assert ReadCache.snapshot().available?
  end

  # #4527: `terminate_child` on the live PubSub kills every linked subscriber
  # sibling; their restarts into a missing registry exhaust the root restart
  # budget, `Aiur.Supervisor` shuts down, and every later test in the shard
  # fails. The excluded orchestrator-guard fixture is the sole exception: its
  # integration test runs in a separate mix test VM to exercise the detector.
  test "no test terminates the shared PubSub child under the live application" do
    isolated_fixture = "test/fixtures/orchestrator_guard/leak_probes_test.exs"

    offenders =
      for file <- Path.wildcard(Path.join(Path.expand("..", __DIR__), "**/*.{ex,exs}")),
          Path.relative_to_cwd(file) != isolated_fixture,
          File.read!(file) =~ ~r/terminate_child\([^,()]+,\s*Phoenix\.PubSub\.Supervisor\)/,
          do: Path.relative_to_cwd(file)

    assert offenders == []
    assert File.read!(Path.join(Path.expand("..", __DIR__), "fixtures/orchestrator_guard/leak_probes_test.exs")) =~ "@moduletag :orchestrator_guard_probe"
  end

  test "ensure_runtime_children_running restores shared event and provider stores" do
    on_exit(fn -> Aiur.TestSupport.ensure_runtime_children_running() end)

    assert is_pid(Process.whereis(IdGenerator))
    assert is_pid(Process.whereis(Aiur.ProviderMeters.Store))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, IdGenerator)
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.ProviderMeters.Store)
    refute Process.whereis(IdGenerator)
    refute Process.whereis(Aiur.ProviderMeters.Store)

    assert :ok = Aiur.TestSupport.ensure_runtime_children_running()
    assert is_pid(Process.whereis(IdGenerator))
    assert is_pid(Process.whereis(Aiur.ProviderMeters.Store))
    assert {:ok, id} = IdGenerator.reserve_durable_id()
    assert is_integer(id)
  end

  test "ensure_orchestrator_running restarts a terminated shared orchestrator" do
    on_exit(fn -> Aiur.TestSupport.ensure_orchestrator_running() end)

    assert is_pid(Process.whereis(Aiur.Orchestrator))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
    refute Process.whereis(Aiur.Orchestrator)

    assert :ok = Aiur.TestSupport.ensure_orchestrator_running()
    assert is_pid(Process.whereis(Aiur.Orchestrator))
  end

  test "ensure_read_cache_running recovers a stopped read cache (contained to one child)" do
    on_exit(fn -> Aiur.TestSupport.ensure_runtime_children_running() end)

    assert is_pid(Process.whereis(ReadCache))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.GitHub.ReadCache)
    Process.sleep(100)

    refute is_pid(Process.whereis(ReadCache))
    # ReadCache is contained: stopping it must not take down PubSub or the app.
    assert is_pid(Process.whereis(Aiur.Supervisor))
    assert is_pid(Process.whereis(Aiur.PubSub))

    assert :ok = Aiur.TestSupport.ensure_read_cache_running()
    assert is_pid(Process.whereis(ReadCache))
    assert ReadCache.snapshot().available?
  end

  test "ensure_subscription_store_supervisor_running restores the stopped dynamic supervisor" do
    identifier = "test-support-subscription-store-#{System.unique_integer([:positive])}"
    on_exit(fn -> Aiur.TestSupport.ensure_runtime_children_running() end)
    on_exit(fn -> SubscriptionStore.stop(identifier) end)

    assert is_pid(Process.whereis(SubscriptionStoreSupervisor))

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, SubscriptionStoreSupervisor)

    refute Process.whereis(SubscriptionStoreSupervisor)

    assert :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    assert is_pid(Process.whereis(SubscriptionStoreSupervisor))
    assert :ok = SubscriptionStore.attach(identifier)
    assert [{store, _value}] = Registry.lookup(SubscriptionStoreRegistry, identifier)
    assert is_pid(store)

    assert %{subscribed_to: [], last_seen_event_id: nil, open_attentions: []} =
             SubscriptionStore.snapshot(identifier)
  end

  defp process_ancestors(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, :"$ancestors", [])
  end
end
