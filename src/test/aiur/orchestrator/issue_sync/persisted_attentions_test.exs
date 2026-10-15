defmodule Aiur.Orchestrator.IssueSync.PersistedAttentionsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.AlertFeed
  alias Aiur.AlertLedger
  alias Aiur.Config
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "resolves and rearms a persisted observed error after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("observed-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-observed_tracker_error"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(topic)
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

    assert_received {:event, %{topic: ^resolved_topic}}
    refute Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true), &(&1["topic"] == topic))

    _ =
      IssueSync.sync_polled_issue_state(
        recovered,
        [%{issue | state: "error"}],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: ^topic}}
  end

  test "resolves a persisted retry-exhaustion error with its own cause after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("retry-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-retry_exhausted"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    _ =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: ^resolved_topic}}
  end

  test "resolves and rearms a persisted tracker pause after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("pause-restart", "rework")
    paused = %{issue | paused: true}
    topic = "ticket.#{issue.identifier}.agent.paused"
    resolved_topic = "#{topic}.resolved"
    workspace = Aiur.Workspace.workspace_path_under(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    _opened =
      IssueSync.sync_polled_issue_state(
        %State{},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: ^topic}}
    :ok = AlertLedger.append(%{"topic" => "system.supervision.degraded", "needs_attention" => true})
    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), &(&1["topic"] == topic))

    _restart_with_pause =
      IssueSync.sync_polled_issue_state(
        %State{},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    mailbox_barrier()
    refute_received {:event, %{topic: ^topic}}

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

    assert_received {:event, %{topic: ^resolved_topic}}
    refute Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true), &(&1["topic"] == topic))

    _ =
      IssueSync.sync_polled_issue_state(
        recovered,
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:event, %{topic: ^topic}}
  end

  test "does not duplicate an error alert already emitted by a specialized producer" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#specialized-error.agent.attention.error-observed_tracker_error")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("specialized-error", "rework")
    errored = %{previous | state: "error"}

    _ =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, observed_error_alerts: MapSet.new([previous.id])},
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    mailbox_barrier()
    refute_received {:event, %{topic: "ticket.its-everdred/aiur#specialized-error.agent.attention.error-observed_tracker_error"}}
  end
end
