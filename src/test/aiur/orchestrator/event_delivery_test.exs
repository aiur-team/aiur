defmodule Aiur.Orchestrator.EventDeliveryTest do
  use ExUnit.Case, async: false
  alias Aiur.Orchestrator.EventDelivery

  defmodule Receiver do
    use GenServer
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}
    @impl true
    def handle_call(message, from, test_pid) do
      send(test_pid, {:call, from, message})
      {:noreply, test_pid}
    end
  end

  defmodule AlertSink do
    def emit_system(topic, opts) do
      send(self(), {:alert, topic, opts})
      :ok
    end
  end

  setup do
    original = Process.whereis(Aiur.Orchestrator)

    if original do
      :ok = :sys.suspend(original)
      Process.unregister(Aiur.Orchestrator)
    end

    on_exit(fn ->
      if original && Process.alive?(original) do
        Process.register(original, Aiur.Orchestrator)
        :ok = :sys.resume(original)
      end
    end)

    :ok
  end

  test "default dead letter preserves warning and alert fields" do
    original = Application.fetch_env!(:aiur, :signal)
    on_exit(fn -> Application.put_env(:aiur, :signal, original) end)
    Application.put_env(:aiur, :signal, alert_sink: AlertSink)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = EventDelivery.dead_letter("42", 100, "ticket.42.branch.push", :busy, 3)
      end)

    assert log =~ "SubscriptionStore(42): giving up on event 100 on topic ticket.42.branch.push after 3 attempt(s): :busy; advancing cursor past failed event"
    assert_received {:alert, "system.subscription_store.event_dead_lettered", opts}
    assert opts == [reason: "enqueue failed after 3 attempt(s) for event 100 on ticket.42.branch.push: :busy", needs_attention: true, severity: "warning"]
  end

  test "default adapter reports absent orchestrator" do
    assert Process.whereis(Aiur.Orchestrator) == nil
    assert EventDelivery.enqueue("42", %{id: 100}, %{subscribed_to: []}) == {:error, :no_orchestrator}
  end

  test "default adapter forwards bindings and preserves return mappings" do
    pid = start_supervised!({Receiver, self()})
    Process.register(pid, Aiur.Orchestrator)
    context = %{subscribed_to: [%{"topic" => "ticket.42.#"}]}
    event = %{id: 100}

    for {reply, expected} <- [{:ok, :ok}, {{:error, :busy}, {:error, :busy}}, {:unexpected, {:error, {:unexpected_return, :unexpected}}}] do
      task = Task.async(fn -> EventDelivery.enqueue("42", event, context) end)

      receive do
        {:call, from, {:enqueue_event_digest, "42", ^event, ^context}} -> GenServer.reply(from, reply)
      end

      assert Task.await(task) == expected
    end
  end

  test "default adapter keeps the 1000 ms enqueue timeout and exit mapping" do
    pid = start_supervised!({Receiver, self()})
    Process.register(pid, Aiur.Orchestrator)

    assert {:error, {:exit, {:timeout, {GenServer, :call, [^pid, {:enqueue_event_digest, "42", %{id: 100}, %{subscribed_to: []}}, 1_000]}}}} =
             EventDelivery.enqueue("42", %{id: 100}, %{subscribed_to: []})
  end
end
