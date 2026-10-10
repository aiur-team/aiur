defmodule Aiur.BuildOrder.TicketDetailCoordinatorRefreshFailureTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Lifecycle, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.GitHub.ResourceStore

  @configured {"owner", "repo"}

  # The coordinator no longer holds GitHub bodies — `Aiur.GitHub.ResourceStore`
  # does, keyed by the issue rather than by the reader. That is the point of the
  # change, and it means these cases, which all read issue 42 with a different
  # stubbed body, would otherwise serve each other's bodies.
  setup do
    ResourceStore.reset()
    :ok
  end

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  test "survives task-supervisor outage, preserves LKG, and recovers on a later demand" do
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, failed_supervisor} = Task.Supervisor.start_link()

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        task_supervisor: failed_supervisor,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
          {:ok, snapshot(identity, if(attempt == 1, do: "first", else: "recovered"))}
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    :ok = GenServer.stop(failed_supervisor)
    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated, outage_state}, 2_000

    assert %State{
             generation: 2,
             health: :stale,
             detail: %Snapshot{title: "first"},
             failure: %Failure{kind: :transport}
           } = outage_state

    assert Process.alive?(cache)
    {:ok, recovered_supervisor} = Task.Supervisor.start_link()
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, recovered_supervisor))

    assert {:ok, %State{generation: 3, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 3,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }},
                   2_000
  end

  test "survives rejected task startup and recovers after a healthy supervisor is configured" do
    identity = identity(42, "I42")
    {:ok, rejecting_supervisor} = Task.Supervisor.start_link(max_children: 0)

    {:ok, cache} =
      start_cache(
        task_supervisor: rejecting_supervisor,
        reader: fn _identity -> {:ok, snapshot(identity, "recovered")} end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)

    assert {:ok, %State{generation: 1, health: :unavailable, failure: %Failure{kind: :transport}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 1,
                      health: :unavailable,
                      failure: %Failure{kind: :transport}
                    }},
                   2_000

    assert Process.alive?(cache)
    {:ok, healthy_supervisor} = Task.Supervisor.start_link()
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, healthy_supervisor))

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {:ticket_detail_updated,
                    %State{
                      generation: 2,
                      health: :healthy,
                      detail: %Snapshot{title: "recovered"}
                    }},
                   2_000
  end

  test "times out cold demand, terminates its task, and ignores late completion" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        refresh_timeout_ms: 30_000,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "late")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    send(cache, {:refresh_timeout, ref, 1})

    assert_receive {:ticket_detail_updated, state}, 2_000
    assert %State{generation: 1, health: :unavailable, failure: %Failure{kind: :timeout}} = state
    refute Process.alive?(reader_pid)

    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}, 100

    assert {:ok, %State{health: :unavailable, failure: %Failure{kind: :timeout}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "keeps last-known-good detail stale when a refresh task times out" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        refresh_timeout_ms: 30_000,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    send(cache, {:refresh_timeout, ref, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000

    refute Process.alive?(reader_pid)
    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}, 100
  end

  test "keeps last-known-good detail when a timeout races a task-supervisor restart" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        task_supervisor: task_supervisor,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}},
      2_000
    )

    Agent.update(clock, fn _ -> 2 end)

    assert {:ok, %State{generation: 2, health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    {:ok, stale_supervisor} = Task.Supervisor.start_link()
    :ok = GenServer.stop(stale_supervisor)
    :sys.replace_state(cache, &Map.put(&1, :task_supervisor, stale_supervisor))
    send(cache, {:refresh_timeout, ref, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000

    assert Process.alive?(cache)
    reader_ref = Process.monitor(reader_pid)
    send(reader_pid, :finish)
    assert_receive {:DOWN, ^reader_ref, :process, ^reader_pid, _reason}, 2_000
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}, 100
  end

  defp start_cache(opts) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    TicketDetailCoordinator.start_link(
      Keyword.merge(
        [
          name: nil,
          task_supervisor: task_supervisor,
          configured_repo: @configured,
          configuration_subscriber: fn _pid -> :ok end,
          now: fn -> ~U[2026-07-14 09:00:00Z] end,
          clock_ms: fn -> 0 end
        ],
        opts
      )
    )
  end

  defp identity(number, node_id, repository \\ @configured) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => node_id, "number" => number},
        repository,
        repository
      )

    identity
  end

  defp snapshot(identity, title) do
    %Snapshot{
      identity: identity,
      title: title,
      description: nil,
      lifecycle: Lifecycle.from_github("open", nil),
      url: "https://github.com/owner/repo/issues/#{identity.identifier}",
      created_at: ~U[2026-07-01 10:00:00Z],
      updated_at: ~U[2026-07-02 11:00:00Z],
      observed_at: ~U[2026-07-14 09:00:00Z]
    }
  end

  defp inflight_ref(cache, identity) do
    %{entries: entries} = :sys.get_state(cache)

    %{inflight: %{ref: ref}} =
      Enum.find_value(entries, fn {_key, entry} -> if entry.identity == identity, do: entry end)

    ref
  end

  defp cache_barrier(cache), do: :sys.get_state(cache)
end
