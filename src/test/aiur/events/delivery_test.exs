defmodule Aiur.Events.DeliveryTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Events.{Delivery, IdGenerator, SubscriptionStore}

  defmodule Sink do
    @behaviour Delivery
    @impl true
    def enqueue(id, event, context) do
      send(event.test_pid, {:delivered, id, event.id, context})
      Map.get(event, :result, :ok)
    end

    @impl true
    def dead_letter(id, event_id, topic, reason, attempts) do
      send(Process.whereis(Aiur.Events.DeliveryTest), {:dead_letter, id, event_id, topic, reason, attempts})
      :ok
    end
  end

  defmodule RaisingSink do
    @behaviour Delivery
    @impl true
    def enqueue(_, _, _), do: raise("sink failed")
    @impl true
    defdelegate dead_letter(id, event_id, topic, reason, attempts), to: Sink
  end

  defmodule UndefinedEnqueue do
    defdelegate dead_letter(id, event_id, topic, reason, attempts), to: Sink
  end

  defmodule DeadLetterFailure do
    @behaviour Delivery
    @impl true
    def enqueue(_, _, _), do: {:error, {:raised, :permanent}}
    @impl true
    def dead_letter(_, _, _, _, _), do: raise("dead-letter sink failed")
  end

  setup do
    tmp = Aiur.TestSupport.tmp_root!("delivery_seam")
    original = Application.fetch_env!(:aiur, Delivery)
    original_fn = :persistent_term.get({SubscriptionStore, :enqueue_fn}, nil)
    Application.put_env(:aiur, Delivery, Sink)
    SubscriptionStore.set_enqueue_fn(nil)
    Process.register(self(), __MODULE__)
    id = "sink-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.put_env(:aiur, Delivery, original)
      SubscriptionStore.set_enqueue_fn(original_fn)
      Aiur.TestCleanup.rm_rf!(tmp)
    end)

    Aiur.TestSupport.put_runtime_state_dir!(Path.join(tmp, "runtime"))
    %{identifier: id}
  end

  defp attach(id) do
    # ExUnit stops children before on_exit restores the global delivery sink.
    # Intentional crashes must not restart under the application's supervisor.
    pid = start_supervised!({SubscriptionStore, identifier: id}, restart: :temporary)
    :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "test")
    pid
  end

  defp event(extra \\ %{}) do
    Map.merge(%{id: IdGenerator.peek() + 100, topic: "ticket.42.branch.push", test_pid: self()}, extra)
  end

  test "configured sink receives the event and current bindings; selection is fixed at init", %{identifier: id} do
    pid = attach(id)
    Application.put_env(:aiur, Delivery, RaisingSink)
    event = event()
    send(pid, {:event, event})
    assert %{last_seen_event_id: cursor, subscribed_to: subs} = SubscriptionStore.snapshot(id)
    assert cursor == event.id
    assert_received {:delivered, ^id, ^cursor, %{subscribed_to: ^subs}}
  end

  # Future regression guard: hook priority predates this extraction.
  test "test function takes priority over the configured sink", %{identifier: id} do
    pid = attach(id)
    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn ^id, event ->
      send(test_pid, {:hook, event.id})
      :ok
    end)

    event = event()
    send(pid, {:event, event})
    assert %{last_seen_event_id: cursor} = SubscriptionStore.snapshot(id)
    assert cursor == event.id
    assert_received {:hook, ^cursor}
    refute_received {:delivered, ^id, _, _}
  end

  test "raising sink dead letters through the configured module and advances cursor", %{identifier: id} do
    Application.put_env(:aiur, Delivery, RaisingSink)
    pid = attach(id)
    event = event()
    send(pid, {:event, event})
    assert %{last_seen_event_id: cursor} = SubscriptionStore.snapshot(id)
    assert cursor == event.id
    assert_received {:dead_letter, ^id, ^cursor, "ticket.42.branch.push", {:raised, %RuntimeError{message: "sink failed"}}, 1}
  end

  test "transient sink failure dead letters after the existing retry limit", %{identifier: id} do
    pid = attach(id)
    event = event(%{result: {:error, :no_orchestrator}})
    send(pid, {:event, event})
    assert %{last_seen_event_id: nil} = SubscriptionStore.snapshot(id)

    for _ <- 1..3 do
      send(pid, {:retry_stalled})
      SubscriptionStore.snapshot(id)
    end

    assert %{last_seen_event_id: cursor} = SubscriptionStore.snapshot(id)
    assert cursor == event.id
    assert_received {:dead_letter, ^id, ^cursor, "ticket.42.branch.push", :no_orchestrator, 3}
  end

  test "undefined enqueue callback is a permanent failure", %{identifier: id} do
    Application.put_env(:aiur, Delivery, UndefinedEnqueue)
    pid = attach(id)
    event = event()
    send(pid, {:event, event})
    assert %{last_seen_event_id: cursor} = SubscriptionStore.snapshot(id)
    assert cursor == event.id
    assert_received {:dead_letter, ^id, ^cursor, "ticket.42.branch.push", {:raised, %UndefinedFunctionError{module: UndefinedEnqueue, function: :enqueue, arity: 3}}, 1}
  end

  test "dead-letter sink exceptions terminate the store", %{identifier: id} do
    Application.put_env(:aiur, Delivery, DeadLetterFailure)
    pid = attach(id)
    monitor = Process.monitor(pid)
    send(pid, {:event, event()})
    receive_barrier({:DOWN, ^monitor, :process, ^pid, {%RuntimeError{message: "dead-letter sink failed"}, _}})
  end
end
