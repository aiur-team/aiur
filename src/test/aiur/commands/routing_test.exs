Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.RoutingTest do
  use Aiur.DecisionStoreCase, async: false
  alias Aiur.Application, as: AiurApp
  alias Aiur.Commands.Routing

  @config %{enabled: true, ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(dir, "executor"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :executor_state_dir, previous), else: Application.delete_env(:aiur, :executor_state_dir)
    end)

    store = start_store!(dir)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    {:ok, roster} = Agent.start_link(fn -> :active end)
    %{store: store, clock: clock, roster: roster}
  end

  defp router(ctx, opts \\ []) do
    parent = self()

    defaults = [
      name: nil,
      store: ctx.store,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      config: @config,
      roster_fun: fn opts ->
        send(parent, {:roster_options, opts})

        case Agent.get(ctx.roster, & &1) do
          :offline -> %{executors: []}
          :raise -> raise "roster failed"
          :timeout -> exit(:timeout)
          state -> %{executors: [%{state: state}]}
        end
      end
    ]

    pid = start_supervised!(Supervisor.child_spec({Routing, Keyword.merge(defaults, opts)}, id: make_ref(), restart: :temporary))
    :sys.get_state(pid)
    pid
  end

  defp command(ctx, payload \\ %{}) do
    {:ok, %{decision: decision}} = request(ctx.store, Map.merge(%{"question" => "Proceed?", "blocking" => false}, payload))
    decision
  end

  defp current(ctx, d) do
    {:ok, value} = DecisionStore.get(d.decision_id, ctx.store)
    value
  end

  defp history(ctx, d) do
    {:ok, events} = DecisionStore.audit_history(d.decision_id, ctx.store)
    events
  end

  defp count(ctx, d, type), do: Enum.count(history(ctx, d), &(&1.type == type))
  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))
  defp tick(pid), do: GenServer.call(pid, :sweep)

  test "routes live Executor work then escalates acknowledged work at answer deadline once", ctx do
    d = command(ctx)
    pid = router(ctx)
    assert current(ctx, d).route_state == :with_executor
    assert current(ctx, d).routed_at == Agent.get(ctx.clock, & &1)
    assert_received {:roster_options, opts}
    assert opts[:record?] == false
    assert {:ok, _} = DecisionStore.record_command_fact(d.decision_id, :executor_acknowledged, %{at: Agent.get(ctx.clock, & &1), executor_id: "exec", via: :explicit}, server: ctx.store)
    advance(ctx, 899)
    tick(pid)
    assert current(ctx, d).route_state == :with_executor
    advance(ctx, 1)
    tick(pid)
    assert current(ctx, d).route_state == :with_human
    assert [%{cause: :executor_answer_timeout}] = current(ctx, d).escalations
    tick(pid)
    assert count(ctx, d, :escalated) == 1
    assert count(ctx, d, :human_needed) == 1
  end

  test "boot catches missed acknowledgement deadline and restarts never re-ask", ctx do
    d = command(ctx)
    pid = router(ctx)
    GenServer.stop(pid)
    advance(ctx, 1200)
    restarted = router(ctx)
    assert [%{cause: :executor_ack_timeout}] = current(ctx, d).escalations
    GenServer.stop(restarted)
    last = router(ctx)
    advance(ctx, 3600)
    tick(last)
    assert count(ctx, d, :escalated) == 1
    assert count(ctx, d, :human_needed) == 1
  end

  test "durable replay catches downtime and preserves exactly one human-needed", ctx do
    d = command(ctx)
    pid = router(ctx)
    GenServer.stop(pid)
    GenServer.stop(ctx.store)
    advance(ctx, 1200)
    restored = start_store!(ctx.dir)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    ctx = %{ctx | store: restored}
    recovered = router(ctx)
    assert current(ctx, d).route_state == :with_human
    assert count(ctx, d, :routed) == 1
    assert count(ctx, d, :escalated) == 1
    assert count(ctx, d, :human_needed) == 1
    GenServer.stop(recovered)
    GenServer.stop(restored)
    replayed = start_store!(ctx.dir)
    on_exit(fn -> if Process.alive?(replayed), do: GenServer.stop(replayed) end)
    ctx = %{ctx | store: replayed}
    router(ctx)
    assert count(ctx, d, :escalated) == 1
    assert count(ctx, d, :human_needed) == 1
  end

  test "legacy human-required Commands route simultaneously and never re-ask", ctx do
    {:ok, %{decision: d}} = project_attention(ctx.store, minimal_attention("Need operator?"))
    pid = router(ctx)
    assert current(ctx, d).route_state == :with_both
    assert current(ctx, d).route_policy == :simultaneous
    advance(ctx, 3600)
    tick(pid)
    assert count(ctx, d, :routed) == 1
    assert count(ctx, d, :human_needed) == 1
    assert count(ctx, d, :escalated) == 0
  end

  test "empty roster routes straight to human", ctx do
    d = command(ctx)
    Agent.update(ctx.roster, fn _ -> :offline end)
    router(ctx)
    assert current(ctx, d).route_state == :with_human
    assert Enum.find(history(ctx, d), &(&1.type == :routed)).data.cause == :executor_offline
    assert count(ctx, d, :human_needed) == 1
  end

  for state <- [:stalled, :offline, :raise, :timeout] do
    test "roster #{state} during deadline escalates immediately", ctx do
      d = command(ctx)
      pid = router(ctx)
      Agent.update(ctx.roster, fn _ -> unquote(state) end)
      capture_log(fn -> tick(pid) end)
      expected = if unquote(state) == :offline, do: :executor_offline, else: :executor_stalled
      assert [%{cause: ^expected}] = current(ctx, d).escalations
      assert count(ctx, d, :human_needed) == 1
    end
  end

  # Future regression guard: Facts already prevents terminal/answered escalation; not new Routing coverage.
  test "future regression guard: answers and expiry stop deadlines", ctx do
    answered = command(ctx)
    expired = command(ctx, %{"question" => "Expired?"})
    pid = router(ctx)
    assert {:ok, _} = answer(ctx.store, answered.decision_id, %{"idempotency_key" => "answer", "expected_version" => 1, "custom_response" => "Proceed"})
    assert {:ok, _} = DecisionStore.expire(expired.decision_id, "test", [], ctx.store)
    advance(ctx, 3600)
    tick(pid)
    for d <- [answered, expired], do: assert(count(ctx, d, :escalated) == 0)
  end

  test "accepted defer reroutes once across restart and retains first human visibility", ctx do
    d = command(ctx)
    pid = router(ctx)
    advance(ctx, 300)
    tick(pid)
    visible = current(ctx, d).human_visible_at
    GenServer.stop(pid)
    advance(ctx, 60)
    assert {:ok, _} = DecisionStore.defer(d.decision_id, [actor: %{kind: :operator, id: "dashboard"}], ctx.store)
    resumed = router(ctx)
    assert current(ctx, d).route_state == :with_executor
    assert current(ctx, d).routed_at == Agent.get(ctx.clock, & &1)
    assert current(ctx, d).human_visible_at == visible
    tick(resumed)
    assert count(ctx, d, :routed) == 2
    assert count(ctx, d, :human_needed) == 1
    advance(ctx, 300)
    tick(resumed)
    assert current(ctx, d).route_state == :with_human
    assert count(ctx, d, :escalated) == 2
    assert count(ctx, d, :human_needed) == 1
  end

  test "human-required and Executor-originated Commands cannot defer", ctx do
    human = command(ctx, %{"authority" => "human_required"})
    {:ok, %{decision: executor}} = request(ctx.store, %{"question" => "Executor asks?", "blocking" => false}, ticket: %{identifier: "executor"}, requester: %{kind: :executor})

    for d <- [human, executor] do
      assert {:error, {:conflict, :not_deferrable}} = DecisionStore.defer(d.decision_id, [actor: %{kind: :operator, id: "dashboard"}], ctx.store)
      assert current(ctx, d).decision_status == :open
    end
  end

  test "repairs crash between human visibility and human-needed", ctx do
    d = command(ctx)
    at = Agent.get(ctx.clock, & &1)

    assert {:ok, _} =
             DecisionStore.record_command_fact(d.decision_id, :routed, %{policy: :human_only, state: :with_human, cause: :executor_offline, at: at, actor: %{kind: :system, id: "routing"}},
               server: ctx.store
             )

    pid = router(ctx)
    tick(pid)
    assert count(ctx, d, :human_needed) == 1
    assert Enum.find(history(ctx, d), &(&1.type == :human_needed)).data.cause == :executor_offline
  end

  test "kill switch prevents all routing writes", ctx do
    d = command(ctx)
    pid = router(ctx, config: %{@config | enabled: false})
    advance(ctx, 3600)
    tick(pid)
    assert current(ctx, d).routed_at == nil
    assert count(ctx, d, :human_needed) == 0
  end

  test "read-only failure retains timer and retry recovers", ctx do
    d = command(ctx)
    :sys.replace_state(ctx.store, &%{&1 | writable?: false})

    capture_log(fn ->
      pid = router(ctx)
      assert is_reference(:sys.get_state(pid).timer_ref)
      assert current(ctx, d).routed_at == nil
      :sys.replace_state(ctx.store, &%{&1 | writable?: true})
      tick(pid)
      assert current(ctx, d).route_state == :with_executor
    end)
  end

  test "explicit Executor escalation becomes human visibility once", ctx do
    d = command(ctx)
    pid = router(ctx)
    assert {:ok, _} = DecisionStore.escalate_executor_command(d.decision_id, %{expected_version: d.version, executor_id: "exec", reason: "Needs operator"}, ctx.store)
    DecisionPubSub.broadcast_changed(d.decision_id, d.version)
    :sys.get_state(pid)
    assert [%{cause: :executor_escalated}] = current(ctx, d).escalations
    assert count(ctx, d, :human_needed) == 1
    assert Enum.find(history(ctx, d), &(&1.type == :human_needed)).data.cause == :executor_escalated
  end

  test "timer tick uses the earliest deadline and remains bounded", ctx do
    d = command(ctx)
    pid = router(ctx, config: %{@config | ack_ms: 10_000})
    state = :sys.get_state(pid)
    assert state.next_due_at == DateTime.add(current(ctx, d).routed_at, 10, :second)
    assert Process.read_timer(state.timer_ref) <= 10_000
    advance(ctx, 10)
    send(pid, :tick)
    :sys.get_state(pid)
    assert [%{cause: :executor_ack_timeout}] = current(ctx, d).escalations
    assert count(ctx, d, :human_needed) == 1
  end

  test "application supervises Routing between the durable store and expiry" do
    for opts <- [[interactive_cli?: true, headless?: false, dashboard?: true], [interactive_cli?: false, headless?: true, dashboard?: false]] do
      children =
        AiurApp.child_specs(opts)
        |> List.flatten()
        |> Enum.map(fn
          {mod, _opts} -> mod
          %{id: id} -> id
          mod -> mod
        end)

      routing = Enum.find_index(children, &(&1 == Routing))
      assert is_integer(routing)
      assert Enum.find_index(children, &(&1 == DecisionStore)) < routing
      assert routing < Enum.find_index(children, &(&1 == DecisionExpiry))
    end
  end

  test "change feed routes newly created Commands without waiting for tick", ctx do
    pid = router(ctx)
    d = command(ctx)
    # PubSub dispatch and the barrier share this sender; no tick can mask a missing subscription.
    DecisionPubSub.broadcast_changed(d.decision_id, d.version)
    :sys.get_state(pid)
    assert current(ctx, d).route_state == :with_executor
  end
end
