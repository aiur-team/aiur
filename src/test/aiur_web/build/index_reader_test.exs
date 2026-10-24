defmodule AiurWeb.Build.IndexReaderTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Freshness
  alias AiurWeb.Build.IndexReader

  defmodule SlowOpenServer do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_cast(:block, parent) do
      send(parent, :open_read_blocked)
      Process.sleep(300)
      {:noreply, parent}
    end

    def handle_call(:snapshot, _from, parent), do: {:reply, %Aiur.OpenTicketSource.Snapshot{}, parent}
  end

  defmodule UnpublishedFleetServer do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:fleet_view, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "first cold index read projects an adopted running agent from the orchestrator snapshot" do
    {:ok, identity} =
      Aiur.TrackerIdentity.from_github(%{"node_id" => "I_kwDOExample12", "number" => 12}, {"aiur-team", "aiur"}, {"aiur-team", "aiur"})

    snapshot = %{
      statuses: [
        %{identifier: "12", tracker_identity: identity, work_state: :working, state: :running, open_decision_count: 2, waiting_reason: :waiting_for_human, runtime_seconds: 600},
        %{identifier: "13", tracker_identity: %{identity | identifier: "13", provider_id: "I_kwDOExample13"}, work_state: :working, state: :idle}
      ],
      running: [
        %{
          identifier: "12",
          started_at: DateTime.utc_now(),
          agent_family: :claude,
          resolved_model: "claude-opus-5-1",
          effort: :high,
          progress_percent: 64,
          progress_freshness: :fresh
        }
      ]
    }

    server = start_supervised!({UnpublishedFleetServer, snapshot})

    read =
      IndexReader.read(:all, parts(),
        repository_fun: fn -> {:ok, {"aiur-team", "aiur"}} end,
        units_fun: fn -> %{status: :empty, snapshot: %{rows: []}} end,
        orchestrator: server,
        running_rows_fun: &Freshness.read_running_rows/1
      )

    assert Map.has_key?(read.now.rows, "12")
    refute Map.has_key?(read.now.rows, "13")
    assert {:ok, index} = assemble(read)
    assert index.sources.agents.state == "ok"
    assert index.all["12"].sec == "now"
    assert index.all["12"].agent.state == "paused-decision"
    assert index.all["12"].start != nil
    assert index.all["12"].agent.model == "claude"
    assert index.all["12"].agent.name == "Claude"
    assert index.all["12"].agent.effort == "high"
    assert index.all["12"].pct == 64
  end

  test "unavailable running snapshot is a typed unavailable source" do
    read = IndexReader.read(:all, parts(), running_rows_fun: fn _opts -> {:error, :unavailable} end)

    assert read.now == {:error, :running_snapshot_unavailable}
    assert {:ok, index} = assemble(read)
    assert index.sources.agents.state == "unavailable"
    assert index.sources.agents.reason == "read_failed"
  end

  test "timed out running snapshot remains a typed read error" do
    read = IndexReader.read(:all, parts(), running_rows_fun: fn _opts -> {:error, :timeout} end)

    assert read.now == {:error, :running_snapshot_timeout}
    assert {:ok, index} = assemble(read)
    assert index.sources.agents.state == "unavailable"
  end

  test "cached open and queue facts keep every open id with no duplicate history read" do
    p = parts() |> put_in([:open, Access.key(:tickets)], [open(50, ["agent:todo"]), open(51, ["agent:human-review"]), open(53)])
    read = IndexReader.read(MapSet.new(~w(planned not_queued)a), p, [])
    assert {:ok, index} = assemble(read)
    assert Enum.sort(Map.keys(index.all)) == ~w(50 51 53)
    assert index.all["50"].sec == "plan"
    assert index.all["51"].sec == "nq" and index.all["53"].sec == "nq"
  end

  test "an open snapshot timeout keeps other timeline rows and names the degraded source" do
    server = start_supervised!({SlowOpenServer, self()})
    GenServer.cast(server, :block)
    assert_receive :open_read_blocked, 1_000

    previous = parts([row(40)]) |> put_in([:now, :rows], %{"41" => now_row(41)})

    read =
      IndexReader.read(MapSet.new(~w(open planned not_queued)a), previous,
        open_server: server,
        open_timeout: 5
      )

    assert read.open == {:error, :timeout}
    assert {:ok, index} = assemble(read)
    assert Map.has_key?(index.all, "40")
    assert Map.has_key?(index.all, "41")
    assert index.sources.open_tickets.reason == "open_tickets_timeout"
  end
end
