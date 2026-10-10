defmodule Aiur.BuildOrder.TicketHistoryProviderEvictionTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.TrackerIdentity

  setup do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "evicts the least-recently-used identity at the configured bound" do
    server =
      start_provider(
        max_identities: 2,
        history_fun: fn identity, _ -> [history_event(String.to_integer(identity.identifier))] end,
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

  test "eviction and rehydration notifications use strictly increasing generations" do
    server =
      start_provider(
        max_identities: 1,
        history_fun: fn identity, _ -> [history_event(String.to_integer(identity.identifier))] end
      )

    one = identity(identifier: "1", provider_id: "I-1")
    two = identity(identifier: "2", provider_id: "I-2")
    :ok = TicketHistoryProvider.subscribe(server, one)
    :ok = TicketHistoryProvider.subscribe(server, two)

    assert {:ok, %{generation: first_generation}} = TicketHistoryProvider.request(server, one)
    assert_receive {:ticket_history_updated, %{identity: ^one, generation: ^first_generation}}, 2_000

    assert {:ok, %{generation: second_generation}} = TicketHistoryProvider.request(server, two)
    assert_receive {:ticket_history_evicted, ^one, first_eviction_generation}, 2_000
    assert_receive {:ticket_history_updated, %{identity: ^two, generation: ^second_generation}}, 2_000
    assert first_generation < first_eviction_generation
    assert first_eviction_generation < second_generation

    assert {:ok, %{generation: rehydrated_generation}} = TicketHistoryProvider.request(server, one)
    assert_receive {:ticket_history_evicted, ^two, second_eviction_generation}, 2_000
    assert_receive {:ticket_history_updated, %{identity: ^one, generation: ^rehydrated_generation}}, 2_000
    assert second_generation < second_eviction_generation
    assert second_eviction_generation < rehydrated_generation
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
    refute_receive :history_queried, 100
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
