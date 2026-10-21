defmodule Aiur.Events.SubscriptionStoreTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Events.{IdGenerator, SubscriptionStore}
  alias Aiur.JsonStore
  alias Aiur.Orchestrator.{AutoSubscriptions, State}

  setup do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_subscr_test")
    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))
    original_runtime_state_dir = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, Path.join(tmp_dir, "runtime-state"))

    identifier = "test-issue-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      stop_store_if_alive(identifier)

      if original do
        Application.put_env(:aiur, :log_file, original)
      else
        Application.delete_env(:aiur, :log_file)
      end

      if original_runtime_state_dir do
        Application.put_env(:aiur, :runtime_state_dir, original_runtime_state_dir)
      else
        Application.delete_env(:aiur, :runtime_state_dir)
      end

      # Non-raising rm_rf: the SubscriptionStore writer persists into this
      # dir via JsonStore's atomic write (a `<path>.tmp.<n>` staging file
      # renamed into place). Under CI load that staging file can land
      # between rm_rf's directory listing and its final rmdir, so the rmdir
      # sees a non-empty dir and fails with :eexist. The dir is unique per
      # test under the system tmp dir, so a rare leftover is harmless —
      # tolerate the race instead of crashing an unrelated run. Matches the
      # `Aiur.TestCleanup.rm_rf!/1` teardown convention in `Aiur.TestSupport`.
      Aiur.TestCleanup.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, identifier: identifier}
  end

  defp stop_store_if_alive(identifier) do
    SubscriptionStore.stop(identifier)
  catch
    :exit, {reason, {GenServer, :stop, _args}} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  describe "attach/1" do
    test "starts a writer with empty state", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      snap = SubscriptionStore.snapshot(id)
      assert snap == %{subscribed_to: [], last_seen_event_id: nil, open_attentions: []}
    end

    test "is idempotent", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.attach(id)
      assert SubscriptionStore.snapshot(id) != :not_found
    end
  end

  describe "stop/1" do
    test "is a no-op when the registry is already stopped", %{identifier: id} do
      :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreRegistry)

      try do
        assert :ok = SubscriptionStore.stop(id)
      after
        {:ok, _pid} =
          Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreRegistry)
      end
    end
  end

  describe "cleanup" do
    test "tolerates a store exiting immediately before cleanup", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)
      monitor = Process.monitor(pid)

      Process.exit(pid, :shutdown)
      receive_barrier({:DOWN, ^monitor, :process, ^pid, :shutdown})

      SubscriptionStore.set_registry_lookup_fn(fn _registry, _identifier -> [{pid, nil}] end)

      try do
        assert :ok = stop_store_if_alive(id)
      after
        SubscriptionStore.set_registry_lookup_fn(nil)
      end
    end
  end

  describe "snapshot/1" do
    test "is unavailable-safe while the supervised registry is stopped", %{identifier: id} do
      :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreRegistry)

      try do
        assert :not_found = SubscriptionStore.snapshot(id)
        assert [] = AutoSubscriptions.direct_blockers_for(%State{}, id)
      after
        {:ok, _pid} =
          Supervisor.restart_child(Aiur.Supervisor, Aiur.Events.SubscriptionStoreRegistry)
      end
    end

    test "is unavailable-safe when the attached store exits after registry lookup", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)
      on_exit(fn -> SubscriptionStore.set_registry_lookup_fn(nil) end)

      SubscriptionStore.set_registry_lookup_fn(fn _registry, identifier ->
        assert identifier == id
        Process.exit(pid, :shutdown)
        [{pid, nil}]
      end)

      assert SubscriptionStore.snapshot(id) == :not_found
    end
  end

  describe "add_subscription/3" do
    test "writes file and registers with Exchange", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "auto:test")

      snap = SubscriptionStore.snapshot(id)
      [entry] = snap.subscribed_to
      assert entry["topic"] == "ticket.42.#"
      assert entry["reason"] == "auto:test"
      assert is_integer(entry["subscription_created_at_event_id"])

      path = SubscriptionStore.path_for(id)

      {:ok, json} = JsonStore.read(path)
      assert [%{"topic" => "ticket.42.#"}] = json["subscribed_to"]
    end

    test "idempotent: re-add preserves both reason and floor (first-write-wins)", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "first")
      [entry1] = SubscriptionStore.snapshot(id).subscribed_to
      floor1 = entry1["subscription_created_at_event_id"]

      # Cause IdGenerator to advance so peek would return a different value
      _ = IdGenerator.next_id()

      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "second")
      [entry2] = SubscriptionStore.snapshot(id).subscribed_to

      # First write wins on both reason and floor — overwriting either
      # would let an auto-sub pass clobber a manual claim and break
      # reason-scoped removal.
      assert entry2["reason"] == "first"
      assert entry2["subscription_created_at_event_id"] == floor1
    end

    test "refuses an unsafe live manual agent binding", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)

      assert {:error, :agent_subscription_scope_forbidden} =
               SubscriptionStore.add_subscription(id, "executor.#", "manual:agent")

      assert SubscriptionStore.snapshot(id).subscribed_to == []
    end
  end

  describe "remove_subscription/2" do
    test "removes entry and unsubscribes from Exchange", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "x")
      :ok = SubscriptionStore.remove_subscription(id, "ticket.42.#")

      snap = SubscriptionStore.snapshot(id)
      assert snap.subscribed_to == []
    end

    test "no-op when topic not subscribed", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.remove_subscription(id, "never.bound")
      assert SubscriptionStore.snapshot(id).subscribed_to == []
    end
  end

  describe "advance_cursor/2" do
    test "advances and persists", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.advance_cursor(id, 100)
      assert SubscriptionStore.snapshot(id).last_seen_event_id == 100
    end

    test "never rewinds", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.advance_cursor(id, 100)
      :ok = SubscriptionStore.advance_cursor(id, 50)
      assert SubscriptionStore.snapshot(id).last_seen_event_id == 100
    end
  end

  describe "attentions" do
    test "add + resolve round-trip", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_attention(id, "needs-review")
      assert SubscriptionStore.snapshot(id).open_attentions == ["needs-review"]

      :ok = SubscriptionStore.resolve_attention(id, "needs-review")
      assert SubscriptionStore.snapshot(id).open_attentions == []
    end

    test "resolve of unknown slug is a no-op", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.resolve_attention(id, "unknown")
      assert SubscriptionStore.snapshot(id).open_attentions == []
    end

    test "add is idempotent", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_attention(id, "a")
      :ok = SubscriptionStore.add_attention(id, "a")
      assert SubscriptionStore.snapshot(id).open_attentions == ["a"]
    end
  end

  describe "open_attention_count/1" do
    test "counts open attentions and tracks resolution", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      assert SubscriptionStore.open_attention_count(id) == 0
      assert SubscriptionStore.open_attention_count_result(id) == {:ok, 0}

      :ok = SubscriptionStore.add_attention(id, "needs-review")
      :ok = SubscriptionStore.add_attention(id, "needs-input")
      assert SubscriptionStore.open_attention_count(id) == 2
      assert SubscriptionStore.open_attention_count_result(id) == {:ok, 2}

      :ok = SubscriptionStore.resolve_attention(id, "needs-review")
      assert SubscriptionStore.open_attention_count(id) == 1
    end

    test "returns 0 for an identifier with no attached store" do
      assert SubscriptionStore.open_attention_count("no-such-identifier") == 0
      assert SubscriptionStore.open_attention_count_result("no-such-identifier") == {:error, :unavailable}
    end

    test "does not call a suspended per-ticket store", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_attention(id, "needs-review")
      [{pid, _count}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)
      :ok = :sys.suspend(pid)

      try do
        task = Task.async(fn -> SubscriptionStore.open_attention_count(id) end)
        assert Task.await(task, 100) == 1
      after
        :ok = :sys.resume(pid)
      end
    end

    test "restores the direct-read count from durable state", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_attention(id, "needs-review")
      :ok = SubscriptionStore.stop(id)
      assert SubscriptionStore.open_attention_count(id) == 0
      assert SubscriptionStore.open_attention_count_result(id) == {:error, :unavailable}

      :ok = SubscriptionStore.attach(id)
      assert SubscriptionStore.open_attention_count(id) == 1
      assert SubscriptionStore.open_attention_count_result(id) == {:ok, 1}
    end
  end
end
