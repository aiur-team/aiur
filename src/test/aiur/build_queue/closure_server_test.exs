defmodule Aiur.BuildQueue.ClosureServerTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{Model, Server}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, &{:ok, &1.labels, &1.now})

    def issue_closure(id, _age) do
      Agent.get_and_update(__MODULE__, fn state -> {{:ok, %{open?: false, state_reason: state.reason}}, %{state | reads: state.reads ++ [id]}} end)
    end

    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})
    def save(document), do: Agent.update(__MODULE__, &%{&1 | document: document})
    def status(_ids), do: :unavailable
  end

  test "server retains terminal cache and plans duplicate attention after reopen" do
    now = ~U[2026-10-08 00:00:00Z]
    queue = %Model.Queue{id: "q-1234", name: "Q", kind: :list, root: nil, held: true, generation: 0, created_at: now}
    item = %Model.Item{issue_id: "2", queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: nil, added_at: now}
    edge = %Model.Edge{prerequisite: "1", dependent: "2", source: :native}
    document = %{queues: [queue], items: [item], edges: [edge], intents: [], latches: []}
    labels = %{"2" => %{labels: ["agent:queued"], updated_at: nil}}
    boundary = start_supervised!({Agent, fn -> %{labels: labels, now: 1_000, reason: "completed", document: document, reads: []} end})
    Process.register(boundary, Boundary)
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         settings: {:ok, settings},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> Agent.get(Boundary, & &1.now) end,
         exchange: :absent_closure_exchange,
         schedule: fn _, message, _ -> send(owner, {:scheduled, message}) end}
      )

    assert_received {:scheduled, :tick}
    assert_received {:scheduled, initial}
    send(pid, initial)
    assert {:ok, %{projections: [%{verdict: :ready}]}} = GenServer.call(pid, :show)

    for n <- 2..10 do
      Agent.update(Boundary, &%{&1 | now: n * 100_000})
      reconcile(pid)
      assert {:ok, %{projections: [%{verdict: :ready}]}} = GenServer.call(pid, :show)
    end

    assert Agent.get(Boundary, & &1.reads) == ["1"]
    Agent.update(Boundary, &%{&1 | labels: Map.put(labels, "1", %{labels: [], updated_at: nil})})
    reconcile(pid)
    assert {:ok, %{projections: [%{verdict: :waiting}]}} = GenServer.call(pid, :show)
    Agent.update(Boundary, &%{&1 | labels: labels, reason: "duplicate"})
    reconcile(pid)
    assert {:ok, %{projections: [%{verdict: {:unknown, [:duplicate]}}], actions: actions}} = GenServer.call(pid, :show)
    assert {:attention_open, {{:prerequisite_failed, :duplicate}, "1"}} in actions
    assert Agent.get(Boundary, & &1.reads) == ["1", "1"]
  end

  defp reconcile(pid) do
    assert :ok = GenServer.call(pid, :reconcile_now)
    assert_received {:scheduled, message}
    send(pid, message)
    GenServer.call(pid, :status)
  end
end
