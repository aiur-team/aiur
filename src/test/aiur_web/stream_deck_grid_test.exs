defmodule AiurWeb.StreamDeckGridTest do
  use ExUnit.Case, async: true

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

  test "projects unavailable and timed-out snapshots as API errors" do
    assert StreamDeckGrid.payload(:missing_streamdeck_orchestrator, 1) == %{
             error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
           }

    server = :streamdeck_grid_timeout_server
    start_supervised!({__MODULE__.TimeoutServer, name: server})

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

  test "projects horizontal paging metadata for more than eight agents" do
    agents = Enum.map(1..9, &agent(to_string(&1)))
    payload = StreamDeckGrid.project(%{running: agents, retrying: [], idle: []})

    assert payload.total == 9
    assert payload.windows == 2
    assert payload.max_column_offset == 1
  end

  test "uses the dashboard's natural ticket ordering within a bucket" do
    payload = StreamDeckGrid.project(%{running: [agent("10"), agent("2")], retrying: [], idle: []})

    assert Enum.map(payload.agents, & &1.identifier) == ["2", "10"]
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

  defmodule TimeoutServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    def child_spec(opts), do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:noreply, state}
  end
end
