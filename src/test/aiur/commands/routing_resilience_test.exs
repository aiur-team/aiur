Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.RoutingResilienceTest do
  use Aiur.DecisionStoreCase, async: false
  alias Aiur.Commands.Routing
  alias Aiur.Commands.Routing.Sweep

  @config %{enabled: true, ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}

  defmodule StoreProxy do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:list, _from, %{bad_list: true} = state), do: {:reply, :invalid_decision_list, state}

    def handle_call({:audit_history, id} = request, _from, %{fail_history_id: id, history_reads: reads} = state) do
      if reads == 1 do
        {:reply, {:error, :history_unavailable}, %{state | fail_history_id: nil}}
      else
        {:reply, GenServer.call(state.store, request), %{state | history_reads: reads + 1}}
      end
    end

    def handle_call(request, _from, state), do: {:reply, GenServer.call(state.store, request), state}
  end

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    store = start_store!(dir)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{store: store, now: DateTime.utc_now()}
  end

  defp router(ctx, opts \\ []) do
    defaults = [name: nil, store: ctx.store, clock: fn -> ctx.now end, config: @config, roster_fun: fn _opts -> %{executors: [%{state: :active}]} end]
    pid = start_supervised!(Supervisor.child_spec({Routing, Keyword.merge(defaults, opts)}, id: make_ref(), restart: :temporary))
    :sys.get_state(pid)
    pid
  end

  defp command(ctx, payload \\ %{}) do
    {:ok, %{decision: decision}} = request(ctx.store, Map.merge(%{"question" => "Proceed?", "blocking" => false}, payload))
    decision
  end

  defp current(ctx, decision) do
    {:ok, value} = DecisionStore.get(decision.decision_id, ctx.store)
    value
  end

  test "unrelated change traffic preserves the actual full-sweep timer under the ceiling", ctx do
    command(ctx)
    pid = router(ctx)
    before = :sys.get_state(pid)
    assert DateTime.diff(before.next_due_at, ctx.now, :millisecond) == @config.ack_ms
    assert Process.read_timer(before.timer_ref) in 1..30_000

    for _iteration <- 1..5 do
      send(pid, {:decision_changed, "missing-command", 1})
      after_change = :sys.get_state(pid)
      assert after_change.timer_ref == before.timer_ref
      assert after_change.next_due_at == before.next_due_at
      assert Process.read_timer(after_change.timer_ref) in 1..30_000
    end
  end

  test "a new earlier deadline replaces the actual timer before the old full-sweep time", ctx do
    command(ctx)
    pid = router(ctx, config: %{@config | ack_ms: 10_000})
    before = :sys.get_state(pid)
    assert Process.read_timer(before.timer_ref) in 5_001..10_000
    urgent = command(ctx, %{"question" => "Urgent?", "blocking" => true, "urgency" => "high"})
    DecisionPubSub.broadcast_changed(urgent.decision_id, urgent.version)
    after_change = :sys.get_state(pid)

    assert after_change.timer_ref != before.timer_ref
    assert Process.read_timer(before.timer_ref) == false
    assert Process.read_timer(after_change.timer_ref) in 1..5_000
    assert after_change.next_due_at == DateTime.add(ctx.now, 5, :second)
    assert current(ctx, urgent).route_state == :with_executor
  end

  test "unrelated changes preserve the roster polling timer when no deadline exists", ctx do
    pid = router(ctx)
    before = :sys.get_state(pid)
    assert before.next_due_at == nil
    send(pid, {:decision_changed, "missing-command", 1})
    after_change = :sys.get_state(pid)
    assert after_change.next_due_at == nil
    assert after_change.timer_ref == before.timer_ref
    assert Process.read_timer(after_change.timer_ref) in 1..30_000
  end

  test "raised sweep errors retain the same process and an armed retry then recover", ctx do
    decision = command(ctx)
    proxy = start_supervised!({StoreProxy, store: ctx.store, bad_list: true})

    log =
      capture_log(fn ->
        pid = router(ctx, store: proxy)
        assert Process.alive?(pid)
        assert Process.read_timer(:sys.get_state(pid).timer_ref) in 1..30_000
        assert current(ctx, decision).routed_at == nil
        :sys.replace_state(proxy, &%{&1 | bad_list: false})
        send(pid, :tick)
        :sys.get_state(pid)
        assert Process.alive?(pid)
        assert current(ctx, decision).route_state == :with_executor
      end)

    assert log =~ "aiur_command_routing sweep_failed"
  end

  test "history reread error skips one Command, continues others and repairs on retry", ctx do
    failed = command(ctx, %{"question" => "History unavailable?", "authority" => "human_required"})
    healthy = command(ctx, %{"question" => "Healthy?", "authority" => "human_required"})
    proxy = start_supervised!({StoreProxy, store: ctx.store, fail_history_id: failed.decision_id, history_reads: 0})
    assert {nil, [{id, :history_unavailable}]} = Sweep.run([failed, healthy], :live, ctx.now, @config, proxy)
    assert id == failed.decision_id
    assert current(ctx, failed).human_visible_at == ctx.now
    assert current(ctx, failed).human_needed_at == nil
    assert current(ctx, healthy).human_needed_at == ctx.now
    assert {nil, []} = Sweep.run([current(ctx, failed)], :live, ctx.now, @config, proxy)
    assert current(ctx, failed).human_needed_at == ctx.now
    assert {:ok, history} = DecisionStore.audit_history(failed.decision_id, ctx.store)
    assert Enum.count(history, &(&1.type == :human_needed)) == 1
  end
end
