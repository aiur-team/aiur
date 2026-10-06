defmodule Aiur.TestSupportTest do
  use Aiur.TestSupport

  alias Aiur.CurrentRunMembership
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Events.SubscriptionStoreRegistry
  alias Aiur.Events.SubscriptionStoreSupervisor
  alias Aiur.GitHub.ReadCache

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
    on_exit(fn -> Aiur.TestSupport.ensure_runtime_children_running() end)

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
    assert is_pid(Process.whereis(ReadCache))
    assert :ok = CurrentRunMembership.subscribe()
    Phoenix.PubSub.unsubscribe(Aiur.PubSub, "current-run-membership:changed")
    assert ReadCache.snapshot().available?
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
end
