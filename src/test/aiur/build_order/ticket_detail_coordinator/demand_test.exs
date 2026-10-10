defmodule Aiur.BuildOrder.TicketDetailCoordinatorDemandTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Lifecycle, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.GitHub.RequestOrigin
  alias Aiur.GitHub.ResourceStore

  @configured {"owner", "repo"}
  @workflow_configuration_topic "workflow_store:configuration"

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

  test "coalesces concurrent cold demand and publishes one complete generation" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "first")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000

    for _ <- 1..3 do
      assert {:ok, %State{health: :unavailable, generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    end

    refute_receive {:reader_started, _reader_pid}, 100
    send(reader_pid, :finish)

    assert_receive(
      {:ticket_detail_updated, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}},
      2_000
    )

    assert {:ok, %State{health: :healthy, generation: 1, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.current(cache, identity)
  end

  test "propagates a LiveView request origin into the refresh task" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:view_originated, RequestOrigin.view_originated?()})
          {:ok, snapshot(identity, "detail")}
        end
      )

    RequestOrigin.carry(true, fn ->
      assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    end)

    assert_receive {:view_originated, true}, 2_000
  end

  test "keeps a background request origin out of the refresh task" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:view_originated, RequestOrigin.view_originated?()})
          {:ok, snapshot(identity, "detail")}
        end
      )

    assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:view_originated, false}, 2_000
  end

  test "constant repository fixture does not subscribe to workflow configuration" do
    parent = self()
    identity = identity(42, "I42")

    {:ok, cache} =
      start_cache(
        reader: fn _identity ->
          send(parent, {:reader_started, self()})

          receive do
            :finish -> {:ok, snapshot(identity, "first")}
          end
        end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:reader_started, reader_pid}, 2_000

    refute Enum.any?(
             Registry.lookup(Aiur.PubSub, @workflow_configuration_topic),
             fn {subscriber, _metadata} -> subscriber == cache end
           )

    send(reader_pid, :finish)

    assert_receive {
                     :ticket_detail_updated,
                     %State{generation: 1, health: :healthy, detail: %Snapshot{title: "first"}}
                   },
                   2_000
  end

  test "rejects another repository before cache admission or reader invocation" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    {:ok, cache} =
      start_cache(reader: fn _identity -> flunk("reader must not be invoked") end)

    assert {:error, %Failure{kind: :nonfetchable_repository}} = TicketDetailCoordinator.request(cache, foreign)
    assert %{entries: %{}} = :sys.get_state(cache)
  end

  test "keeps last-known-good detail stale when a refresh fails" do
    identity = identity(42, "I42")
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, results} = Agent.start_link(fn -> [{:ok, snapshot(identity, "first")}, {:error, %Failure{kind: :timeout}}] end)

    {:ok, cache} =
      start_cache(
        freshness_ms: 10,
        clock_ms: fn -> Agent.get(clock, & &1) end,
        reader: fn _identity -> Agent.get_and_update(results, fn [result | rest] -> {result, rest} end) end
      )

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)
    assert_receive {:ticket_detail_updated, %State{health: :healthy, detail: %Snapshot{title: "first"}}}, 2_000

    Agent.update(clock, fn _ -> 11 end)

    assert {:ok, %State{health: :stale, detail: %Snapshot{title: "first"}}} =
             TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{
                       health: :stale,
                       detail: %Snapshot{title: "first"},
                       failure: %Failure{kind: :timeout}
                     }
                   },
                   2_000
  end

  test "reports a cold failure as unavailable rather than fabricating detail" do
    identity = identity(42, "I42")
    {:ok, cache} = start_cache(reader: fn _identity -> {:error, %Failure{kind: :not_found}} end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{health: :unavailable, detail: nil}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive {
                     :ticket_detail_updated,
                     %State{health: :unavailable, detail: nil, failure: %Failure{kind: :not_found}}
                   },
                   2_000
  end

  test "recovers from a cold failure only after a later successful demand" do
    identity = identity(42, "I42")
    {:ok, results} = Agent.start_link(fn -> [{:error, %Failure{kind: :timeout}}, {:ok, snapshot(identity, "recovered")}] end)

    {:ok, cache} =
      start_cache(reader: fn _identity -> Agent.get_and_update(results, fn [result | rest] -> {result, rest} end) end)

    assert :ok = TicketDetailCoordinator.subscribe(cache, identity)
    assert {:ok, %State{generation: 1, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 1, health: :unavailable, detail: nil}},
      2_000
    )

    assert {:ok, %State{generation: 2, health: :unavailable}} = TicketDetailCoordinator.request(cache, identity)

    assert_receive(
      {:ticket_detail_updated, %State{generation: 2, health: :healthy, detail: %Snapshot{title: "recovered"}}},
      2_000
    )
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
end
