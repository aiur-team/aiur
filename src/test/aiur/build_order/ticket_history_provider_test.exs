defmodule Aiur.BuildOrder.TicketHistoryProviderTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.TicketHistory.{Failure, Snapshot}
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.{TicketObservation, TrackerIdentity}

  setup do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "composes BO-005 progress and latest evidence with bounded IssueLog history" do
    raw = for id <- 1..120, do: history_event(id)
    test_pid = self()

    server =
      start_provider(
        history_fun: fn identity, opts ->
          send(test_pid, {:history_query, identity, opts})
          raw
        end,
        activity_snapshot_fun: fn _identity -> {:ok, activity()} end
      )

    assert {:ok, %Snapshot{} = snapshot} = TicketHistoryProvider.request(server, identity())
    assert_receive {:history_query, %{identifier: "42"}, opts}, 1000
    assert opts[:limit] == 101
    assert opts[:kinds] == [:emit, :emit_alert, :self]
    assert snapshot.health == :available
    assert snapshot.progress.percent == 40
    assert snapshot.progress.provenance == %{run_id: "run-1", attempt: 1, session_id: "session-1"}
    assert snapshot.latest_evidence.attributes == %{percent: 40}
    assert length(snapshot.entries) == 50
    assert Enum.map(snapshot.entries, & &1.event_id) == Enum.to_list(120..71//-1)
    assert snapshot.truncated?
  end

  test "honors a lower limit and falls back from invalid direct limits" do
    raw = for id <- 1..8, do: history_event(id)
    lower = start_provider(history_limit: 3, history_fun: fn _, _ -> raw end)
    fallback = start_provider(history_limit: 101, history_fun: fn _, _ -> raw end)

    assert {:ok, %{entries: lower_entries, truncated?: true}} =
             TicketHistoryProvider.request(lower, identity())

    assert Enum.map(lower_entries, & &1.event_id) == [8, 7, 6]

    assert {:ok, %{entries: fallback_entries}} = TicketHistoryProvider.request(fallback, identity())
    assert length(fallback_entries) == 8
  end

  test "marks source truncation only after history exceeds the hard maximum" do
    exact_limit =
      start_provider(history_limit: 100, history_fun: fn _, _ -> for id <- 1..100, do: history_event(id) end)

    assert {:ok, %{entries: exact_entries, truncated?: false}} =
             TicketHistoryProvider.request(exact_limit, identity())

    assert length(exact_entries) == 100

    overflow_limit =
      start_provider(history_limit: 100, history_fun: fn _, _ -> for id <- 1..101, do: history_event(id) end)

    assert {:ok, %{entries: overflow_entries, truncated?: true}} =
             TicketHistoryProvider.request(overflow_limit, identity())

    assert Enum.map(overflow_entries, & &1.event_id) == Enum.to_list(101..2//-1)
  end

  test "distinguishes all source-health states without inventing empty activity" do
    assert request_health(history: [], activity: activity()) == :known_empty
    assert request_health(history: [], activity: {:error, :not_found}) == :missing_source
    assert request_health(history: [history_event(1)], activity: {:error, :not_found}) == :restart_unknown
    assert request_health(history: {:error, :disk}, activity: activity()) == :unavailable

    stale_activity = activity(observed_at: ~U[2026-07-15 11:55:00Z], status: :stale)

    assert request_health(history: [history_event(1)], activity: stale_activity) == :stale
    assert request_health(history: [history_event(1)], activity: activity()) == :available
  end

  test "recovers after a structured history source failure" do
    {:ok, source} = Agent.start_link(fn -> {:error, :disk} end)

    server =
      start_provider(
        history_fun: fn _, _ -> Agent.get(source, & &1) end,
        activity_snapshot_fun: fn _ -> {:ok, activity()} end
      )

    assert {:ok, %{health: :unavailable, entries: []}} =
             TicketHistoryProvider.request(server, identity())

    Agent.update(source, fn _ -> [history_event(2)] end)

    assert {:ok, %{health: :available, entries: [%{event_id: 2}]}} =
             TicketHistoryProvider.request(server, identity())
  end

  test "production IssueLog health distinguishes missing, unavailable, and known-empty history" do
    with_log_root(fn ->
      server =
        start_provider(
          history_fun: &Aiur.IssueLog.event_history/2,
          activity_snapshot_fun: fn _ -> {:ok, activity()} end
        )

      path = Aiur.IssueLog.event_log_path(identity())

      assert {:ok, %{health: :missing_source, source_health: %{history: :missing_source}}} =
               TicketHistoryProvider.request(server, identity())

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")

      assert {:ok, %{health: :known_empty, source_health: %{history: :known_empty}}} =
               TicketHistoryProvider.request(server, identity())

      File.rm!(path)
      File.mkdir_p!(path)

      assert {:ok, %{health: :unavailable, source_health: %{history: :unavailable}}} =
               TicketHistoryProvider.request(server, identity())
    end)
  end

  test "production IssueLog reads cannot cross equal repository leaves owned by different accounts" do
    with_log_root(fn ->
      alice = identity(owner: "alice", repository: "project")
      bob = identity(owner: "bob", repository: "project")
      alice_path = Aiur.IssueLog.event_log_path(alice)

      File.mkdir_p!(Path.dirname(alice_path))
      File.write!(alice_path, history_line(9))

      alice_server =
        start_provider(
          configured_repo: {"alice", "project"},
          history_fun: &Aiur.IssueLog.event_history/2
        )

      bob_server =
        start_provider(
          configured_repo: {"bob", "project"},
          history_fun: &Aiur.IssueLog.event_history/2
        )

      assert {:ok, %{entries: [%{event_id: 9}]}} =
               TicketHistoryProvider.request(alice_server, alice)

      assert {:ok, %{health: :missing_source, entries: []}} =
               TicketHistoryProvider.request(bob_server, bob)
    end)
  end

  test "late live events are ordered, deduplicated, and replace disk entries with richer typed provenance" do
    server =
      start_provider(
        history_limit: 3,
        history_fun: fn _, _ -> [history_event(10), history_event(12)] end,
        activity_snapshot_fun: fn _ -> {:error, :not_found} end
      )

    assert {:ok, %{entries: [%{event_id: 12}, %{event_id: 10}]}} =
             TicketHistoryProvider.request(server, identity())

    send(
      server,
      {:event, typed_event(10, ~U[2026-07-15 12:00:10Z], 55, attempt: 2, session_id: "session-2")}
    )

    send(server, {:event, typed_event(11, ~U[2026-07-15 11:59:00Z], 45)})
    _ = :sys.get_state(server)

    assert {:ok, %{entries: entries, truncated?: false}} =
             TicketHistoryProvider.current(server, identity())

    assert Enum.map(entries, & &1.event_id) == [12, 10, 11]
    assert Enum.find(entries, &(&1.event_id == 10)).source == :exchange
    assert Enum.find(entries, &(&1.event_id == 10)).provenance == %{attempt: 2, session_id: "session-2"}
  end

  test "sanitizes before retention and rejects configured-repository collisions before querying" do
    test_pid = self()
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"

    raw = [
      history_event(1,
        summary: "prompt #{secret} /home/private logs/agent.ndjson terminal output"
      )
    ]

    server =
      start_provider(
        history_fun: fn identity, _opts ->
          send(test_pid, {:queried, identity})
          raw
        end,
        activity_snapshot_fun: fn _ ->
          {:ok,
           activity()
           |> Map.put(:message, "raw model output #{secret}")
           |> Map.put(:local_path, "/home/private")}
        end
      )

    assert {:error, %Failure{kind: :repository_mismatch}} =
             TicketHistoryProvider.request(server, identity(owner: "other"))

    refute_receive {:queried, _}, 100

    assert {:ok, snapshot} = TicketHistoryProvider.request(server, identity())
    assert_receive {:queried, %{identifier: "42"}}, 1000
    refute inspect(snapshot) =~ secret
    refute inspect(snapshot) =~ "/home/private"
    refute inspect(snapshot) =~ "agent.ndjson"
    refute inspect(snapshot) =~ "terminal output"
    refute inspect(snapshot) =~ "raw model output"
  end

  test "publishes immutable per-ticket updates and tolerates subscriber churn" do
    server = start_provider()
    :ok = TicketHistoryProvider.subscribe(server, identity())

    send(server, {:event, typed_event(20, ~U[2026-07-15 12:00:20Z], 65)})

    assert_receive {:ticket_history_updated,
                    %Snapshot{
                      generation: first_generation,
                      entries: [%{event_id: 20}] = entries
                    }},
                   500

    assert is_integer(first_generation)
    assert entries |> hd() |> Map.from_struct() |> Map.has_key?(:details)

    test_pid = self()

    subscriber =
      spawn(fn ->
        :ok = TicketHistoryProvider.subscribe(server, identity())
        send(test_pid, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(subscriber)
    assert_receive :subscribed, 2_000
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}, 2_000

    send(server, {:event, typed_event(21, ~U[2026-07-15 12:00:21Z], 70)})

    assert_receive {:ticket_history_updated, %Snapshot{generation: second_generation, entries: [%{event_id: 21} | _]}},
                   500

    assert second_generation > first_generation

    send(server, {:event, typed_event(21, ~U[2026-07-15 12:00:21Z], 70)})
    refute_receive {:ticket_history_updated, _snapshot}, 50
    assert Process.alive?(server)
  end

  defp request_health(opts) do
    history = Keyword.fetch!(opts, :history)
    activity = Keyword.fetch!(opts, :activity)

    server =
      start_provider(
        history_fun: fn _, _ -> history end,
        activity_snapshot_fun: fn _ -> normalize_activity_result(activity) end
      )

    assert {:ok, snapshot} = TicketHistoryProvider.request(server, identity())
    snapshot.health
  end

  defp normalize_activity_result({:error, _reason} = result), do: result
  defp normalize_activity_result(activity), do: {:ok, activity}

  defp start_provider(opts \\ []) do
    defaults = [
      name: nil,
      configured_repo: {"owner", "repo"},
      exchange_subscribe_fun: fn -> :ok end,
      exchange_pid_fun: fn -> nil end,
      activity_subscribe_fun: fn -> :ok end,
      configuration_subscribe_fun: fn _pid -> :ok end,
      activity_snapshots_fun: fn -> %{entries: []} end,
      activity_snapshot_fun: fn _identity -> {:error, :not_found} end,
      history_fun: fn _identifier, _opts -> [] end,
      now: fn -> ~U[2026-07-15 12:01:00Z] end,
      stale_after_ms: 300_000
    ]

    {:ok, server} = TicketHistoryProvider.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(server)
    end)

    server
  end

  defp activity(opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, ~U[2026-07-15 12:00:00Z])
    status = Keyword.get(opts, :status, :fresh)

    %{
      identity: identity(),
      status: status,
      active_stage: :work,
      progress: %{
        status: :known,
        freshness: status,
        percent: 40,
        source: :checkin,
        provenance: %{run_id: "run-1", attempt: 1, session_id: "session-1"},
        observed_at: observed_at,
        event_id: 4
      },
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        attributes: %{percent: 40},
        provenance: %{run_id: "run-1", attempt: 1, session_id: "session-1"},
        observed_at: observed_at,
        event_id: 4
      },
      observed_at: observed_at,
      retention: :current
    }
  end

  defp history_event(id, opts \\ []) do
    timestamp =
      ~U[2026-07-15 12:00:00Z]
      |> DateTime.add(id, :second)
      |> DateTime.to_iso8601()

    %{
      kind: "emit",
      id: id,
      topic: Keyword.get(opts, :topic, "ticket.42.pr.opened"),
      ts: Keyword.get(opts, :ts, timestamp),
      summary: Keyword.get(opts, :summary, "unsafe arbitrary provider text")
    }
  end

  defp history_line(id) do
    timestamp =
      ~U[2026-07-15 12:00:00Z]
      |> DateTime.add(id, :second)
      |> DateTime.to_iso8601()

    "#{timestamp} [event:emit] id=#{id} ticket.42.pr.opened: unsafe arbitrary provider text\n"
  end

  defp typed_event(id, observed_at, percent, provenance \\ []) do
    %{
      ticket_observation: %TicketObservation{
        status: :joinable,
        reason: nil,
        tracker_identity: identity(),
        source: %{kind: :agent_event, name: "progress"},
        event_id: id,
        provenance: Map.new(provenance),
        occurred_at: observed_at,
        observed_at: observed_at,
        attributes: %{percent: percent}
      }
    }
  end

  defp identity(opts \\ []) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: Keyword.get(opts, :owner, "owner"),
      repository: Keyword.get(opts, :repository, "repo"),
      provider_id: Keyword.get(opts, :provider_id, "I-42"),
      identifier: Keyword.get(opts, :identifier, "42"),
      reason: nil
    }
  end

  defp with_log_root(fun) do
    original_log_file = Application.get_env(:aiur, :log_file)
    tmp = Aiur.TestSupport.tmp_root!("ticket-history-provider")
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    try do
      fun.()
    after
      case original_log_file do
        nil -> Application.delete_env(:aiur, :log_file)
        value -> Application.put_env(:aiur, :log_file, value)
      end

      File.rm_rf!(tmp)
    end
  end
end
