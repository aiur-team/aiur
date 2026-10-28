defmodule AiurWeb.ListenerModeEventsTest do
  use Aiur.TestSupport
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Aiur.{AgentQueue, AgentQueueStore, Listener, Orchestrator}
  alias Aiur.Orchestrator.{ListenerModes, State}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{DashboardLive, ListenerModeEvents}
  alias AiurWeb.OperatorControlCenter.ListenerMode
  alias Phoenix.LiveView.Async

  defmodule Server do
    use GenServer
    alias Aiur.Orchestrator.OperatorMessages.Snapshot
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:operator_message_snapshot, id}, _from, state), do: Snapshot.handle_call(state, id)
    def handle_call({:listener_get_mode, id}, _from, state), do: ListenerModes.get_mode(state, id)
    def handle_call({:listener_set_mode, id, mode, opts}, _from, state), do: ListenerModes.set_mode(state, id, mode, opts)
  end

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)
    dir = Aiur.TestSupport.tmp_root!("listener-dashboard")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    start_supervised!({Server, %State{last_polled_issues: %{"42" => %{identifier: "42"}}}})
    EndpointStubs.put(dashboard_writable: true)
    {:ok, record} = Listener.get_mode("42")

    socket =
      assign(%Phoenix.LiveView.Socket{},
        writable: true,
        agent_log_modal: %{issue_identifier: "42", writable_target?: true},
        listener_view: Map.put(record, :routing, :listener),
        listener_identifier: "42",
        listener_feedback: %{},
        listener_receipts: []
      )

    %{socket: socket}
  end

  test "dashboard mute selection persists the mode and confirms its value", %{socket: socket} do
    Aiur.AgentPubSub.subscribe_listen_mode("42")
    {:noreply, pending} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "mute", "expected_version" => "0"}, socket)
    assert pending.assigns.listener_feedback.state == :pending
    event = receive_barrier({:listen_mode_changed, "42", %{version: 1, requested: :mute}})
    {:noreply, confirmed} = DashboardLive.handle_info(event, pending)
    assert confirmed.assigns.listener_view.requested == :mute
    assert confirmed.assigns.listener_view.effective == :mute
    assert {:ok, %{requested: :mute, version: 1}} = Listener.get_mode("42")
  end

  test "stale expected version shows conflict and durable winner", %{socket: socket} do
    assert {:ok, %{version: 1}} = Listener.set_mode("42", :steer, expected_version: 0)
    assert {:noreply, changed} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "async", "expected_version" => "0"}, socket)
    assert changed.assigns.listener_feedback == %{state: :conflict, choice: :async}
    assert changed.assigns.listener_view.requested == :steer
    assert {:ok, %{requested: :steer, version: 1}} = Listener.get_mode("42")
  end

  test "write stays pending until the matching change event arrives", %{socket: socket} do
    Aiur.AgentPubSub.subscribe_listen_mode("42")
    {:noreply, changed} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "async", "expected_version" => "0"}, socket)
    assert changed.assigns.listener_feedback.state == :pending
    assert changed.assigns.listener_view.requested == :sync
    event = receive_barrier({:listen_mode_changed, "42", %{version: 1, requested: :async}})
    {:noreply, confirmed} = DashboardLive.handle_info(event, changed)
    assert confirmed.assigns.listener_feedback == %{left_async: false}
    assert confirmed.assigns.listener_view.requested == :async
    assert {:ok, %{requested: :async, version: 1}} = Listener.get_mode("42")
  end

  test "missing event times out and unrelated or older events cannot confirm", %{socket: socket} do
    {:noreply, pending} = ListenerModeEvents.change(%{"mode" => "async", "expected_version" => "0"}, socket)
    assert {:noreply, ^pending} = DashboardLive.handle_info({:listen_mode_changed, "other", %{version: 1}}, pending)
    {:noreply, timeout} = DashboardLive.handle_info({:listener_timeout, "42", 1}, pending)
    assert timeout.assigns.listener_feedback.state == :error
  end

  test "future regression guard: legacy, read-only, ambiguous targets and invalid input never write", %{socket: socket} do
    for blocked <- [assign(socket, writable: false), assign(socket, listener_view: %{routing: :legacy}), assign(socket, agent_log_modal: %{writable_target?: false})] do
      assert {:noreply, ^blocked} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "async", "expected_version" => "0"}, blocked)
    end

    assert {:noreply, ^socket} = ListenerModeEvents.change(%{"mode" => "invalid", "expected_version" => "0"}, socket)
    assert {:ok, %{version: 0}} = Listener.get_mode("42")
  end

  test "leaving async shows notice without delivering unread bodies", %{socket: socket} do
    {:ok, record} = Listener.set_mode("42", :async, expected_version: 0)
    socket = assign(socket, listener_view: Map.put(record, :routing, :listener))
    {:noreply, pending} = ListenerModeEvents.change(%{"mode" => "sync", "expected_version" => "1"}, socket)
    assert pending.assigns.listener_feedback.left_async
    assert {:ok, %{requested: :sync, version: 2}} = Listener.get_mode("42")
  end

  test "cached row refresh cannot roll back an event-confirmed version", %{socket: socket} do
    {:noreply, pending} = ListenerModeEvents.change(%{"mode" => "async", "expected_version" => "0"}, socket)
    {:noreply, confirmed} = DashboardLive.handle_info({:listen_mode_changed, "42", %{version: 1, requested: :async, effective: nil, effective_reason: :not_running}}, pending)
    older = Map.merge(socket.assigns.listener_view, %{unread_count: 2, freshness: :stale})
    refreshed = confirmed |> assign(conversation_row: %{listener: older}) |> ListenerModeEvents.refresh()
    assert refreshed.assigns.listener_view.version == 1
    assert refreshed.assigns.listener_view.requested == :async
    assert refreshed.assigns.listener_view.freshness == :stale
    assert refreshed.assigns.listener_view.unread_count == 2
    assert {:noreply, ^refreshed} = DashboardLive.handle_info({:listen_mode_changed, "42", %{version: 0, requested: :sync}}, refreshed)
  end

  test "same-version effective event survives an older snapshot", %{socket: socket} do
    prior = socket.assigns.listener_view |> Map.put(:observed_at, DateTime.add(DateTime.utc_now(), -30))
    {:noreply, changed} = DashboardLive.handle_info({:listen_mode_changed, "42", %{version: 0, requested: :sync, effective: :sync, effective_reason: nil}}, socket)
    refreshed = changed |> assign(conversation_row: %{listener: prior}) |> ListenerModeEvents.refresh()
    assert refreshed.assigns.listener_view.effective == :sync
    assert refreshed.assigns.listener_view.effective_reason == nil
  end

  test "receipt tick observes real held and read states and rejects old drawer timers", %{socket: socket} do
    {store, item} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message("42", "message", listener_mode: :async))
    :sys.replace_state(Orchestrator, &%{&1 | queue_store: store})
    token = make_ref()
    socket = %{socket | transport_pid: self(), view: DashboardLive} |> assign(listener_timer: token, listener_receipts_busy: false) |> ListenerModeEvents.sent({:ok, item.id})
    held = receipt_tick(socket, token)
    assert [%{receipt: :held_async, request_id: id}] = held.assigns.listener_receipts
    assert id == item.id
    assert {:noreply, ^held} = DashboardLive.handle_info({:listener_refresh, "42", make_ref()}, held)
    read = %{item | status: :consumed, read_at: DateTime.utc_now()}
    :sys.replace_state(Orchestrator, &%{&1 | queue_store: %{store | items: Map.put(store.items, item.id, read)}})
    observed = receipt_tick(held, token)
    assert [%{receipt: :read}] = observed.assigns.listener_receipts
    stop_supervised!(Server)
    retained = receipt_tick(observed, token)
    assert [%{receipt: :read}] = retained.assigns.listener_receipts
    unknown = socket |> ListenerModeEvents.sent({:ok, 99})
    unavailable = receipt_tick(unknown, token)
    assert Enum.all?(unavailable.assigns.listener_receipts, &(&1.receipt == :unknown))
  end

  test "failed set mode shows the failure state and error text", %{socket: socket} do
    stop_supervised!(Server)
    {:noreply, failed} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "async", "expected_version" => "0"}, socket)
    assert_error_rendered(failed)
  end

  test "failed refresh shows the failure state and error text", %{socket: socket} do
    stop_supervised!(Server)
    {:noreply, failed} = DashboardLive.handle_event("refresh_listen_mode", %{}, socket)
    assert_error_rendered(failed)
  end

  test "stale and offline observations refuse writes on the server", %{socket: socket} do
    for freshness <- [:stale, :offline] do
      blocked = assign(socket, listener_view: Map.put(socket.assigns.listener_view, :freshness, freshness))
      assert {:noreply, ^blocked} = DashboardLive.handle_event("set_listen_mode", %{"mode" => "async", "expected_version" => "0"}, blocked)
      assert {:ok, %{version: 0, requested: :sync}} = Listener.get_mode("42")
    end
  end

  test "send result keeps accepted, failed and outcome unknown distinct", %{socket: socket} do
    socket = socket |> ListenerModeEvents.sent({:ok, 12}) |> ListenerModeEvents.sent({:error, :unavailable}) |> ListenerModeEvents.sent({:error, {:outcome_unknown, %{}}})
    assert socket.assigns.listener_receipts == [%{request_id: nil, receipt: :outcome_unknown}, %{request_id: nil, receipt: :failed}, %{request_id: 12, receipt: :accepted}]
  end

  defp assert_error_rendered(socket) do
    assert socket.assigns.listener_feedback.state == :error
    html = render_component(&ListenerMode.listener_mode/1, listener: socket.assigns.listener_view, feedback: socket.assigns.listener_feedback, now: DateTime.utc_now(), writable: true)
    assert html =~ "could not be confirmed"
  end

  defp receipt_tick(socket, token) do
    socket = %{socket | private: Map.put(socket.private, :lifecycle, %Phoenix.LiveView.Lifecycle{})}
    {:noreply, pending} = DashboardLive.handle_info({:listener_refresh, "42", token}, socket)
    assert pending.assigns.listener_receipts_busy
    {:phoenix, :async_result, {:start, {ref, cid, key, result}}} = receive_barrier({:phoenix, :async_result, {:start, {_ref, _cid, {:listener_receipts, "42", ^token}, _result}}})
    Async.handle_async(pending, cid, :start, key, ref, result)
  end
end
