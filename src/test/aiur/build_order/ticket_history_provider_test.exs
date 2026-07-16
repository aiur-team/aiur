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
        history_fun: fn identifier, opts ->
          send(test_pid, {:history_query, identifier, opts})
          raw
        end,
        activity_snapshot_fun: fn _identity -> {:ok, activity()} end
      )

    assert {:ok, %Snapshot{} = snapshot} = TicketHistoryProvider.request(server, identity())
    assert_receive {:history_query, "42", opts}
    assert opts[:limit] == 100
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
        history_fun: fn identifier, _opts ->
          send(test_pid, {:queried, identifier})
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

    refute_receive {:queried, _}

    assert {:ok, snapshot} = TicketHistoryProvider.request(server, identity())
    assert_receive {:queried, "42"}
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

    subscriber =
      spawn(fn ->
        :ok = TicketHistoryProvider.subscribe(server, identity())
      end)

    ref = Process.monitor(subscriber)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

    send(server, {:event, typed_event(21, ~U[2026-07-15 12:00:21Z], 70)})

    assert_receive {:ticket_history_updated, %Snapshot{generation: second_generation, entries: [%{event_id: 21} | _]}},
                   500

    assert second_generation > first_generation

    send(server, {:event, typed_event(21, ~U[2026-07-15 12:00:21Z], 70)})
    refute_receive {:ticket_history_updated, _snapshot}, 50
    assert Process.alive?(server)
  end

  test "evicts the least-recently-used identity at the configured bound" do
    server =
      start_provider(
        max_identities: 2,
        history_fun: fn identifier, _ -> [history_event(String.to_integer(identifier))] end,
        activity_snapshot_fun: fn _ -> {:ok, activity()} end
      )

    one = identity(identifier: "1", provider_id: "I-1")
    two = identity(identifier: "2", provider_id: "I-2")
    three = identity(identifier: "3", provider_id: "I-3")

    assert {:ok, _} = TicketHistoryProvider.request(server, one)
    assert {:ok, _} = TicketHistoryProvider.request(server, two)
    assert {:ok, _} = TicketHistoryProvider.current(server, one)
    assert {:ok, _} = TicketHistoryProvider.request(server, three)

    assert {:ok, %{generation: :unknown, health: :missing_source}} =
             TicketHistoryProvider.current(server, two)

    assert {:ok, %{generation: generation}} = TicketHistoryProvider.current(server, one)
    assert is_integer(generation)
    assert length(TicketHistoryProvider.snapshots(server)) == 2
  end

  test "current is I/O-free and does not call an unqueried source known-empty" do
    test_pid = self()

    server =
      start_provider(
        history_fun: fn _, _ ->
          send(test_pid, :history_queried)
          []
        end
      )

    assert {:ok, snapshot} = TicketHistoryProvider.current(server, identity())
    assert snapshot.health == :missing_source
    assert snapshot.source_health == %{activity: :missing_source, history: :missing_source}
    refute_receive :history_queried
  end

  test "restart restores only durable markers and reports current activity unknown" do
    first = start_provider(activity_snapshot_fun: fn _ -> {:error, :not_found} end)
    send(first, {:event, typed_event(30, ~U[2026-07-15 12:00:30Z], 80)})
    _ = :sys.get_state(first)
    assert {:ok, %{entries: [%{event_id: 30}]}} = TicketHistoryProvider.current(first, identity())
    GenServer.stop(first)

    restarted =
      start_provider(
        history_fun: fn _, _ -> [history_event(30)] end,
        activity_snapshot_fun: fn _ -> {:error, :not_found} end
      )

    assert {:ok, snapshot} = TicketHistoryProvider.request(restarted, identity())
    assert snapshot.health == :restart_unknown
    assert snapshot.source_health == %{activity: :missing_source, history: :available}
    assert snapshot.progress == %{status: :unknown}
  end

  test "workflow repository changes reset retained identities" do
    {:ok, repository} = Agent.start_link(fn -> {:ok, {"owner", "repo"}, 1} end)

    server =
      start_provider(
        configured_repo: nil,
        repository_snapshot_fun: fn -> Agent.get(repository, & &1) end,
        activity_snapshot_fun: fn _ -> {:ok, activity()} end
      )

    assert {:ok, %{generation: generation}} = TicketHistoryProvider.request(server, identity())
    assert is_integer(generation)

    Agent.update(repository, fn _ -> {:ok, {"owner", "next"}, 2} end)
    send(server, {:workflow_config_updated, 2})
    _ = :sys.get_state(server)

    assert {:error, %Failure{kind: :repository_mismatch}} =
             TicketHistoryProvider.current(server, identity())

    next_identity = identity(repository: "next")

    assert {:ok, %{generation: :unknown, health: :missing_source}} =
             TicketHistoryProvider.current(server, next_identity)
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
      if Process.alive?(server), do: GenServer.stop(server)
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
end
