defmodule AiurWeb.StreamDeckGridTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.StreamDeckGrid

  test "projects an empty fleet" do
    assert StreamDeckGrid.project(%{running: [], retrying: [], idle: []}) == %{
             agents: [],
             total: 0,
             columns_per_page: 4,
             rows_per_column: 2,
             agents_per_page: 8,
             windows: 0,
             max_column_offset: 0
           }
  end

  test "tolerates an incomplete snapshot" do
    assert StreamDeckGrid.project(%{}).agents == []
  end

  test "projects unavailable snapshots as API errors" do
    assert StreamDeckGrid.payload(:missing_streamdeck_orchestrator, 1) == %{
             error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
           }
  end

  test "projects a completed snapshot from the read model" do
    server = start_supervised!({__MODULE__.TimeoutServer, []})

    :ok = SnapshotStore.publish(server, %{running: [], retrying: [], idle: []})

    assert %{agents: [], snapshot_freshness: %{status: :current}} = StreamDeckGrid.payload(server, 1)
  end

  test "returns a hard error before the first snapshot" do
    server = start_supervised!({__MODULE__.TimeoutServer, []})

    assert StreamDeckGrid.payload(server, 0) == %{
             error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
           }
  end

  test "projects fewer than eight agents with the column-major contract metadata" do
    payload = StreamDeckGrid.project(%{running: [agent("1"), agent("2")], retrying: [], idle: [agent("3")]})

    assert payload.total == 3
    assert payload.windows == 1
    assert payload.max_column_offset == 0
    assert Enum.map(payload.agents, & &1.identifier) == ["1", "2", "3"]
  end

  test "projects the design paging metadata for twenty filtered agents" do
    agents = Enum.map(1..20, &agent(to_string(&1)))
    payload = StreamDeckGrid.project(%{running: agents, retrying: [], idle: []})

    assert payload.total == 20
    assert payload.windows == 3
    assert payload.max_column_offset == 6
  end

  test "preserves the raw fleet order within equal ranks" do
    payload = StreamDeckGrid.project(%{running: [agent("10"), agent("2")], retrying: [], idle: []})

    assert Enum.map(payload.agents, & &1.identifier) == ["10", "2"]
  end

  test "sorts one agent per bucket and places dependency-ready queued work first" do
    payload =
      StreamDeckGrid.project(%{
        running: [agent("running"), agent("paused", work_state: :paused), agent("alert", open_decision_count: 1), agent("stuck", work_state: :error)],
        retrying: [],
        idle: [agent("queued-blocked", waiting_reason: :waiting_for_dependency), agent("queued-ready")]
      })

    assert Enum.map(payload.agents, & &1.identifier) == [
             "alert",
             "stuck",
             "running",
             "paused",
             "queued-ready",
             "queued-blocked"
           ]

    assert Enum.map(Enum.take(payload.agents, 4), & &1.bucket) == [
             :alert,
             :stuck,
             :running,
             :paused
           ]

    assert Enum.map(Enum.drop(payload.agents, 4), &{&1.identifier, &1.dependency_ready}) == [
             {"queued-ready", true},
             {"queued-blocked", false}
           ]
  end

  test "puts a stuck agent from the raw fleet tail on the first page" do
    payload =
      StreamDeckGrid.project(%{
        running: Enum.map(1..8, &agent("running-#{&1}")) ++ [agent("stuck-tail", work_state: :error)],
        retrying: [],
        idle: []
      })

    assert payload.agents |> Enum.take(8) |> Enum.map(& &1.identifier) |> List.first() == "stuck-tail"
  end

  test "uses the injected readiness predicate to rank queued agents" do
    payload =
      StreamDeckGrid.project(
        %{running: [], retrying: [], idle: [agent("blocked"), agent("ready")]},
        fn entry -> entry.identifier == "ready" end
      )

    assert Enum.map(payload.agents, &{&1.identifier, &1.dependency_ready}) == [
             {"ready", true},
             {"blocked", false}
           ]
  end

  property "renders agents in non-decreasing Stream Deck rank for any fleet" do
    check all(bucket_sequence <- list_of(member_of([:alert, :stuck, :running, :paused, :queued]), max_length: 40), max_runs: 30) do
      snapshot = snapshot_for(bucket_sequence)

      ranks =
        snapshot
        |> StreamDeckGrid.project()
        |> Map.fetch!(:agents)
        |> Enum.map(&bucket_rank(&1.bucket))

      assert ranks == Enum.sort(ranks)
    end
  end

  test "keeps an unchanged fleet in exactly the same order across refreshes" do
    snapshot = %{
      running: [agent("running-2"), agent("running-1"), agent("stuck", work_state: :error)],
      retrying: [],
      idle: [agent("queued-2"), agent("queued-1")]
    }

    assert StreamDeckGrid.project(snapshot).agents == StreamDeckGrid.project(snapshot).agents
  end

  test "includes the Stream Deck agent fields" do
    [agent] = StreamDeckGrid.project(%{running: [agent("123", backend: "claude", progress_percent: 60, priority: 1)], retrying: [], idle: []}).agents

    assert agent == %{
             identifier: "123",
             title: "Ticket 123",
             vendor: "claude",
             bucket: :running,
             progress_percent: 60,
             priority: true
           }
  end

  test "normalizes vendor and invalid activity values" do
    [agent] =
      StreamDeckGrid.project(%{
        running: [agent("123", agent_family: "claude", backend: "codex", progress_percent: 101, priority: "high")],
        retrying: [],
        idle: []
      }).agents

    assert agent.vendor == "claude"
    assert agent.progress_percent == 0
    refute agent.priority
  end

  test "projects a registry provider family without coercing it to codex" do
    [agent] =
      StreamDeckGrid.project(%{running: [agent("1439", backend: "fake")], retrying: [], idle: []}).agents

    assert agent.vendor == "fake"
  end

  test "only flags positive priority ranks" do
    [unprioritized, prioritized] = StreamDeckGrid.project(%{running: [agent("1", priority: 0), agent("2", priority: 1)], retrying: [], idle: []}).agents

    refute unprioritized.priority
    assert prioritized.priority
  end

  defp agent(identifier, attrs \\ []) do
    Map.merge(
      %{
        identifier: identifier,
        title: "Ticket #{identifier}",
        backend: "codex",
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        priority: nil
      },
      Map.new(attrs)
    )
  end

  defp snapshot_for(bucket_sequence) do
    bucket_sequence
    |> Enum.with_index()
    |> Enum.reduce(%{running: [], retrying: [], idle: []}, fn {bucket, index}, snapshot ->
      entry = agent("agent-#{index}")

      case bucket do
        :alert -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :open_decision_count, 1)]))
        :stuck -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :work_state, :error)]))
        :running -> Map.update!(snapshot, :running, &(&1 ++ [entry]))
        :paused -> Map.update!(snapshot, :running, &(&1 ++ [Map.put(entry, :work_state, :paused)]))
        :queued -> Map.update!(snapshot, :idle, &(&1 ++ [entry]))
      end
    end)
  end

  defp bucket_rank(:alert), do: 0
  defp bucket_rank(:stuck), do: 1
  defp bucket_rank(:running), do: 2
  defp bucket_rank(:paused), do: 3
  defp bucket_rank(:queued), do: 4

  defmodule TimeoutServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

    def child_spec(opts), do: %{id: {__MODULE__, Keyword.get(opts, :name, self())}, start: {__MODULE__, :start_link, [opts]}}

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:noreply, state}
  end
end
