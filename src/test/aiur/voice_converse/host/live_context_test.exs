defmodule Aiur.VoiceConverse.Host.LiveContextTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Exchange
  alias Aiur.TrackerIdentity
  alias Aiur.VoiceConverse.Host.{BriefingSource, CommandSource, LiveContext, Worker}

  defmodule Live do
    def subscribe(observer), do: send(observer, {:live_subscriber, self()})
  end

  defmodule Capabilities do
    def report, do: %{executor: %{state: "idle"}}
  end

  defmodule UnavailableCapabilities do
    def report, do: %{executor: nil}
  end

  defmodule UnregisteredExchange do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :name), opts)
    def init(state), do: {:ok, state}

    def handle_call({:subscribe, _pattern, _pid}, _from, state) do
      Process.unregister(state)
      {:reply, :ok, state}
    end
  end

  setup do
    exchange = start_supervised!({Exchange, []})
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_42", "number" => 42}, {"org", "repo"}, {"org", "repo"})
    %{exchange: exchange, target: %Worker{identity: identity}}
  end

  test "new and resolved Commands arrive only for the subscribed ticket", %{exchange: exchange, target: target} do
    assert :ok = CommandSource.subscribe(target, self(), exchange: exchange)
    assert 0 == publish(exchange, "ticket.43.agent.decision.requested", %{question: "Wrong ticket?"})
    publish(exchange, "ticket.42.agent.decision.requested", %{question: "Ship?", decision_id: "cmd1"})
    assert_receive {:context_update, "New Command: Ship?", []}, 1_000
    refute_receive {:context_update, "New Command: Wrong ticket?", []}, 100
    publish(exchange, "ticket.42.agent.decision.answered", %{decision_id: "cmd1"})
    assert_receive {:command_resolved, "cmd1"}, 1_000
    publish(exchange, "ticket.42.agent.unknown", %{question: "Ignore?"})
    refute_receive {:context_update, _, _}, 100
  end

  test "status notes push a portable briefing and phase milestones remain scoped", ctx do
    assert :ok = BriefingSource.subscribe(ctx.target, self(), exchange: ctx.exchange, orchestrator: :absent_test_orchestrator)
    publish(ctx.exchange, "ticket.42.agent.progress.status", %{payload: %{doing: "Run tests", why: "Check context", asks: "Choose?"}})
    assert_receive {:briefing, briefing}, 1_000
    assert briefing.current_task.value == "Run tests"
    assert briefing.questions.value == ["Choose?"]
    publish(ctx.exchange, "ticket.42.agent.progress.status", %{payload: %{unexpected: "ignore"}})
    refute_receive {:briefing, _}, 100
    publish(ctx.exchange, "ticket.42.agent.phase.work.end", %{})
    assert_receive {:context_update, "Phase: work.end", []}, 1_000
  end

  test "executor subscribes to system and executor namespaces", %{exchange: exchange} do
    assert :ok = LiveContext.subscribe(:executor, self(), :briefing, exchange: exchange, capabilities: Capabilities)
    publish(exchange, "system.build_order.root.progress", %{percent: 50})
    assert_receive {:context_update, "Build order progress: 50%", []}, 1_000
    publish(exchange, "system.capabilities.changed", %{revision: 2})
    assert_receive {:context_update, "Executor state: idle", []}, 1_000
    publish(exchange, "ticket.42.queue.attention.prerequisite_failed", %{blocked: ["43", "44", "45"]})
    assert_receive {:context_update, "Failed prerequisite blocks 3 tickets", []}, 1_000
    publish(exchange, "ticket.42.queue.attention.prerequisite_failed.resolved", %{})
    assert_receive {:context_update, "Failed prerequisite cleared", []}, 1_000
    publish(exchange, "ticket.42.pr.opened", %{})
    refute_receive {:context_update, "PR opened", []}, 100
  end

  test "unavailable Executor state is explicit after a capability change", %{exchange: exchange} do
    assert :ok = LiveContext.subscribe(:executor, self(), :briefing, exchange: exchange, capabilities: UnavailableCapabilities)
    publish(exchange, "system.capabilities.changed", %{revision: 3})
    assert_receive {:context_update, "Executor state unavailable", []}, 1_000
  end

  test "an ended live worker generation ends its subscribed voice target", ctx do
    target = %{ctx.target | live_source: self()}
    assert :ok = BriefingSource.subscribe(target, self(), exchange: ctx.exchange, live: Live)
    assert_receive {:live_subscriber, adapter}, 1_000
    send(adapter, {:live_conversation_changed, %{state: :ended}})
    assert_receive :target_gone, 1_000
  end

  test "missing Exchange degrades to unsupported", %{target: target} do
    assert :unsupported = LiveContext.subscribe(target, self(), :briefing, exchange: :missing_test_exchange)
  end

  test "subscription monitors the same Exchange PID after its name is unregistered", %{target: target} do
    name = Module.concat(__MODULE__, "Vanishing#{System.unique_integer([:positive])}")
    exchange = start_supervised!(Supervisor.child_spec({UnregisteredExchange, name: name}, restart: :temporary))
    assert :ok = LiveContext.subscribe(target, self(), :briefing, exchange: name)
    refute_receive :live_context_unavailable, 100
    GenServer.stop(exchange)
    assert_receive :live_context_unavailable, 1_000
  end

  test "Exchange loss reports unavailable instead of silently retaining a dead subscription", ctx do
    assert :ok = BriefingSource.subscribe(ctx.target, self(), exchange: ctx.exchange)
    GenServer.stop(ctx.exchange)
    assert_receive :live_context_unavailable, 1_000
  end

  test "subscriptions are reaped when the session exits", %{exchange: exchange, target: target} do
    subscriber =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    assert :ok = LiveContext.subscribe(target, subscriber, :commands, exchange: exchange)
    assert 1 == publish(exchange, "ticket.42.agent.decision.requested", %{question: "Ship?"})
    # Monitor the adapter rather than sleeping while Exchange reaps its bindings.
    [{_, adapter, _}] = :ets.tab2list(:persistent_term.get({{Exchange, :table}, exchange}))
    monitor = Process.monitor(adapter)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^adapter, _}, 1_000
  end

  defp publish(exchange, topic, payload), do: Exchange.publish(topic, Map.put(payload, :topic, topic), exchange)
end
