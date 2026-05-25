defmodule Aiur.Events.SubscriptionStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.{Exchange, SubscriptionStore}
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

      File.rm_rf!(tmp_dir)
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

  describe "add_subscription/3" do
    test "writes file and registers with Exchange", %{identifier: id, tmp_dir: dir} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "auto:test")

      snap = SubscriptionStore.snapshot(id)
      [entry] = snap.subscribed_to
      assert entry["topic"] == "ticket.42.#"
      assert entry["reason"] == "auto:test"
      assert is_integer(entry["subscription_created_at_event_id"])

      # File on disk matches
      path = Path.join(dir, "aiur." <> safe_id(id) <> ".subscriptions.json")
      {:ok, json} = JsonStore.read(path)
      assert [%{"topic" => "ticket.42.#"}] = json["subscribed_to"]
    end

    test "idempotent: re-add updates reason but preserves floor", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "first")
      [entry1] = SubscriptionStore.snapshot(id).subscribed_to
      floor1 = entry1["subscription_created_at_event_id"]

      # Cause IdGenerator to advance so peek would return a different value
      _ = Aiur.Events.IdGenerator.next_id()

      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "second")
      [entry2] = SubscriptionStore.snapshot(id).subscribed_to

      assert entry2["reason"] == "second"
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

  defp eventually_has_event?(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_has_event?(pid, deadline, deadline)
  end

  defp eventually_has_event?(pid, deadline, _) do
    now = System.monotonic_time(:millisecond)

    cond do
      now > deadline ->
        false

      true ->
        {:messages, msgs} = Process.info(pid, :messages)

        if Enum.any?(msgs, fn
             {:event, _} -> true
             _ -> false
           end) do
          true
        else
          Process.sleep(20)
          eventually_has_event?(pid, deadline, deadline)
        end
    end
  end
end
