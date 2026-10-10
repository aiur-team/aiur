defmodule Aiur.BuildOrder.TicketHistoryProviderLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.TicketHistory.Failure
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.{TicketObservation, TrackerIdentity}

  setup do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
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

  test "re-subscribes after the Exchange process restarts" do
    test_pid = self()

    first_exchange =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, exchange} = Agent.start_link(fn -> first_exchange end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(exchange)
    end)

    _server =
      start_provider(
        exchange_subscribe_fun: fn ->
          send(test_pid, :exchange_subscribed)
          :ok
        end,
        exchange_pid_fun: fn -> Agent.get(exchange, & &1) end
      )

    assert_receive :exchange_subscribed, 1000

    second_exchange =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Agent.update(exchange, fn _ -> second_exchange end)
    Process.exit(first_exchange, :kill)

    assert_receive :exchange_subscribed, 2_000
    Process.exit(second_exchange, :kill)
  end

  defp start_provider(opts) do
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
