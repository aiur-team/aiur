defmodule Aiur.BuildQueue.SetWaitingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Model, Planner, ReadModel}
  alias Aiur.{BuildQueueCLI, Config.Schema}

  defmodule Reader do
    use GenServer
    def start_link(model), do: GenServer.start_link(__MODULE__, model)
    @impl true
    def init(model), do: {:ok, model}
    @impl true
    def handle_call(:read_model, _from, model), do: {:reply, model, model}
  end

  test "a set admission decline reaches the planner, read model and queue show waiting column" do
    now = System.system_time(:millisecond)
    time = DateTime.from_unix!(now, :millisecond)
    reason = "queue_set_order: set 2 waits for set 1 (max_active_sets 1)"

    queue = %Model.Queue{
      id: "q-0001",
      name: "B",
      rank: 1,
      kind: :list,
      root: nil,
      held: false,
      generation: 0,
      created_at: time
    }

    item = %Model.Item{
      issue_id: "3",
      queue_id: queue.id,
      position: 0,
      hold: nil,
      override: nil,
      promoted_at: time,
      added_at: time
    }

    observation = %Model.Observation{
      issue_id: "3",
      open?: true,
      labels: ~w(agent:queued agent:todo),
      state_reason: nil,
      pr: nil,
      observed_at_ms: now
    }

    document = %{queues: [queue], items: [item], edges: [], intents: [], latches: []}

    input =
      struct!(
        Planner.Input,
        Map.to_list(document) ++
          [
            now_ms: now,
            observations: %{"3" => observation},
            claims: %{"3" => {:declined, {:queue_set_order, reason}}},
            opts: [label_prefix: "agent", observation_max_age_ms: 1_000]
          ]
      )

    {[projection], actions} = Planner.plan(input)
    assert projection.state == :promoted
    assert projection.reason == reason
    assert actions == []
    assert {:ok, settings} = Schema.parse(%{})

    model =
      ReadModel.build(%{
        status: :running,
        clock: fn -> now end,
        document: document,
        settings: settings,
        projections: [projection],
        observations: input.observations
      })

    assert hd(hd(model.queues).items).reason == reason
    assert hd(model.queues).set_rank == 1
    assert hd(model.queues).state == :waiting
    assert hd(model.queues).waiting_reason == reason
    assert hd(model.queues).counts == %{ready: 1, startable: 1, started: 0, done: 0}
    pid = start_supervised!({Reader, model})
    output = capture_io(fn -> assert BuildQueueCLI.run(server: pid) == 0 end)
    assert output =~ "#3  promoted  #{reason}"
    json = capture_io(fn -> BuildQueueCLI.run(server: pid, json: true) end) |> Jason.decode!()
    assert hd(hd(json["queues"])["items"])["reason"] == reason
  end
end
