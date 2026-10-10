defmodule Aiur.BuildOrder.TicketDetailCoordinatorRestartTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Lifecycle, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Snapshot, State}
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

  test "ignores a delayed completion from an older generation" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 10,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
          send(parent, {:reader_started, attempt, self()})

          receive do
            :finish -> {:ok, snapshot(identity, if(attempt == 1, do: "first", else: "second"))}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 1, first_reader}, 2_000
    first_ref = inflight_ref(cache, identity)
    send(first_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 1, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _ -> 11 end)
    assert {:ok, %State{generation: 2, health: :stale}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 2, second_reader}, 2_000

    send(cache, {first_ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}, 100

    send(second_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{generation: 2, detail: %Snapshot{title: "second"}}}, 2_000
  end

  test "restart loses in-memory detail until a new demand succeeds" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn identity -> {:ok, snapshot(identity, "first")} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000
    :ok = GenServer.stop(cache)

    {:ok, restarted} = start_cache(reader: fn _identity -> flunk("current must not fetch") end)

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(restarted, identity)
  end

  test "abnormal supervised restart tells existing subscribers to clear detail" do
    identity = identity(42, "I42")
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, epochs} = Agent.start_link(fn -> 0 end)

    cache_options = [
      name: nil,
      configured_repo: @configured,
      task_supervisor: task_supervisor,
      configuration_subscriber: fn _pid -> :ok end,
      reset_epoch: fn -> Agent.get_and_update(epochs, fn epoch -> {epoch + 1, epoch + 1} end) end,
      reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
    ]

    {:ok, supervisor} = Supervisor.start_link([{TicketDetailCoordinator, cache_options}], strategy: :one_for_one)
    cache = cache_child(supervisor)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000

    Process.exit(cache, :kill)

    assert_receive {:ticket_detail_coordinator_reset, 2}, 2_000
    restarted = cache_child(supervisor)
    refute restarted == cache

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(restarted, identity)
  end

  test "abnormal restart kills owned in-flight reads before replacement demand" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, epochs} = Agent.start_link(fn -> 0 end)

    cache_options = [
      name: nil,
      configured_repo: @configured,
      task_supervisor: task_supervisor,
      configuration_subscriber: fn _pid -> :ok end,
      reset_epoch: fn -> Agent.get_and_update(epochs, fn epoch -> {epoch + 1, epoch + 1} end) end,
      reader: fn _identity ->
        attempt = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)
        send(parent, {:reader_started, attempt, self()})

        receive do
          :finish -> {:ok, snapshot(identity, "generation-#{attempt}")}
        end
      end
    ]

    {:ok, supervisor} = Supervisor.start_link([{TicketDetailCoordinator, cache_options}], strategy: :one_for_one)
    cache = cache_child(supervisor)

    # Subscribe to the reset topic before the kill so the restart below is
    # observable as a signal (the replacement coordinator broadcasts its reset
    # epoch from `init`) rather than as a wall-clock guess.
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.reset_topic())

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, 1, old_reader}, 2_000
    old_reader_ref = Process.monitor(old_reader)

    Process.exit(cache, :kill)

    # Signal 1: the abnormal restart kills the owned in-flight read — the old
    # reader's monitor DOWN. This is the production guarantee under test.
    assert_receive {:DOWN, ^old_reader_ref, :process, ^old_reader, _reason}, 2_000

    # Signal 2: the replacement coordinator has started (its reset broadcast
    # comes from `init`). Reading the child from the supervisor before this
    # signal races the supervisor's restart and can hand back the dead pid —
    # CI run 32629780488 caught `refute restarted == cache` failing exactly
    # that way under load. Each bound above is only a lost-message safety net
    # so a genuine regression fails loudly; the synchronization itself is the
    # confirmed monitor/subscription signal, not the duration.
    assert_receive {:ticket_detail_coordinator_reset, 2}, 2_000

    restarted = cache_child(supervisor)
    refute restarted == cache
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(restarted, identity)
    assert_receive {:reader_started, 2, new_reader}, 2_000
    refute Process.alive?(old_reader)
    send(new_reader, :finish)
  end

  test "does not let direct startup options exceed cache hard bounds" do
    {:ok, cache} =
      start_cache(
        freshness_ms: 300_001,
        refresh_timeout_ms: 30_001,
        max_entries: 101,
        max_description_bytes: 16_385
      )

    assert %{
             freshness_ms: 30_000,
             refresh_timeout_ms: 30_000,
             max_entries: 32,
             max_description_bytes: 16_384
           } = :sys.get_state(cache)
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

  defp cache_child(supervisor) do
    [{TicketDetailCoordinator, cache, :worker, _modules}] = Supervisor.which_children(supervisor)
    cache
  end

  defp cache_barrier(cache), do: :sys.get_state(cache)
end
