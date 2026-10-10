defmodule Aiur.BuildOrder.TicketDetailCoordinatorEvictionTest do
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

  test "bounds retention by evicting completed least-recently-used entries" do
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, first)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^first}}, 2_000

    assert :ok = TicketDetailCoordinator.subscribe(cache, second)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, second)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, identity: ^second}}, 2_000
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.current(cache, first)
  end

  test "notifies every subscriber before evicting a completed entry" do
    parent = self()
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(max_entries: 1, reader: fn identity -> {:ok, snapshot(identity, identity.identifier)} end)

    first_subscriber = subscribe_and_forward(cache, first, parent)
    second_subscriber = subscribe_and_forward(cache, first, parent)

    assert_receive {:detail_subscribed, ^first_subscriber}, 2_000
    assert_receive {:detail_subscribed, ^second_subscriber}, 2_000
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)

    assert_receive {:detail_update, ^first_subscriber, {:ticket_detail_updated, first_update}}, 2_000
    assert %State{generation: 1, health: :healthy, identity: ^first} = first_update

    assert_receive {:detail_update, ^second_subscriber, {:ticket_detail_updated, second_update}}, 2_000
    assert %State{generation: 1, health: :healthy, identity: ^first} = second_update

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, second)

    assert_receive {
                     :detail_update,
                     ^first_subscriber,
                     {:ticket_detail_updated,
                      %State{
                        generation: 1,
                        health: :unavailable,
                        detail: nil,
                        identity: ^first,
                        failure: %Failure{kind: :evicted}
                      }}
                   },
                   2_000

    assert_receive {
                     :detail_update,
                     ^second_subscriber,
                     {:ticket_detail_updated,
                      %State{
                        generation: 1,
                        health: :unavailable,
                        detail: nil,
                        identity: ^first,
                        failure: %Failure{kind: :evicted}
                      }}
                   },
                   2_000

    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.current(cache, first)
  end

  test "does not evict an in-flight identity to exceed the configured capacity" do
    parent = self()
    first = identity(1, "I1")
    second = identity(2, "I2")

    {:ok, cache} =
      start_cache(
        max_entries: 1,
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(first, "first")}
          end
        end
      )

    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, first)
    assert_receive {:reader_started, reader_pid}, 2_000
    assert {:error, %Failure{kind: :capacity}} = TicketDetailCoordinator.request(cache, second)
    send(reader_pid, :finish)
  end

  test "cannot publish a snapshot from another ticket identity" do
    identity = identity(42, "I42")
    other_identity = identity(43, "I43")

    {:ok, cache} =
      start_cache(reader: fn _identity -> {:ok, snapshot(other_identity, "wrong ticket")} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       health: :unavailable,
                       detail: nil,
                       failure: %Failure{kind: :provider_identity_mismatch}
                     }
                   },
                   2_000
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

  defp subscribe_and_forward(cache, identity, parent) do
    spawn_link(fn ->
      :ok = TicketDetailCoordinator.subscribe(cache, identity)
      send(parent, {:detail_subscribed, self()})
      forward_detail_updates(parent)
    end)
  end

  defp forward_detail_updates(parent) do
    receive do
      {:ticket_detail_updated, %State{} = state} ->
        send(parent, {:detail_update, self(), {:ticket_detail_updated, state}})
        forward_detail_updates(parent)
    end
  end
end
