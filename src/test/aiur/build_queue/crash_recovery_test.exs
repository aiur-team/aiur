defmodule Aiur.BuildQueue.CrashRecoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildQueue.{Hints, Model, Server, Store}
  alias Aiur.Config.Schema

  defmodule Boundary do
    # Claimed rows isolate store recovery from the write protocol.
    def open_issue_labels(_age), do: {:ok, Map.new(["1", "2", "3"], &{&1, %{labels: ["agent:queued", "agent:in-progress"], updated_at: nil}}), 1_000}
    def status(_ids), do: :unavailable
  end

  setup do
    root = Path.join(System.tmp_dir!(), "build-queue-crash-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "supervisor restart after an abrupt kill recovers durable queue state and hints" do
    :ok = Store.save(document())
    supervisor = start_supervised!(%{id: :crash_recovery_supervisor, type: :supervisor, start: {Supervisor, :start_link, [[child_spec()], [strategy: :one_for_one]]}})
    before_pid = Process.whereis(Server)
    {:ok, before} = GenServer.call(Server, :show)
    before_hints = hints()

    assert before.status == :running
    assert Enum.map(before.projections, & &1.issue_id) |> Enum.sort() == ["1", "2", "3"]
    assert before_hints == [{"1", {-1, 0}, false}, {"2", {0, 0}, true}, {"3", {0, 0}, false}]

    ref = Process.monitor(before_pid)
    Process.exit(before_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^before_pid, :killed}, 1_000
    after_pid = restarted(supervisor, before_pid)

    {:ok, recovered} = GenServer.call(Server, :show)
    assert after_pid != before_pid
    assert :ets.info(Hints.table_name(), :owner) == after_pid
    assert recovered.status == :running
    assert recovered.projections == before.projections
    assert recovered.actions == before.actions
    assert hints() == before_hints
    assert Store.load() == {:ok, document()}
  end

  defp child_spec do
    opts = [
      name: Server,
      settings: {:ok, %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}},
      tracker: Boundary,
      claim_probe: Boundary,
      clock: fn -> 1_000 end,
      exchange: :absent_crash_recovery_exchange,
      # Reconcile requests run at once, so a restarted server has reconciled before its first call.
      schedule: fn
        pid, {:reconcile, _} = message, _delay ->
          send(pid, message)
          make_ref()

        _pid, _message, _delay ->
          make_ref()
      end
    ]

    Supervisor.child_spec({Server, opts}, id: Server)
  end

  defp restarted(supervisor, old_pid) do
    case Supervisor.which_children(supervisor) do
      [{Server, pid, :worker, _}] when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        restarted(supervisor, old_pid)
    end
  end

  defp hints, do: Hints.table_name() |> :ets.tab2list() |> Enum.sort()

  defp document do
    created = ~U[2026-10-08 00:00:00Z]
    queue = %Model.Queue{id: "q-ab12", name: "Q", kind: :build_order, root: 1, held: false, generation: 0, created_at: created}

    items =
      for id <- ["1", "2", "3"],
          do: %Model.Item{issue_id: id, queue_id: "q-ab12", position: nil, hold: if(id == "2", do: :operator), override: nil, promoted_at: nil, added_at: created}

    %{queues: [queue], items: items, edges: [%Model.Edge{prerequisite: "1", dependent: "3", source: :native}], intents: [], latches: []}
  end
end
