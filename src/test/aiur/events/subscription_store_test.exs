defmodule Aiur.Events.SubscriptionStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.Events.{Exchange, IdGenerator, SubscriptionStore}
  alias Aiur.JsonStore

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_subscr_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    identifier = "test-issue-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SubscriptionStore.stop(identifier)

      if original do
        Application.put_env(:aiur, :log_file, original)
      else
        Application.delete_env(:aiur, :log_file)
      end

      # Non-raising rm_rf: the SubscriptionStore writer persists into this
      # dir via JsonStore's atomic write (a `<path>.tmp.<n>` staging file
      # renamed into place). Under CI load that staging file can land
      # between rm_rf's directory listing and its final rmdir, so the rmdir
      # sees a non-empty dir and fails with :eexist. The dir is unique per
      # test under the system tmp dir, so a rare leftover is harmless —
      # tolerate the race instead of crashing an unrelated run. Matches the
      # `File.rm_rf/1` teardown convention in `Aiur.TestSupport`.
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, identifier: identifier}
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

  describe "add_subscription/3" do
    test "writes file and registers with Exchange", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "auto:test")

      snap = SubscriptionStore.snapshot(id)
      [entry] = snap.subscribed_to
      assert entry["topic"] == "ticket.42.#"
      assert entry["reason"] == "auto:test"
      assert is_integer(entry["subscription_created_at_event_id"])

      path =
        Path.join(
          Paths.log_root_dir(),
          "#{Paths.repo_name()}.#{safe_id(id)}.subscriptions.json"
        )

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

      :ok = SubscriptionStore.add_attention(id, "needs-review")
      :ok = SubscriptionStore.add_attention(id, "needs-input")
      assert SubscriptionStore.open_attention_count(id) == 2

      :ok = SubscriptionStore.resolve_attention(id, "needs-review")
      assert SubscriptionStore.open_attention_count(id) == 1
    end

    test "returns 0 for an identifier with no attached store" do
      assert SubscriptionStore.open_attention_count("no-such-identifier") == 0
    end
  end

  describe "restart restoration" do
    test "reloads bindings into Exchange on init", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.999.#", "test")

      [{old_pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)
      Process.flag(:trap_exit, true)
      ref = Process.monitor(old_pid)
      :ok = SubscriptionStore.stop(id)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}, 1_000

      :ok = SubscriptionStore.attach(id)
      [{new_pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)

      # handle_continue(:load) re-registers bindings asynchronously after
      # init returns, so poll briefly rather than asserting immediately.
      assert eventually(
               fn -> "ticket.999.#" in Exchange.bindings_for(new_pid) end,
               1_000
             )
    end
  end

  describe "Exchange integration" do
    test "Exchange has a binding for every persisted subscription", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.55.#", "test")

      [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)
      assert "ticket.55.#" in Exchange.bindings_for(pid)
    end

    test "attach/1 returns AFTER bindings are registered (no race)", %{identifier: id} do
      # Pre-populate the on-disk subscriptions file so a fresh attach
      # has bindings to re-register during init.
      tmp_path =
        Path.join(
          Paths.log_root_dir(),
          "#{Paths.repo_name()}.#{safe_id(id)}.subscriptions.json"
        )

      File.mkdir_p!(Path.dirname(tmp_path))

      File.write!(
        tmp_path,
        Jason.encode!(%{
          "subscribed_to" => [
            %{
              "topic" => "ticket.901.#",
              "reason" => "test",
              "subscription_created_at_event_id" => 1
            }
          ],
          "last_seen_event_id" => nil,
          "open_attentions" => []
        })
      )

      :ok = SubscriptionStore.attach(id)
      [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)

      # No Process.sleep — bindings must be ready synchronously.
      assert "ticket.901.#" in Exchange.bindings_for(pid)
    end
  end

  describe "cursor redelivery defense" do
    test "events with id <= last_seen_event_id are dropped on handle_info", %{identifier: id} do
      test_pid = self()

      SubscriptionStore.set_enqueue_fn(fn _id, ev ->
        send(test_pid, {:enqueued, ev})
        :ok
      end)

      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.555.#", "test")
      :ok = SubscriptionStore.advance_cursor(id, 1000)

      [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)

      # Simulate Exchange delivering a stale event (id < cursor)
      send(pid, {:event, %{id: 500, topic: "ticket.555.branch.push"}})
      send(pid, {:event, %{id: 1500, topic: "ticket.555.branch.push"}})

      assert_receive {:enqueued, %{id: 1500}}, 500
      refute_receive {:enqueued, %{id: 500}}, 100

      SubscriptionStore.set_enqueue_fn(nil)
    end
  end

  defp safe_id(id) do
    String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_loop(fun, deadline)
  end

  defp eventually_loop(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        eventually_loop(fun, deadline)
    end
  end
end
