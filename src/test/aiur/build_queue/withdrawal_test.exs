defmodule Aiur.BuildQueue.WithdrawalTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.BuildQueue.{Hints, Model, Server}
  alias Aiur.Config.Schema
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator.{IssueSync, State}

  defmodule Boundary do
    def load, do: Agent.get(__MODULE__, &{:ok, &1.document})
    def save(document), do: Agent.update(__MODULE__, &%{&1 | document: document, now: &1.now + Map.get(&1, :save_advance_ms, 0)})

    def open_issue_labels(_age) do
      state = Agent.get(__MODULE__, & &1)

      if Map.get(state, :snapshot_unavailable, false),
        do: {:error, :unavailable},
        else: {:ok, Map.new(state.labels, fn {id, labels} -> {id, %{labels: labels, updated_at: nil}} end), state.observed_at}
    end

    def status(ids) do
      held = Map.new(ids, &{&1, Hints.held?(&1)})
      promoted = Agent.get(__MODULE__, fn state -> Enum.filter(state.document.items, &(&1.promoted_at != nil and not Map.get(state, :snapshot_unavailable, false))) end)
      unless Enum.all?(promoted, &held[&1.issue_id]), do: raise("probe ran before withdrawal holds")
      Agent.get_and_update(__MODULE__, fn state -> {state.claims, %{state | probes: state.probes ++ [{ids, held}]}} end)
    end

    def remove_label(id, label) do
      Agent.get_and_update(__MODULE__, fn state ->
        [result | rest] = state.results
        results = if rest == [], do: [result], else: rest
        labels = if result == :ok, do: Map.update!(state.labels, id, &List.delete(&1, label)), else: state.labels
        intent = List.last(state.document.intents)
        {result, %{state | labels: labels, results: results, calls: state.calls ++ [{id, label, intent}]}}
      end)
    end

    def notify_demand(_ids), do: raise("withdrawal must not notify demand")
    def update_issue_state(_id, _state, _opts), do: raise("withdrawal must not promote")
  end

  setup do
    queue = %Model.Queue{id: "q", name: "Q", kind: :build_order, root: 1, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
    item = %Model.Item{issue_id: "1", queue_id: "q", position: nil, hold: nil, override: nil, promoted_at: DateTime.from_unix!(0), added_at: queue.created_at}
    edge = %Model.Edge{prerequisite: "2", dependent: "1", source: :native}
    document = %{queues: [queue], items: [item], edges: [edge], intents: [], latches: []}

    state = %{
      document: document,
      labels: %{"1" => ["agent:queued", "agent:todo"], "2" => ["agent:queued"]},
      now: 10_000,
      observed_at: 10_000,
      claims: %{"1" => :unclaimed},
      probes: [],
      calls: [],
      results: [:ok]
    }

    pid = start_supervised!({Agent, fn -> state end})
    Process.register(pid, Boundary)
    :ok
  end

  test "AC4: withdrawal keeps queued marker and real IssueSync does not heal todo" do
    :ok = Exchange.subscribe("ticket.1.queue.withdrawn")
    pid = server()
    reconcile(pid)
    assert labels() == ["agent:queued"]
    assert [{"1", "agent:todo", %{action: :withdraw, outcome: nil, target_labels: ["agent:queued"]}}] = get(:calls)
    assert [%{action: :withdraw, outcome: :ok}] = get(:document).intents
    Exchange.bindings_for(self())
    assert_received {:event, %{"ticket" => "1", "queue_id" => "q", "cause" => "withdraw", topic: "ticket.1.queue.withdrawn"}}
    assert Hints.held?("1")
    previous = %Issue{id: "1", identifier: "1", state: "todo", state_labels: ["agent:todo"], labels: ["agent:queued", "agent:todo"], queued: true}
    observed = %{previous | state: nil, state_labels: [], labels: labels()}

    {_, [healed]} =
      IssueSync.reconcile_contradictory_state_labels(%State{last_polled_issues: %{"1" => previous}}, [observed], fn id, state ->
        Agent.update(Boundary, &%{&1 | labels: Map.update!(&1.labels, id, fn labels -> labels ++ ["agent:#{state}"] end)})
      end)

    assert healed.state == nil
    assert labels() == ["agent:queued"]
    next(pid)
    refute Hints.held?("1")
    assert hd(get(:document).items).promoted_at == nil
    next(pid)
    assert {:ok, %{projections: [%{state: :waiting}], actions: []}} = GenServer.call(pid, :show)
  end

  test "AC5: claimed with only todo keeps labels and releases hold with attention" do
    put(:claims, %{"1" => :claimed})
    pid = server()
    reconcile(pid)
    assert get(:calls) == []
    assert labels() == ["agent:queued", "agent:todo"]
    refute Hints.held?("1")
    assert {:ok, %{actions: actions}} = GenServer.call(pid, :show)
    assert {:attention_open, {:dependency_changed_after_start, "1"}} in actions
    assert get(:probes) == [{["1"], %{"1" => true}}]
  end

  test "AC6: unavailable and missing claim proofs retain hold without any write" do
    put(:claims, :unavailable)
    pid = server()
    reconcile(pid)

    for claims <- [:unavailable, %{}, %{"1" => :unavailable}] do
      put(:claims, claims)
      next(pid)
      assert Hints.held?("1")
      assert get(:calls) == []
      assert get(:document).intents == []
      assert {:ok, %{projections: [%{state: :held, reason: :claim_check_unavailable}]}} = GenServer.call(pid, :show)
    end

    put(:claims, %{"1" => :unclaimed})
    next(pid)
    assert labels() == ["agent:queued"]
  end

  test "holds precede the single batch probe, including on later reconciles" do
    Agent.update(Boundary, fn state ->
      item = %{hd(state.document.items) | issue_id: "3"}
      edge = %Model.Edge{prerequisite: "2", dependent: "3", source: :native}

      %{
        state
        | document: %{state.document | items: state.document.items ++ [item], edges: state.document.edges ++ [edge]},
          labels: Map.put(state.labels, "3", ["agent:queued", "agent:todo"]),
          claims: :unavailable
      }
    end)

    pid = server()
    reconcile(pid)
    next(pid)
    assert get(:probes) == List.duplicate({["1", "3"], %{"1" => true, "3" => true}}, 2)
    assert get(:calls) == []
  end

  test "declined means unclaimed for withdrawal, including an unauthorized decline" do
    put(:claims, %{"1" => {:declined, :unauthorized}})
    pid = server()
    reconcile(pid)
    assert labels() == ["agent:queued"]
    assert [%{outcome: :ok}] = get(:document).intents
  end

  test "remove failures use the writer retry policy and keep the hold" do
    put(:results, [{:error, :transport}])
    pid = server()
    reconcile(pid)
    assert length(get(:calls)) == 4
    assert Hints.held?("1")
    assert labels() == ["agent:queued", "agent:todo"]
    put(:results, [:ok])
    next(pid)
    assert labels() == ["agent:queued"]
    assert Hints.held?("1")
    next(pid)
    refute Hints.held?("1")
  end

  test "budget failure keeps hold and retries on next reconciliation" do
    put(:results, [{:error, {:github, :local_hold, %{}}}])
    pid = server()
    reconcile(pid)
    assert GenServer.call(pid, :status) == :writes_paused
    assert length(get(:calls)) == 1
    assert Hints.held?("1")
    put(:results, [:ok])
    next(pid)
    assert GenServer.call(pid, :status) == :running
    assert labels() == ["agent:queued"]
  end

  test "evidence expiring during intent persistence cannot remove todo" do
    put(:save_advance_ms, 120_001)
    pid = server()
    reconcile(pid)
    assert get(:calls) == []
    assert [%{action: :withdraw, outcome: {:error, :stale_observation}}] = get(:document).intents
    assert Hints.held?("1")
    assert labels() == ["agent:queued", "agent:todo"]
  end

  test "delayed observation beyond the intent window still releases hold when removal is seen" do
    pid = server()
    reconcile(pid)
    put(:snapshot_unavailable, true)
    for _ <- 1..3, do: next(pid, false)
    assert Hints.held?("1")
    assert length(get(:calls)) == 1
    put(:snapshot_unavailable, false)
    next(pid)
    refute Hints.held?("1")
    assert hd(get(:document).items).hold == nil
  end

  test "stalled unavailable holds warn after three intervals and stay held" do
    put(:claims, :unavailable)
    pid = server()
    reconcile(pid)
    put(:now, 190_001)
    log = capture_log(fn -> next(pid) end)
    assert log =~ "withdrawal held for 1"
    assert log =~ "retaining dispatch hold"
    assert Hints.held?("1")
    assert get(:calls) == []
  end

  test "restart after removal recovers its intent and never invents an external hold" do
    pid = server()
    reconcile(pid)
    assert Hints.held?("1")
    assert labels() == ["agent:queued"]
    stop_supervised!(Server)
    refute Hints.held?("1")
    put(:snapshot_unavailable, true)
    pid = server()
    reconcile(pid)
    for _ <- 1..3, do: next(pid, false)
    put(:snapshot_unavailable, false)
    next(pid)
    assert hd(get(:document).items).promoted_at == nil
    refute Hints.held?("1")
    next(pid)
    assert {:ok, %{projections: [%{state: :waiting}], actions: []}} = GenServer.call(pid, :show)
    assert length(get(:calls)) == 1
    assert hd(get(:document).items).hold == nil
  end

  defp server do
    owner = self()
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true, observation_max_age_seconds: 120}, tracker: %Schema.Tracker{}}

    start_supervised!(
      {Server,
       name: nil,
       settings: {:ok, settings},
       tracker: Boundary,
       store: Boundary,
       claim_probe: Boundary,
       clock: fn -> get(:now) end,
       sleep: fn _ -> :ok end,
       exchange: :absent_withdrawal_exchange,
       schedule: fn pid, message, _delay ->
         send(owner, {:scheduled, pid, message})
         make_ref()
       end}
    )
  end

  defp reconcile(pid) do
    GenServer.call(pid, :status)
    assert_received {:scheduled, ^pid, {:reconcile, _} = message}
    send(pid, message)
    GenServer.call(pid, :show)
  end

  defp next(pid, fresh \\ true) do
    if fresh, do: Agent.update(Boundary, &%{&1 | now: &1.now + 1, observed_at: &1.now + 1})
    GenServer.call(pid, :reconcile_now)
    reconcile(pid)
  end

  defp labels, do: get(:labels)["1"]
  defp get(key), do: Agent.get(Boundary, &Map.fetch!(&1, key))
  defp put(key, value), do: Agent.update(Boundary, &Map.put(&1, key, value))
end
