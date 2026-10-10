defmodule Aiur.BuildOrder.TicketDetailCoordinatorRepositorySwitchTest do
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

  test "evicts an in-flight detail when the configured repository changes" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(identity, "stale repository")}
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
    assert @configured == inflight_repository(cache, identity)

    :sys.replace_state(cache, &Map.put(&1, :configured_repo, {"other", "repo"}))
    send(reader_pid, :finish)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       generation: 2,
                       health: :unavailable,
                       detail: nil,
                       identity: ^identity,
                       failure: %Failure{kind: :evicted}
                     }
                   },
                   2_000

    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "reconciles idle subscribed detail before subscription and cannot resurrect it after a switch-back" do
    identity = identity(42, "I42")
    switched_identity = identity(42, "I42", {"other", "repo"})
    {:ok, repository} = Agent.start_link(fn -> @configured end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn -> Agent.get(repository, & &1) end,
        reader: fn requested_identity ->
          attempt = Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end)
          {:ok, snapshot(requested_identity, if(attempt == 1, do: "first", else: "second"))}
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, switched_identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^identity, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert {:error, %Failure{kind: :nonfetchable_repository}} = TicketDetailCoordinator.current(cache, identity)

    assert {:ok, %State{identity: ^switched_identity, health: :unavailable}} =
             TicketDetailCoordinator.current(cache, switched_identity)

    assert %{entries: %{}} = :sys.get_state(cache)

    Agent.update(repository, fn _repository -> @configured end)

    assert {:ok, %State{identity: ^identity, health: :unavailable, detail: nil}} =
             TicketDetailCoordinator.current(cache, identity)

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "second"}}}, 2_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "reconciles an in-flight repository switch before capacity admission" do
    parent = self()
    first = identity(42, "I42")
    second = identity(43, "I43", {"other", "repo"})
    {:ok, repository} = Agent.start_link(fn -> @configured end)

    {:ok, cache} =
      start_cache(
        max_entries: 1,
        configured_repo: fn -> Agent.get(repository, & &1) end,
        reader: fn requested_identity ->
          send(parent, {:reader_started, requested_identity, self()})

          receive do
            :finish -> {:ok, snapshot(requested_identity, requested_identity.identifier)}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, first)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:reader_started, ^first, _first_reader}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, second)
    assert {:ok, %State{identity: ^second, health: :unavailable}} = TicketDetailCoordinator.request(cache, second)

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^first, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert_receive {:reader_started, ^second, second_reader}, 2_000
    send(second_reader, :finish)
    assert_receive {:ticket_detail_updated, %State{identity: ^second, health: :healthy}}, 2_000
    assert %{entries: entries} = :sys.get_state(cache)
    assert map_size(entries) == 1
  end

  test "evicts idle subscribed detail when a validated configuration generation changes" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, repository} = Agent.start_link(fn -> @configured end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn -> Agent.get(repository, & &1) end,
        configuration_subscriber: fn pid -> send(parent, {:configuration_subscribed, pid}) end,
        reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
      )

    assert_receive {:configuration_subscribed, ^cache}, 2_000
    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^identity}}, 2_000

    Agent.update(repository, fn _repository -> {"other", "repo"} end)
    send(cache, {:workflow_config_updated, 2})

    assert_receive {
                     :ticket_detail_updated,
                     %State{identity: ^identity, health: :unavailable, detail: nil, failure: %Failure{kind: :evicted}}
                   },
                   2_000

    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "configuration reader failure is typed and preserves last-known-good detail" do
    identity = identity(42, "I42")
    {:ok, mode} = Agent.start_link(fn -> :healthy end)

    {:ok, cache} =
      start_cache(
        configured_repo: fn ->
          case Agent.get(mode, & &1) do
            :healthy -> @configured
            :failed -> raise "configured repository unavailable"
          end
        end,
        reader: fn requested_identity -> {:ok, snapshot(requested_identity, "first")} end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(mode, fn _mode -> :failed end)

    assert {:error, %Failure{kind: :configuration}} = TicketDetailCoordinator.current(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :stale, detail: %Snapshot{title: "first"}, failure: %Failure{kind: :configuration}}
                   },
                   2_000

    assert Process.alive?(cache)

    Agent.update(mode, fn _mode -> :healthy end)

    assert {:ok, %State{health: :healthy, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "configuration failure cancels an in-flight refresh without losing last-known-good detail" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, mode} = Agent.start_link(fn -> :healthy end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 1,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        configured_repo: fn ->
          case Agent.get(mode, & &1) do
            :healthy -> @configured
            :failed -> raise "configured repository unavailable"
          end
        end,
        reader: fn requested_identity ->
          case Agent.get_and_update(attempts, fn attempt -> {attempt + 1, attempt + 1} end) do
            1 ->
              {:ok, snapshot(requested_identity, "first")}

            2 ->
              send(parent, {:reader_started, self()})

              receive do
                :finish -> {:ok, snapshot(requested_identity, "late")}
              end
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _clock -> 2 end)

    assert {:ok, %State{health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)
    Agent.update(mode, fn _mode -> :failed end)

    assert {:error, %Failure{kind: :configuration}} = TicketDetailCoordinator.current(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :stale, detail: %Snapshot{title: "first"}, failure: %Failure{kind: :configuration}}
                   },
                   2_000

    refute Process.alive?(reader_pid)
    send(cache, {ref, {:ok, snapshot(identity, "late")}})
    cache_barrier(cache)
    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "late"}}}, 100
  end

  test "fences an in-flight completion with one atomic configuration snapshot" do
    parent = self()
    identity = identity(42, "I42")
    {:ok, configuration} = Agent.start_link(fn -> {@configured, 1} end)

    {:ok, cache} =
      start_cache(
        configuration_snapshot: fn -> Agent.get(configuration, & &1) end,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "stale-generation")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000
    ref = inflight_ref(cache, identity)

    Agent.update(configuration, fn _snapshot -> {@configured, 2} end)
    send(cache, {ref, {:ok, snapshot(identity, "stale-generation")}})
    cache_barrier(cache)

    refute_receive {:ticket_detail_updated, %State{detail: %Snapshot{title: "stale-generation"}}}, 100
    refute Process.alive?(reader_pid)

    assert {:ok, %State{health: :unavailable, detail: nil, generation: :unknown}} =
             TicketDetailCoordinator.current(cache, identity)
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

  defp inflight_repository(cache, identity) do
    %{entries: entries} = :sys.get_state(cache)

    %{inflight: %{repository: repository}} =
      Enum.find_value(entries, fn {_key, entry} -> if entry.identity == identity, do: entry end)

    repository
  end

  defp cache_barrier(cache), do: :sys.get_state(cache)
end
