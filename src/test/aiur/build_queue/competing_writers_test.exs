defmodule Aiur.BuildQueue.CompetingWritersTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{Hints, Model, Server}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def open_issue_labels(_age), do: Agent.get(__MODULE__, fn s -> {:ok, Map.new(s.labels, fn {id, labels} -> {id, %{labels: labels}} end), s.now} end)
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})
    def status(ids), do: Map.new(ids, &{&1, :unclaimed})
    def notify_demand(_ids), do: :ok

    def save(document) do
      Agent.get_and_update(__MODULE__, fn s ->
        if s.save_error, do: {{:error, s.save_error}, s}, else: {:ok, %{s | document: document}}
      end)
    end

    def update_issue_state(id, "todo", expected_state: :none) do
      Agent.get_and_update(__MODULE__, fn s ->
        result = Map.get(s, :write_result, :ok)
        labels = if result == :ok, do: Map.update!(s.labels, id, &Enum.uniq(&1 ++ ["agent:todo"])), else: s.labels
        {result, %{s | calls: s.calls ++ [{:promote, id}], labels: labels}}
      end)
    end
  end

  setup do
    queue = %Model.Queue{id: "q", name: "Q", kind: :build_order, root: 1, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    items = for id <- ["1", "2"], do: %Model.Item{issue_id: id, queue_id: "q", position: nil, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
    document = %{queues: [queue], items: items, edges: [%Model.Edge{prerequisite: "1", dependent: "2", source: :native}], intents: [], latches: []}
    pid = start_supervised!({Agent, fn -> %{document: document, now: 1_000, labels: %{"1" => ["agent:queued"], "2" => ["agent:queued"]}, calls: [], save_error: nil} end})
    Process.register(pid, Boundary)
    :ok
  end

  test "AC7: external todo removal survives five reconciles until item release" do
    pid = server()
    reconcile(pid)
    assert calls() == [{:promote, "1"}]
    labels("1", ["agent:queued"])
    for _ <- 1..5, do: reconcile(pid)
    assert item("1").hold == :external
    assert Hints.held?("1")
    assert calls() == [{:promote, "1"}]
    assert :ok = Aiur.BuildQueue.release("1", pid)
    reconcile(pid)
    assert item("1").hold == nil
    assert calls() == [{:promote, "1"}, {:promote, "1"}]
  end

  test "manual todo on a waiting item persists override without withdrawing" do
    labels("2", ~w(agent:queued agent:todo))
    pid = server()
    reconcile(pid)
    assert item("2").override == :manual_promotion
    labels("2", ["agent:queued"])
    for _ <- 1..5, do: reconcile(pid)
    assert projection(pid, "2").state == :overridden
    assert calls() == [{:promote, "1"}]
    assert :ok = Aiur.BuildQueue.release("2", pid)
    reconcile(pid)
    assert projection(pid, "2").state == :waiting
    assert item("2").override == nil
  end

  test "marker removal dequeues item and drops edges before replanning its dependent" do
    pid = server()
    reconcile(pid)
    labels("1", ["agent:todo"])
    reconcile(pid)
    assert Enum.map(document().items, & &1.issue_id) == ["2"]
    assert document().edges == []
    token = :sys.get_state(pid).pending
    assert is_reference(token)
    assert_received {:scheduled, ^pid, {:reconcile, ^token}}
    send(pid, {:reconcile, token})
    GenServer.call(pid, :show)
    assert projection(pid, "2").verdict == :ready
    assert calls() == [{:promote, "1"}, {:promote, "2"}]
    assert Hints.sort_key("1") == {0, 0}
  end

  test "successful and pending matching intents explain own promotion for two reconciles" do
    for outcome <- [:ok, nil] do
      intent = %Model.Intent{id: "pending", issue_id: "2", action: :promote, target_labels: ~w(agent:todo agent:queued), recorded_at_ms: 1_000, outcome: outcome}
      change_document(&%{&1 | intents: [intent]})
      labels("2", ~w(agent:queued agent:todo))
      pid = server()
      reconcile(pid)
      assert projection(pid, "2").state == :promoted
      reconcile(pid)
      assert projection(pid, "2").state == :promoted
      reconcile(pid)
      assert projection(pid, "2").state == :overridden
      assert item("2").override == :manual_promotion
      stop_supervised!(Server)
      change_document(fn d -> %{d | items: Enum.map(d.items, &%{&1 | override: nil})} end)
    end
  end

  test "queue release clears queue/operator holds and adopts existing manual todo" do
    change_document(fn d -> %{d | queues: Enum.map(d.queues, &%{&1 | held: true}), items: Enum.map(d.items, &%{&1 | hold: :operator})} end)
    labels("1", ~w(agent:queued agent:todo))
    pid = server()
    reconcile(pid)
    assert item("1").override == :manual_promotion
    assert :ok = Aiur.BuildQueue.release("q", pid)
    reconcile(pid)
    assert Enum.all?(document().items, &(&1.hold == nil and &1.override == nil))
    assert hd(document().queues).held == false
    assert projection(pid, "1").state == :promoted
    refute Hints.held?("1")
    assert calls() == []
  end

  test "failed bookkeeping save stops batch without changing durable state" do
    labels("1", [])
    labels("2", ~w(agent:queued agent:todo))
    Agent.update(Boundary, &%{&1 | save_error: :disk_full})
    pid = server()
    reconcile(pid)
    assert GenServer.call(pid, :status) == :store_unavailable
    assert Enum.map(document().items, & &1.issue_id) == ["1", "2"]
    assert item("2").override == nil
    assert calls() == []
  end

  test "an earlier promotion budget pause cannot discard a later manual override" do
    labels("2", ~w(agent:queued agent:todo))
    Agent.update(Boundary, &Map.put(&1, :write_result, {:error, {:github, :local_hold, %{}}}))
    pid = server()
    reconcile(pid)
    assert GenServer.call(pid, :status) == :writes_paused
    assert item("2").override == :manual_promotion
    labels("2", ["agent:queued"])
    reconcile(pid)
    assert projection(pid, "2").state == :overridden
  end

  test "release reports unknown, unavailable and persistence errors" do
    pid = server()
    reconcile(pid)
    assert Aiur.BuildQueue.release("missing", pid) == {:error, :not_found}
    Agent.update(Boundary, &%{&1 | labels: %{}})
    assert Aiur.BuildQueue.release("1", pid) == {:error, :observation_unavailable}
    labels("1", ["agent:queued"])
    Agent.update(Boundary, &%{&1 | save_error: :disk_full})
    assert Aiur.BuildQueue.release("1", pid) == {:error, :disk_full}
    assert Aiur.BuildQueue.release("1", pid) == {:error, :store_unavailable}
    stop_supervised!(Server)
    assert Aiur.BuildQueue.release("1", pid) == {:error, :disabled}
  end

  defp server do
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    start_supervised!(
      {Server,
       name: nil,
       settings: {:ok, settings},
       tracker: Boundary,
       store: Boundary,
       claim_probe: Boundary,
       exchange: :absent_competing_exchange,
       clock: fn -> Agent.get(Boundary, & &1.now) end,
       schedule: fn pid, message, _ -> send(owner, {:scheduled, pid, message}) end}
    )
  end

  defp reconcile(pid) do
    Agent.update(Boundary, &%{&1 | now: &1.now + 1_000})
    :ok = GenServer.call(pid, :reconcile_now)
    send(pid, {:reconcile, :sys.get_state(pid).pending})
    GenServer.call(pid, :show)
  end

  defp projection(pid, id) do
    {:ok, %{projections: projections}} = GenServer.call(pid, :show)
    Enum.find(projections, &(&1.issue_id == id))
  end

  defp labels(id, labels), do: Agent.update(Boundary, &%{&1 | labels: Map.put(&1.labels, id, labels)})
  defp change_document(fun), do: Agent.update(Boundary, &%{&1 | document: fun.(&1.document)})
  defp document, do: Agent.get(Boundary, & &1.document)
  defp item(id), do: Enum.find(document().items, &(&1.issue_id == id))
  defp calls, do: Agent.get(Boundary, & &1.calls)
end
