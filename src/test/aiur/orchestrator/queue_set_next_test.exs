defmodule Aiur.Orchestrator.QueueSetNextTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Hints, Model, Planner, ReadModel, Reconcile}
  alias Aiur.{BuildQueueCLI, Issue}
  alias Aiur.Orchestrator.{BuildQueueClaimProbe, Dispatcher, QueueSetSlots, State, TrackerTasks}

  defmodule Probe do
    use GenServer
    def start_link(data), do: GenServer.start_link(__MODULE__, data, name: __MODULE__)
    def next_set, do: BuildQueueClaimProbe.next_set(__MODULE__)
    @impl true
    def init(data), do: {:ok, data}
    @impl true
    def handle_call(:read_model, _from, data), do: {:reply, data.model, data}

    def handle_call(:build_queue_next_set, from, data) do
      {:reply, next_set, runtime} = Aiur.Orchestrator.handle_call(:build_queue_next_set, from, data.runtime)
      {:reply, next_set, %{data | runtime: runtime}}
    end
  end

  setup do
    :ets.new(Hints.table_name(), [:named_table, :set])
    :ok
  end

  for limit <- [nil, 1] do
    test "an active set with ready work gets NEXT and the spare slot with max_active_sets #{inspect(limit)}" do
      configure(unquote(limit))
      {model, runtime, issues} = fixture()
      assert hd(model.queues).counts == %{ready: 1, started: 1, done: 0}
      pid = start_supervised!({Probe, %{model: model, runtime: runtime}})
      output = capture_io(fn -> assert BuildQueueCLI.run(server: pid, claim_probe: Probe) == 0 end)
      assert output =~ "NEXT  A  rank 0"
      refute output =~ "NEXT  B"
      json = capture_io(fn -> BuildQueueCLI.run(server: pid, claim_probe: Probe, json: true) end) |> Jason.decode!()
      assert [a, b] = json["queues"]
      assert {a["state"], a["next"]} == {"active", true}
      assert {b["state"], b["next"]} == {"waiting", false}
      if unquote(limit), do: assert(b["waiting_reason"] =~ "max_active_sets 1")
      parent = self()

      pending =
        Dispatcher.choose_issues(runtime, issues,
          issue_fetcher: fn [id] -> {:ok, [Enum.find(issues, &(&1.id == id))]} end,
          blocked_by_hydrator: fn issue -> {:ok, issue} end,
          runner: fn issue, _, _ ->
            send(parent, {:started, issue.id})
            :ok
          end
        )

      final = drain(pending)
      assert Enum.sort(Map.keys(final.running)) == ["1", "2"]
      assert_received {:started, "2"}
      refute_received {:started, "3"}
    end
  end

  test "selection uses ordinary dispatch ordering when set order is none" do
    configure(nil, "none")
    {model, runtime, _issues} = fixture()
    pid = start_supervised!({Probe, %{model: model, runtime: runtime}})
    output = capture_io(fn -> BuildQueueCLI.run(server: pid, claim_probe: Probe) end)
    assert output =~ "NEXT  B  rank 1"
  end

  test "no capacity or unavailable admission cannot invent a next set" do
    configure(nil)
    {model, runtime, _issues} = fixture()
    runtime = %{runtime | effective_concurrent_agents: 1, max_concurrent_agents: 1}
    pid = start_supervised!({Probe, %{model: model, runtime: runtime}})

    for probe <- [Probe, :absent_next_set_probe] do
      json = capture_io(fn -> BuildQueueCLI.run(server: pid, claim_probe: probe, json: true) end) |> Jason.decode!()
      expected = if probe == Probe, do: false
      assert Enum.all?(json["queues"], &(&1["next"] == expected))
      refute capture_io(fn -> BuildQueueCLI.run(server: pid, claim_probe: probe) end) =~ "NEXT"
    end
  end

  defp configure(limit, order \\ "ranked") do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent", max_concurrent_agents: 2)
    File.write!(Workflow.workflow_file_path(), File.read!(Workflow.workflow_file_path()) <> "\nbuild_queue:\n  set_order: #{order}\n  max_active_sets: #{limit || "null"}\n")
    Aiur.WorkflowStore.force_reload()
  end

  defp fixture do
    now = System.system_time(:millisecond)
    time = DateTime.from_unix!(now, :millisecond)
    queues = for {name, rank} <- [{"A", 0}, {"B", 1}], do: %Model.Queue{id: name, name: name, rank: rank, kind: :list, root: nil, held: false, generation: 0, created_at: time}

    items =
      for id <- ["1", "2", "3"],
          do: %Model.Item{issue_id: id, queue_id: if(id == "3", do: "B", else: "A"), position: String.to_integer(id), promoted_at: time, added_at: time, hold: nil, override: nil}

    document = %{queues: queues, items: items, edges: [], intents: [], latches: []}

    observations =
      Map.new(items, fn item ->
        {item.issue_id,
         %Model.Observation{
           issue_id: item.issue_id,
           open?: true,
           labels: ["agent:queued", if(item.issue_id == "1", do: "agent:in-progress", else: "agent:todo")],
           state_reason: nil,
           pr: nil,
           observed_at_ms: now
         }}
      end)

    issues = for id <- ["2", "3"], do: %Issue{id: id, identifier: "repo##{id}", title: "ticket", state: "todo", priority: if(id == "2", do: 4, else: 1), blocked_by: []}

    runtime = %State{
      snapshot_key: self(),
      max_concurrent_agents: 2,
      effective_concurrent_agents: 2,
      running: %{"1" => %{identifier: "repo#1", worker_host: nil}},
      claimed: MapSet.new(["1"]),
      last_polled_issues: Map.new(issues, &{&1.id, &1})
    }

    input = struct!(Planner.Input, Map.to_list(document) ++ [now_ms: now, observations: observations, opts: [label_prefix: "agent", observation_max_age_ms: 60_000]])
    {projections, _} = Planner.plan(input)
    Reconcile.write_hints(projections, MapSet.new(), document)
    claims = Map.new(items, &{&1.issue_id, BuildQueueClaimProbe.classify(runtime, &1.issue_id)})
    # Probe current admission as dispatch would, then let the real planner carry its decline reason.
    claims = Map.new(claims, fn {id, claim} -> {id, if(reason = QueueSetSlots.reason(id, runtime), do: {:declined, {:queue_set_order, reason}}, else: claim)} end)
    {projections, _} = Planner.plan(%{input | claims: claims})
    model = ReadModel.build(%{status: :running, clock: fn -> now end, document: document, settings: Config.settings!(), projections: projections, observations: observations})
    {model, runtime, issues}
  end

  defp drain(state) do
    case Map.keys(state.tracker_tasks) do
      [] ->
        state

      [ref] ->
        receive_barrier({^ref, result})
        {:handled, next} = TrackerTasks.result(state, ref, result)
        drain(next)
    end
  end
end
