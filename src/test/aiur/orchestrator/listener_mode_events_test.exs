defmodule Aiur.Orchestrator.ListenerModeEventsTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.{Catalog, Exchange, HistoryStore, Publisher, SubscriptionStore, UniversalSubscriptions}
  alias Aiur.IssueLog.Format
  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.{AutoSubscriptions, ListenerModes, State}

  defmodule History do
    @behaviour HistoryStore
    def record(id, kind, event) do
      send(Application.fetch_env!(:aiur, :listener_event_test_receiver), {:history, id, kind, event})
      :ok
    end
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-mode-events")
    settings = for key <- [HistoryStore, :listener_event_test_receiver, :runtime_state_dir], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :runtime_state_dir, dir)
    Application.put_env(:aiur, HistoryStore, History)
    Application.put_env(:aiur, :listener_event_test_receiver, self())
    tracked = :persistent_term.get({Publisher, :tracked_fn}, :absent)
    Publisher.set_tracked_fn(fn _ -> true end)
    id = Integer.to_string(System.unique_integer([:positive]))
    blocker = id <> "0"
    :ok = Exchange.subscribe("ticket.#{id}.agent.listen-mode.changed")
    :ok = Aiur.AgentPubSub.subscribe_listen_mode(id)

    on_exit(fn ->
      for {key, previous} <- settings do
        case previous do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end

      SubscriptionStore.stop(id)
      SubscriptionStore.stop(blocker)
      SubscriptionStore.set_enqueue_fn(nil)
      if tracked == :absent, do: :persistent_term.erase({Publisher, :tracked_fn}), else: :persistent_term.put({Publisher, :tracked_fn}, tracked)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{id: id, blocker: blocker, state: %State{queue_store: Aiur.AgentQueueStore.new()}}
  end

  test "set_mode publishes the human actor and only mode fields, with emit attribution", %{id: id, state: state} do
    assert Catalog.lookup("ticket.#{id}.agent.listen-mode.changed").attribution == :payload_actor
    assert {:reply, {:ok, view}, updated} = ListenerModes.set_mode(state, id, :async, expected_version: 0, actor: :human)
    assert_received {:listen_mode_changed, ^id, local}
    assert_received {:event, event}
    assert event.topic == "ticket.#{id}.agent.listen-mode.changed"
    assert Map.drop(event, [:id, :topic, :ticket_observation]) == local
    assert local == Map.take(view, [:requested, :effective, :effective_reason, :version, :actor])
    assert local.actor == :human
    assert_received {:history, ^id, :emit, ^event}
    assert Format.format_event_marker(:emit, event) =~ " actor=human "
    assert updated.queue_store == state.queue_store
    assert {:reply, {:error, {:mode_conflict, _}}, _} = ListenerModes.set_mode(updated, id, :sync, expected_version: 0)
    refute_received {:event, _}
  end

  test "session changes publish system actor and unknown effective mode", %{id: id} do
    issue = %Aiur.Issue{id: id, identifier: id, selected_backend: "claude-repl"}
    state = %State{running: %{id => %{identifier: id, issue: issue, session_execution: nil}}}
    assert {:noreply, updated} = State.handle_session_execution_info(state, id, %{backend: "unregistered"})
    assert_received {:event, %{actor: :system, effective: nil, effective_reason: :harness_unknown} = event}
    assert_received {:history, ^id, :emit, ^event}
    assert {:noreply, _} = State.handle_session_execution_info(updated, id, %{backend: "unregistered"})
    refute_received {:event, _}
  end

  test "exchange unavailable logs failure after saving and broadcasting the mode", %{id: id, state: state} do
    key = {{Exchange, :table}, Exchange}
    table = :persistent_term.get(key)
    :persistent_term.erase(key)

    try do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:reply, {:ok, %{version: 1}}, _} = ListenerModes.set_mode(state, id, :sync, expected_version: 0)
          assert_received {:listen_mode_changed, ^id, %{requested: :sync}}
          assert ModeStore.get(id).requested == :sync
        end)

      assert log =~ "issue_identifier=#{id}"
      refute_received {:event, _}
    after
      :persistent_term.put(key, table)
    end
  end

  # Future-regression guard: default subscriptions already exclude this topic.
  test "published mode changes create no target-agent digest item with default bindings", %{id: id, blocker: blocker, state: state} do
    parent = self()

    SubscriptionStore.set_enqueue_fn(fn target, event ->
      send(parent, {:enqueued, target, event})
      :ok
    end)

    assert :ok = UniversalSubscriptions.attach(id)
    assert :ok = AutoSubscriptions.subscribe_for_declared_blocker(id, blocker)
    assert {:reply, {:ok, _}, _} = ListenerModes.set_mode(state, id, :sync, expected_version: 0)
    assert_received {:event, %{topic: topic}}
    assert topic == "ticket.#{id}.agent.listen-mode.changed"
    assert SubscriptionStore.snapshot(id).last_seen_event_id == nil
    assert SubscriptionStore.snapshot(blocker).last_seen_event_id == nil
    refute_received {:enqueued, _, _}
  end
end
