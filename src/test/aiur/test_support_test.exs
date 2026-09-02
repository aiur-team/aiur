defmodule Aiur.TestSupportTest do
  use Aiur.TestSupport

  alias Aiur.CurrentRunMembership
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

  # The two #2397 regression failures share one mechanism: a sibling test that
  # stops the shared `Aiur.PubSub` child takes down the whole `Aiur.Supervisor`
  # tree (PubSub AND the read cache, and everything else), so the next tests to
  # run see `unknown registry: Aiur.PubSub` and an `available?: false`
  # `ReadCache`. These prove the ensure-running helpers actually recover the app
  # rather than just returning `:ok`.
  #
  # Quarantined (#2474), and the reason is the whole point of #2397. This test
  # is the only one here that takes the entire OTP application down and brings
  # it back, and `Application.stop/1` + `Application.ensure_all_started/1` are
  # calls into the single global `:application_controller`. It passes when the
  # file runs alone (7.2s), but in a full partition a sibling module can leave a
  # supervised child that does not terminate; the controller then blocks
  # forever inside the shutdown, and because EVERY `ensure_*` helper funnels
  # through `ensure_aiur_application_started/1`, every later test queues behind
  # the wedged controller and dies on the 60s ExUnit timeout. Measured on this
  # branch: `MIX_TEST_PARTITION=3 TEST_PARTITIONS=4 mix test --cover
  # --partitions 4` never finished (killed at 11 min, 6 cascading 60s timeouts,
  # all stacked on `:gen.do_call` -> `:application_controller.call`), which is
  # the same wedge that burned 45 minutes as `coverage (3/4)` in run
  # 32790770281. A test that can deadlock the partition it runs in cannot live
  # in the blocking suite; the non-blocking quarantine job still runs it, so the
  # mutation guard on `ensure_pubsub_running/1` is kept rather than deleted.
  @tag :quarantine
  test "ensure_pubsub_running recovers the whole app after a sibling collapsed it by stopping PubSub" do
    on_exit(fn -> Aiur.TestSupport.ensure_runtime_children_running() end)

    assert is_pid(Process.whereis(Aiur.Supervisor))
    assert is_pid(Process.whereis(Aiur.PubSub))
    assert is_pid(Process.whereis(ReadCache))

    # A sibling terminating the shared PubSub child collapses the whole tree.
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Phoenix.PubSub.Supervisor)
    Process.sleep(150)

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
    on_exit(fn -> Aiur.Events.SubscriptionStore.stop(identifier) end)

    assert is_pid(Process.whereis(Aiur.Events.SubscriptionStoreSupervisor))

    assert :ok =
             Supervisor.terminate_child(
               Aiur.Supervisor,
               Aiur.Events.SubscriptionStoreSupervisor
             )

    refute Process.whereis(Aiur.Events.SubscriptionStoreSupervisor)

    assert :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    assert is_pid(Process.whereis(Aiur.Events.SubscriptionStoreSupervisor))
    assert :ok = Aiur.Events.SubscriptionStore.attach(identifier)
    assert [{store, _value}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, identifier)
    assert is_pid(store)
    assert %{subscribed_to: [], last_seen_event_id: nil, open_attentions: []} = Aiur.Events.SubscriptionStore.snapshot(identifier)
  end
end
