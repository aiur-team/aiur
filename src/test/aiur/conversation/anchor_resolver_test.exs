Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.AnchorResolverTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, ResolverState, ResolverSupervisor, Store, TestSupport}
  alias Aiur.Application.Children
  alias Aiur.Events.Exchange
  import TestSupport

  defmodule RecoveringStore do
    alias Aiur.Conversation.Store
    defdelegate prepare(dir, ref), to: Store
    defdelegate rebuild_head(dir), to: Store
    defdelegate stream_entries(dir, from, to), to: Store
    defdelegate append_entries(dir, head, entries), to: Store
    defdelegate append_session_line(dir, line), to: Store

    def append_anchor_line(dir, line) do
      control = Application.fetch_env!(:aiur, :conversation_test_control)
      action = Agent.get_and_update(control, &{Map.get(&1, :anchor_action), Map.delete(&1, :anchor_action)})

      case action do
        :uncertain ->
          Store.append_anchor_line(dir, line)
          {:error, :eio}

        :partial ->
          File.write!(Path.join(dir, "anchors.jsonl"), "{torn", [:append])
          {:error, :enospc}

        :fail ->
          {:error, :enospc}

        _ ->
          Store.append_anchor_line(dir, line)
      end
    end
  end

  setup context do
    ctx = TestSupport.setup(context)
    # Real file writes, registry, History windows and PubSub; only the clock/timers are controlled.
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, Store)
    Application.put_env(:aiur, :conversation_journal, opts)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I_anchor_6627", "number" => 6627}, {"aiur-team", "aiur"}, {"aiur-team", "aiur"})
    {:ok, ref} = Ref.worker(identity)
    exchange = start_supervised!({Exchange, []})
    Agent.update(ctx.control, &Map.put(&1, :monotonic, 0))
    owner = self()

    timer = fn _pid, msg, ms ->
      send(owner, {:scheduled, msg, ms})
      make_ref()
    end

    resolver = start_supervised!({AnchorResolver, name: nil, exchange: exchange, pubsub: ctx.pubsub, send_after: timer, monotonic: fn -> Agent.get(ctx.control, & &1.monotonic) end})
    Map.merge(ctx, %{ref: ref, identity: identity, dir: Path.join(ctx.root, Ref.conversation_id(ref)), exchange: exchange, resolver: resolver})
  end

  test "live progress with an existing tool entry persists one exact anchor and notifies after fsync", ctx do
    append_tool(ctx, "tool-one")
    subscribe(ctx)
    publish(ctx, bus(ctx, 1, "agent.progress", "tool-one"))
    assert :ok = flush(ctx.ref)
    assert [anchor] = anchors(ctx)
    assert {anchor["kind"], anchor["precision"], anchor["pos"], anchor["placement"]} == {"progress", "exact", 1, "at"}
    id = Ref.conversation_id(ctx.ref)
    receive_barrier({:anchor_added, ^id, ^anchor})
    publish(ctx, bus(ctx, 1, "agent.progress", "tool-one"))
    assert :ok = flush(ctx.ref)
    assert anchors(ctx) == [anchor]
    refute_received {:anchor_added, ^id, _}
  end

  test "publication before its tool entry persists observed then exact using the real append notification", ctx do
    append_message(ctx)
    publish(ctx, bus(ctx, 2, "agent.progress", "tool-later"))
    assert :ok = flush(ctx.ref)
    assert [%{"precision" => "observed", "pos" => 1}] = anchors(ctx)
    receive_barrier({:scheduled, {:exact_expired, _, _}, 120_000})
    append_tool(ctx, "tool-later")
    # A call from this process could overtake PubSub's message; notification rendezvous proves processing.
    :sys.get_state(ctx.resolver)
    assert :ok = flush(ctx.ref)
    assert [%{"precision" => "observed"}, %{"precision" => "exact", "pos" => 2}] = anchors(ctx)
    assert :sys.get_state(ctx.resolver).pending == %{}
  end

  test "pending exact expires at 120 seconds and later entries cannot upgrade it", ctx do
    append_message(ctx)
    publish(ctx, bus(ctx, 3, "agent.progress", "never"))
    assert :ok = flush(ctx.ref)
    receive_barrier({:scheduled, message = {:exact_expired, _, _}, 120_000})
    send(ctx.resolver, message)
    assert %{exact_expired: 1} = AnchorResolver.stats(ctx.resolver)
    append_tool(ctx, "never")
    :sys.get_state(ctx.resolver)
    assert :ok = flush(ctx.ref)
    assert [%{"precision" => "observed"}] = anchors(ctx)
    assert :sys.get_state(ctx.resolver).pending == %{}
  end

  test "merge by another actor is after the last observed entry and carries PR identity", ctx do
    append_message(ctx)
    raw = Map.merge(bus(ctx, 4, "pr.merged"), %{pr: %{"number" => 42}, sha: "abc123"})
    publish(ctx, raw)
    assert :ok = flush(ctx.ref)
    assert [anchor] = anchors(ctx)
    assert {anchor["kind"], anchor["precision"], anchor["placement"], anchor["pos"]} == {"pr_merged", "observed", "after", 1}
    assert anchor["subject_ref"] == %{"head_sha" => "abc123", "pr_number" => 42, "decision_id" => nil}
  end

  test "worker event before first session persists unanchored instead of being dropped", ctx do
    publish(ctx, bus(ctx, 5, "pr.opened"))
    assert :ok = flush(ctx.ref)
    assert [%{"kind" => "pr_opened", "precision" => "unanchored", "pos" => nil}] = anchors(ctx)
  end

  test "unjoinable and uncatalogued events do not create a conversation", ctx do
    raw = bus(ctx, 6, "agent.progress")
    publish(ctx, %{raw | ticket_observation: %{raw.ticket_observation | status: :unattributed}})
    publish(ctx, bus(ctx, 7, "agent.custom.ignore"))
    assert AnchorResolver.stats(ctx.resolver) == %{unjoinable: 1, ignored_kind: 1}
    refute File.exists?(ctx.dir)
  end

  test "writer restart deduplicates durable anchors", ctx do
    publish(ctx, bus(ctx, 8, "branch.push"))
    assert :ok = flush(ctx.ref)
    first = anchors(ctx)
    {:ok, writer} = Ingest.writer(ctx.ref)
    :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    publish(ctx, bus(ctx, 8, "branch.push"))
    assert :ok = flush(ctx.ref)
    assert anchors(ctx) == first
    assert length(first) == 1
  end

  test "cursor persists atomically and is restored after a resolver restart", ctx do
    publish(ctx, bus(ctx, 9, "agent.progress"))
    send(ctx.resolver, :save_cursor)
    :sys.get_state(ctx.resolver)
    assert Jason.decode!(File.read!(Path.join(ctx.root, "resolver.json"))) == %{"last_event_id" => 9}
    assert {:ok, %{mode: mode}} = File.stat(Path.join(ctx.root, "resolver.json"))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {_, %{"last_event_id" => 9}, _} = ResolverState.load()
  end

  test "Command source provenance upgrades and survives resolver restart for History lookup", ctx do
    append_message(ctx)
    raw = Map.merge(bus(ctx, 10, "agent.decision.requested", "publication-id"), %{source: %{event_id: "decision-tool"}, decision_id: "d-6627"})
    publish(ctx, raw)
    assert :ok = flush(ctx.ref)
    append_tool(ctx, "decision-tool")
    :sys.get_state(ctx.resolver)
    assert :ok = flush(ctx.ref)
    assert [_, exact] = anchors(ctx)
    assert {exact["precision"], exact["method"], exact["pos"]} == {"exact", "decision_source", 2}
    # The production resolver's index is updated only by the writer after durable append.
    assert {:ok, ^exact} = History.anchor_for_decision("d-6627")
    # A malformed historical line must not take down the resolver's boot tree.
    File.write!(Path.join(ctx.dir, "anchors.jsonl"), Jason.encode!(%{"kind" => "command_requested", "subject_ref" => %{"decision_id" => "bad"}}) <> "\n", [:append])
    restored = start_supervised!({AnchorResolver, name: nil, exchange: ctx.exchange, pubsub: ctx.pubsub}, id: :restored)
    assert {:ok, ^exact} = AnchorResolver.anchor_for_decision("d-6627", restored)
    assert {:error, :not_found} = AnchorResolver.anchor_for_decision("absent", restored)
  end

  test "executor events require an existing Executor conversation", ctx do
    raw = %{bus(ctx, 11, "agent.progress") | topic: "executor.progress"}
    publish(ctx, raw)
    assert %{unjoinable: 1} = AnchorResolver.stats(ctx.resolver)
    ref = Ref.executor()
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    publish(ctx, raw)
    assert :ok = flush(ref)
    assert [%{"kind" => "executor_progress"}] = anchors(%{ctx | dir: Path.join(ctx.root, Ref.conversation_id(ref))})
  end

  test "resolver is synchronously bound and crashes only inside its supervisor", ctx do
    name = :anchor_resolver_test_child
    supervisor = start_supervised!({ResolverSupervisor, name: nil, resolver_opts: [name: name, exchange: ctx.exchange, pubsub: ctx.pubsub]})
    [{_, pid, _, _}] = Supervisor.which_children(supervisor)
    assert "ticket.*.agent.#" in Exchange.bindings_for(pid, ctx.exchange)
    orchestrator = Process.whereis(Aiur.Orchestrator)
    production_resolver = Process.whereis(AnchorResolver)
    monitor = Process.monitor(production_resolver)
    Process.exit(production_resolver, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^production_resolver, :killed})
    # Supervisor calls rendezvous after its EXIT handling and automatic restart.
    Supervisor.which_children(Aiur.Conversation.ResolverSupervisor)
    assert Process.whereis(AnchorResolver) != production_resolver
    assert Process.alive?(Process.whereis(AnchorResolver))
    assert Process.whereis(Aiur.Orchestrator) == orchestrator
    assert Process.alive?(orchestrator)
  end

  test "boot order starts journals before resolver, and resolver immediately after Exchange before producers" do
    children = Children.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)

    modules =
      Enum.map(children, fn
        {module, _} -> module
        %{start: {module, _, _}} -> module
        module -> module
      end)

    exchange = Enum.find_index(modules, &(&1 == Exchange))
    resolver = Enum.find_index(modules, &(&1 == ResolverSupervisor))
    assert resolver == exchange + 1
    assert Enum.find_index(modules, &(&1 == Aiur.Conversation.HeadTable)) < exchange
    assert resolver < Enum.find_index(modules, &(&1 == Aiur.Events.Publisher))
    assert resolver < Enum.find_index(modules, &(&1 == Aiur.Orchestrator))
  end

  test "anchor failure, uncertain fsync and torn tail recover without duplicate durable lines", ctx do
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, RecoveringStore)
    Application.put_env(:aiur, :conversation_journal, opts)
    subscribe(ctx)

    for {action, id} <- [{:fail, 21}, {:uncertain, 22}, {:partial, 23}] do
      Agent.update(ctx.control, &Map.put(&1, :anchor_action, action))
      publish(ctx, bus(ctx, id, "branch.push"))
      assert {:error, :degraded} = flush(ctx.ref)
      assert :ok = flush(ctx.ref)
      assert Enum.count(anchors(ctx), &(&1["event"]["event_id"] == id)) == 1
      conversation_id = Ref.conversation_id(ctx.ref)
      receive_barrier({:anchor_added, ^conversation_id, %{"event" => %{"event_id" => ^id}}})
    end
  end

  test "token bucket queues a burst above twenty window reads and drains it after refill", ctx do
    for id <- 1..25, do: publish(ctx, bus(ctx, id, "branch.push"))
    assert :ok = flush(ctx.ref)
    assert length(anchors(ctx)) == 20
    receive_barrier({:scheduled, :drain, 50})
    Agent.update(ctx.control, &Map.put(&1, :monotonic, 1_000))
    send(ctx.resolver, :drain)
    :sys.get_state(ctx.resolver)
    assert :ok = flush(ctx.ref)
    assert Enum.map(anchors(ctx), & &1["event"]["event_id"]) == Enum.to_list(1..25)
  end

  defp append_message(ctx) do
    Ingest.append(ctx.ref, %{source() | role: :worker}, [event(1)])
    assert :ok = flush(ctx.ref)
  end

  defp append_tool(ctx, id) do
    Ingest.append(ctx.ref, %{source() | role: :worker}, [%{role: "tool", msg_id: id, body: "emitted", payload: %{tool: "emit_event", tool_call_id: id}, timestamp: ctx.now}])
    assert :ok = flush(ctx.ref)
  end

  defp bus(ctx, id, suffix, tool_id \\ nil) do
    %{topic: "ticket.6627." <> suffix, ticket_observation: Aiur.TicketObservation.normalize(%{}, identity: ctx.identity, event_id: id, observed_at: ctx.now, provenance: %{source_event_id: tool_id})}
  end

  defp publish(ctx, event) do
    Exchange.publish(event.topic, event, ctx.exchange)
    :sys.get_state(ctx.resolver)
  end

  defp anchors(ctx), do: ctx.dir |> Path.join("anchors.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp subscribe(ctx), do: Phoenix.PubSub.subscribe(ctx.pubsub, "conversation:" <> Ref.conversation_id(ctx.ref))
end
