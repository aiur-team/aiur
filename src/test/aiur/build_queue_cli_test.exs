defmodule Aiur.BuildQueueCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{BuildQueue, BuildQueueCLI, Config.Schema}
  alias Aiur.BuildQueue.{Model, ReadModel, Server}

  defmodule Boundary do
    def open_issue_labels(_age), do: {:ok, %{"1" => %{labels: ["agent:queued"]}, "2" => %{labels: ["agent:queued"]}}, 1_000}
    def load, do: {:ok, Aiur.BuildQueueCLITest.document()}
    def status(_ids), do: :unavailable
    def save(_doc), do: :ok
  end

  test "public show returns schema v1 and CLI JSON preserves real server order and prerequisites" do
    owner = self()

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         build_order_projection: :absent_queue_cli_projection,
         settings: {:ok, settings()},
         clock: fn -> 2_000 end,
         exchange: :absent_queue_cli_exchange,
         schedule: fn pid, msg, _delay ->
           send(owner, {pid, msg})
           make_ref()
         end}
      )

    assert_received {^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    model = BuildQueue.show(pid)
    assert Map.keys(model) |> Enum.sort() == Enum.sort([:schema_version, :page, :instance, :snapshot, :status, :build_queue, :sources, :queues])
    assert model.build_queue == %{build_order_source: false}
    assert model.schema_version == 1
    assert model.page == "build-queue"
    assert [queue] = model.queues
    assert [first, second] = queue.items
    assert first.number == 1
    assert first.downstream_open == 1
    assert second.number == 2
    assert second.prerequisites == [%{number: 1, source: :list, verdict: :pending}]
    assert model.sources["tracker_observation"].age_ms == 1_000
    output = capture_io(fn -> assert BuildQueueCLI.run(server: pid, json: true, queue: "paseo") == 0 end)
    json = Jason.decode!(output)
    assert json["build_queue"] == %{"build_order_source" => false}
    assert hd(json["queues"])["name"] == "paseo"
    refute output =~ "title"
    refute output =~ "body"
  end

  test "stale build order source retains observation time and renders its age" do
    model = ReadModel.build(state())
    source = %{state: :ok, observed_at: ~U[2026-10-08 00:00:00Z], age_ms: 920_000, freshness: :stale, partial: false, reasons: [:delivery_staleness]}
    model = %{model | sources: Map.put(model.sources, "build_order:2573", source)}
    pid = read_server(model)
    output = capture_io(fn -> assert BuildQueueCLI.run(server: pid) == 0 end)
    assert output =~ "stale (15m ago)"
    assert output =~ "2026-10-08T00:00:00Z"
    json = capture_io(fn -> BuildQueueCLI.run(server: pid, json: true) end) |> Jason.decode!()
    assert json["sources"]["build_order:2573"]["freshness"] == "stale"
    assert json["sources"]["build_order:2573"]["age_ms"] == 920_000
    unknown = %{model | sources: Map.put(model.sources, "build_order:2573", %{source | freshness: :unknown})}
    output = capture_io(fn -> BuildQueueCLI.run(server: read_server(unknown, :unknown_age)) end)
    assert output =~ "unknown (15m ago)"
  end

  test "unreconciled items expose unknown progress and rank instead of invented zero" do
    model = ReadModel.build(state())
    assert [queue] = model.queues
    assert queue.progress.percent == nil
    assert queue.progress.completed == nil
    assert Enum.all?(queue.items, &(&1.state == :unknown and &1.downstream_open == nil and &1.rank == nil))
    output = capture_io(fn -> BuildQueueCLI.run(server: read_server(model)) end)
    assert output =~ "paseo  unknown"
    assert output =~ "tracker_observation  observed unknown  unknown"
    refute output =~ "0%"
    refute output =~ "0 downstream"
  end

  test "items follow planner start order, and a stale observation hides held projections" do
    observations = Map.new(["1", "2"], &{&1, %Model.Observation{issue_id: &1, open?: true, labels: ["agent:queued"], state_reason: nil, pr: nil, observed_at_ms: 1_500}})
    projections = [%{issue_id: "2", state: :waiting, verdict: :waiting, rank: {0, 3, 2, 0, "2"}}, %{issue_id: "1", state: :ready, verdict: :ready, rank: {-1, 3, 1, 0, "1"}}]
    current = %{state() | projections: projections, observations: observations}
    assert [%{number: 2, state: :waiting}, %{number: 1, state: :ready, downstream_open: 1}] = hd(ReadModel.build(current).queues).items
    stale = %{current | clock: fn -> 1_500 + 86_400_000 end}
    assert Enum.all?(hd(ReadModel.build(stale).queues).items, &(&1.state == :unknown and &1.rank == nil))
  end

  test "disabled still prints JSON status and exits one through control marker" do
    pid = start_supervised!({Server, name: nil, settings: {:ok, %{settings() | build_queue: %Schema.BuildQueue{enabled: false}}}})
    output = capture_io(fn -> assert BuildQueueCLI.run(server: pid, json: true) == 1 end)
    assert %{"status" => "disabled", "queues" => []} = Jason.decode!(output)
    output = capture_io(fn -> Aiur.AgentControlCLI.queue(server: pid, json: true) end)
    assert output =~ "\"status\":\"disabled\""
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "invalid and missing queue selections refuse without printing a success envelope" do
    pid = read_server(ReadModel.build(state()))

    for queue <- ["absent", "", 42] do
      output = capture_io(fn -> assert BuildQueueCLI.run(server: pid, queue: queue, error_fun: &IO.puts/1) == 1 end)
      assert output =~ "aiur: queue show"
      refute output =~ "build queue  running"
    end
  end

  @spec document() :: map()
  def document do
    queue = %Model.Queue{id: "q", name: "paseo", kind: :list, root: nil, held: true, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    items = for id <- ["1", "2"], do: %Model.Item{issue_id: id, queue_id: "q", position: String.to_integer(id), hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
    %{queues: [queue], items: items, edges: [%Model.Edge{prerequisite: "1", dependent: "2", source: :list}], intents: [], latches: []}
  end

  defp settings, do: %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}
  defp state, do: %{clock: fn -> 2_000 end, status: :running, document: document(), projections: [], observations: %{}, settings: settings()}

  defp read_server(model, id \\ Aiur.BuildQueueCLITest.ReadServer) do
    start_supervised!(Supervisor.child_spec({Aiur.BuildQueueCLITest.ReadServer, model: model}, id: id))
  end

  defmodule ReadServer do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :model)}
    @impl true
    def handle_call(:read_model, _from, model), do: {:reply, model, model}
  end
end
