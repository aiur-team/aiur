defmodule Aiur.BuildQueue.MutationCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.BuildQueue.{Hints, Model, MutationCLI, Server}
  alias Aiur.Config.Schema
  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})

    def save(doc) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.save_result == :ok, do: {:ok, %{state | document: doc}}, else: {state.save_result, state}
      end)
    end

    def open_issue_labels(_), do: Agent.get(__MODULE__, &{:ok, &1.labels, 1_000})
    def blocked_by(_), do: {:ok, []}
    def ensure_labels(_), do: :ok

    def add_label(id, label) do
      case Agent.get(__MODULE__, & &1.marker_result) do
        :ok -> edit(id, &Enum.uniq(&1 ++ [label]))
        error -> error
      end
    end

    def remove_label(id, label), do: edit(id, &List.delete(&1, label))
    def update_issue_state(id, "todo", _opts), do: add_label(id, "agent:todo")
    defp edit(id, fun), do: Agent.update(__MODULE__, fn state -> %{state | labels: Map.update!(state.labels, id, &%{labels: fun.(&1.labels)})} end)
    def notify_demand(_), do: :ok
    def status(_), do: :unavailable
  end

  setup do
    boundary = start_supervised!({Agent, fn -> %{document: @empty, labels: Map.new(["1", "2", "3"], &{&1, %{labels: ["agent:queued"]}}), save_result: :ok, marker_result: :ok} end})
    Process.register(boundary, Boundary)
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> 1_000 end,
         sleep: fn _ -> :ok end,
         schedule: fn target, message, _ ->
           send(owner, {:scheduled, target, message})
           make_ref()
         end,
         exchange: :absent_mutation_exchange}
      )

    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    assert GenServer.call(pid, :status) == :running
    %{server: pid}
  end

  test "daemon refuses caller workspace before touching server" do
    assert {:error, :agent_workspace} = MutationCLI.execute(verb: :add, ids: ["1"], caller_agent_workspace: "/caller", server: :missing)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1"], caller_agent_workspace: "/caller", error_fun: &IO.puts/1) == 64 end)
    assert output =~ "blocked in agent workspace"
    assert document() == @empty
  end

  test "add prints owning queue and closed IDs while retaining partial successes", %{server: pid} do
    assert {:ok, [{"#1", :ok}]} = MutationCLI.execute(verb: :add, ids: ["1"], queue: "paseo", server: pid)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2", "9"], queue: "other", server: pid) == 1 end)
    assert output =~ "#1: already in queue paseo"
    assert output =~ "#2: ok"
    assert output =~ "#9: closed"
    assert Enum.map(document().items, & &1.issue_id) == ["1", "2"]
    assert document().intents |> Enum.map(&{&1.issue_id, &1.action}) |> Enum.uniq() == [{"1", :mark}, {"2", :mark}]
  end

  test "batch insertion order survives marker-write failure after membership is saved", %{server: pid} do
    Agent.update(Boundary, &%{&1 | marker_result: {:error, :transient}})
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :add, ids: ["1", "2"], at: 0, server: pid) == 1 end)
    assert output =~ "#1:"
    assert output =~ "#2:"
    assert output =~ "marker_write_failed"
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"1", 0}, {"2", 1}]
  end

  test "positions edges reorder and remove traverse real persisted commands", %{server: pid} do
    run(pid, :add, ids: ["1", "2"], after: "3")
    run(pid, :add, ids: ["3"], at: 1)
    assert Enum.map(document().items, &{&1.issue_id, &1.position}) == [{"1", 0}, {"3", 1}, {"2", 2}]
    assert Enum.map(document().edges, &{&1.prerequisite, &1.dependent}) == [{"3", "1"}, {"3", "2"}]
    run(pid, :reorder, ids: ["2"], to: 0)
    assert Enum.map(document().items, & &1.issue_id) == ["2", "1", "3"]
    run(pid, :remove, ids: ["1", "3"])
    assert [%Model.Item{issue_id: "2", position: 0}] = document().items
  end

  test "item and named queue holds persist and release clears overrides and external holds", %{server: pid} do
    run(pid, :add, ids: ["1", "2"])
    run(pid, :hold, ids: ["1"])
    assert Enum.find(document().items, &(&1.issue_id == "1")).hold == :operator
    run(pid, :hold, queue: "default")
    assert hd(document().queues).held
    run(pid, :release, queue: "default")
    refute hd(document().queues).held
    assert Enum.all?(document().items, &is_nil(&1.hold))
    Agent.update(Boundary, fn state -> %{state | document: %{state.document | items: Enum.map(state.document.items, &%{&1 | hold: :external, override: :manual_promotion})}} end)
    # Restart from the persisted competing-writer state, rather than changing the server's internals.
    stop_supervised!(Server)
    settings = %Schema{build_queue: %Schema.BuildQueue{}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    restarted =
      start_supervised!(
        {Server,
         name: nil,
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         settings: {:ok, settings},
         clock: fn -> 1_000 end,
         sleep: fn _ -> :ok end,
         schedule: fn _, _, _ -> make_ref() end,
         exchange: :absent_mutation_exchange}
      )

    run(restarted, :release, ids: ["1"])
    assert %{hold: nil, override: nil} = Enum.find(document().items, &(&1.issue_id == "1"))
    assert %{hold: :external, override: :manual_promotion} = Enum.find(document().items, &(&1.issue_id == "2"))
  end

  test "a persisted hold prevents real promotion and publishes the dispatch hold", %{server: pid} do
    run(pid, :add, ids: ["1"])
    run(pid, :hold, ids: ["1"])
    reconcile(pid)
    assert Hints.held?("1")
    refute "agent:todo" in labels("1")
    run(pid, :release, ids: ["1"])
    reconcile(pid)
    assert "agent:todo" in labels("1")
    refute Hints.held?("1")
  end

  test "failed hold persistence refuses without changing membership", %{server: pid} do
    run(pid, :add, ids: ["1"])
    before = document()
    Agent.update(Boundary, &%{&1 | save_result: {:error, :disk_full}})
    assert {:ok, [{"#1", {:error, :disk_full}}]} = MutationCLI.execute(verb: :hold, ids: ["1"], server: pid)
    assert document() == before
    assert GenServer.call(pid, :status) == :store_unavailable
    assert {:error, :store_unavailable} = MutationCLI.execute(verb: :release, queue: "default", server: pid)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :hold, queue: "default", server: pid, error_fun: &IO.puts/1) == 1 end)
    assert output =~ "store unavailable"
    refute output =~ "not found"
  end

  test "invalid direct RPC arguments cannot mutate", %{server: pid} do
    for opts <- [
          [verb: :add, ids: ["1", "1"]],
          [verb: :hold, ids: ["1"], queue: "default"],
          [verb: :reorder, ids: ["1"], to: -1],
          [verb: :add, ids: ["1"], build_order: 9],
          [verb: :add, ids: ["1"], after: "1"],
          [verb: :remove, ids: ["1"], at: 0]
        ] do
      assert {:error, :invalid_arguments} = MutationCLI.execute(Keyword.put(opts, :server, pid))
    end

    assert document() == @empty
  end

  defp reconcile(pid) do
    assert_received {:scheduled, ^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    GenServer.call(pid, :status)
  end

  defp labels(id), do: Agent.get(Boundary, & &1.labels[id].labels)
  defp run(pid, verb, opts), do: capture_io(fn -> assert Aiur.BuildQueueCLI.run(Keyword.merge(opts, verb: verb, server: pid)) == 0 end)
  defp document, do: Agent.get(Boundary, & &1.document)
end
