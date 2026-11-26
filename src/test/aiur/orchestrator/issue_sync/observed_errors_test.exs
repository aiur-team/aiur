defmodule Aiur.Orchestrator.IssueSync.ObservedErrorsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State
  alias Aiur.Workflow

  test "persists a reason-carrying fallback when polling observes an ordinary error transition" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("observed-error", "rework")
    errored = %{previous | state: "error"}

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}},
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(state.observed_error_alerts, previous.id)

    assert_received {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error"} = event}
    assert event["reason"] =~ "without a specialized local cause"
    assert event["reason"] =~ "will not clear on its own"
    assert event["needs_attention"] == true

    recovered = %{errored | state: "rework"}

    recovered_state =
      IssueSync.sync_polled_issue_state(
        state,
        [recovered],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered_state.observed_error_alerts, previous.id)
    assert_received {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error.resolved"}}

    _ =
      IssueSync.sync_polled_issue_state(
        recovered_state,
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error"}}
  end

  test "does not resolve an observed error while its lifetime latch remains active" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    state = %State{
      observed_error_alerts: MapSet.new([issue.id]),
      observed_error_alert_causes: %{issue.id => :lifetime_latch},
      dispatch_recovery: %{codex_thrash_budget: %{issue.id => %{tripped: :lifetime, lifetime: 2}}}
    }

    recovered =
      IssueSync.sync_polled_issue_state(
        state,
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert recovered.observed_error_alert_causes[issue.id] == :lifetime_latch
    mailbox_barrier()
    refute_received {:event, %{topic: ^resolved_topic}}
  end

  test "re-evaluates a latched error after recovery while tracker state stays unchanged" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error-recovered", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{issue.id => issue},
          observed_error_alerts: MapSet.new([issue.id]),
          observed_error_alert_causes: %{issue.id => :lifetime_latch}
        },
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered.observed_error_alerts, issue.id)
    refute Map.has_key?(recovered.observed_error_alert_causes, issue.id)
    assert_received {:event, %{topic: ^resolved_topic}}
  end

  test "rediscovers and resolves a persisted lifetime latch attention after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert_received {:event, %{topic: ^resolved_topic}}
  end

  test "retains a persisted lifetime latch attention when its budget store is unreadable" do
    Publisher.set_tracked_fn(fn _ -> true end)
    write_workflow_file!(Workflow.workflow_file_path(), max_dispatches_per_ticket: 10)
    issue = issue("latched-error-store-failure", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    store_path = Aiur.TestSupport.tmp_root!("dispatch-budget-invalid") <> ".json"
    previous_store_path = Application.get_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, store_path)
    File.write!(store_path, "not json")
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :dispatch_budget_store_path),
        else: Application.put_env(:aiur, :dispatch_budget_store_path, previous_store_path)

      File.rm(store_path)
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert recovered.observed_error_alert_causes[issue.id] == :lifetime_latch
    mailbox_barrier()
    refute_received {:event, %{topic: ^resolved_topic}}
  end
end
