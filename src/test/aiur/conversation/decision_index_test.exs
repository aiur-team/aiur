Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.DecisionIndexTest do
  use Aiur.DecisionStoreCase, async: false
  import Aiur.OrchestratorStatusSupport, only: [eventually?: 2]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, ResolverSupervisor, Store, TestSupport}
  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionConversation}
  alias AiurWeb.OperatorControlCenter.History, as: CommandHistory
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures

  setup context do
    on_exit(fn -> Supervisor.restart_child(ResolverSupervisor, AnchorResolver) end)
    decision_store_dir = context.dir
    ctx = TestSupport.setup(context)
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, Store)
    Application.put_env(:aiur, :conversation_journal, opts)
    on_exit(fn -> Supervisor.terminate_child(ResolverSupervisor, AnchorResolver) end)
    :ok = Supervisor.terminate_child(ResolverSupervisor, AnchorResolver)
    {:ok, _resolver} = Supervisor.restart_child(ResolverSupervisor, AnchorResolver)
    ctx |> Map.put(:decision_id, "decision-" <> Path.basename(ctx.root)) |> Map.put(:decision_store_dir, decision_store_dir)
  end

  test "a worker Command request is anchored from the durable DecisionStore publish", ctx do
    alias Aiur.TrackerIdentity

    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "issue-node-979",
      database_id: 979,
      identifier: "979",
      reason: nil
    }

    {:ok, ref} = Ref.worker(identity)
    store = start_store!(ctx.decision_store_dir)
    assert "ticket.*.agent.#" in Aiur.Events.bindings_for(Process.whereis(AnchorResolver))
    ticket = %Issue{identifier: "979", tracker_identity: identity}
    tool_id = "decision-tool-#{System.unique_integer([:positive])}"
    source = %{source() | role: :worker, harness: "codex", provider_session_id: "worker-session"}
    Ingest.append(ref, source, [%{role: "tool", msg_id: tool_id, body: "emit_event decision.requested", timestamp: ctx.now, payload: %{tool: "emit_event", tool_call_id: tool_id}}])
    assert :ok = flush(ref)
    assert {:ok, [_session]} = History.list_sessions(ref)
    :ok = Aiur.Events.subscribe("ticket.979.agent.decision.requested")

    decision_source = %{agent_id: "agent-1", session_id: "worker-session", event_id: tool_id}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "Use this PR?", "blocking" => true, "source_id" => tool_id},
               [ticket: ticket, source: decision_source],
               store
             )

    assert Map.get(decision.ticket, :tracker_identity) == identity
    assert_receive {:event, %{ticket_observation: %{status: :joinable, tracker_identity: ^identity}}}, 500
    conversation_id = Ref.conversation_id(ref)

    assert eventually?(
             fn ->
               assert :ok = flush(ref)

               match?(
                 {:ok, %{conversation_id: ^conversation_id, pos: 1, precision: precision}}
                 when precision in ["observed", "causal", "exact"],
                 History.command_anchor(decision.decision_id)
               )
             end,
             100
           )

    assert %{href: href, precision: precision} = DecisionConversation.link(decision.decision_id)
    assert href == "/conversations/#{conversation_id}?pos=1"
    assert precision in ["observed", "causal", "exact"]
  end

  test "durable request lookup upgrades to exact, ignores resolution, and survives resolver restart", ctx do
    Ingest.append(ctx.ref, source(), [event(1), event(2)])
    assert :ok = flush(ctx.ref)
    persist(ctx, "observed", 1)
    id = Ref.conversation_id(ctx.ref)
    assert {:ok, %{conversation_id: ^id, pos: 1, precision: "observed"}} = History.command_anchor(ctx.decision_id)
    persist(ctx, "exact", 2)
    persist(ctx, "observed", 1)
    persist(ctx, "exact", 1, "command_resolved")
    expected = %{conversation_id: id, pos: 2, precision: "exact"}
    assert {:ok, ^expected} = History.command_anchor(ctx.decision_id)
    assert :ok = Supervisor.terminate_child(ResolverSupervisor, AnchorResolver)
    assert {:ok, _pid} = Supervisor.restart_child(ResolverSupervisor, AnchorResolver)
    assert {:ok, ^expected} = History.command_anchor(ctx.decision_id)
    assert {:ok, anchors} = History.list_anchors(ctx.ref)
    assert Enum.any?(anchors, &(&1["kind"] == "command_requested" and &1["subject_ref"]["decision_id"] == ctx.decision_id))
    assert Enum.any?(anchors, &(&1["kind"] == "command_resolved" and &1["subject_ref"]["decision_id"] == ctx.decision_id))
  end

  test "missing and unanchored requests never link to the conversation top", ctx do
    assert History.command_anchor(ctx.decision_id) == :none
    assert DecisionConversation.link(ctx.decision_id) == nil
    persist(ctx, "unanchored", nil)
    assert History.command_anchor(ctx.decision_id) == :none
    assert DecisionConversation.link(ctx.decision_id) == nil
  end

  test "selected inbox and answered history details read the durable request link in read-only mode", ctx do
    Ingest.append(ctx.ref, source(), [event(1)])
    assert :ok = flush(ctx.ref)
    persist(ctx, "observed", 1)
    decision = inbox_decision(ctx.decision_id)
    href = "/conversations/#{Ref.conversation_id(ctx.ref)}?pos=1"
    assert DecisionConversation.link(ctx.decision_id) == %{href: href, precision: "observed"}
    inbox = render_component(&DecisionCard.decision_card/1, decision: decision, now: ctx.now, selected: true, writable: false)
    assert inbox =~ ~s(href="#{href}")
    assert inbox =~ "Open in conversation (approximate)"
    answered = %{decision | answer: action_answer(:operator), decision_status: :answered, lifecycle: :resolved}
    html = render_component(&CommandHistory.history/1, rows: [answered], loaded: 1, expanded_id: decision.decision_id, writable: false)
    assert html =~ ~s(href="#{href}")
  end

  defp persist(ctx, precision, pos, kind \\ "command_requested") do
    anchor = %{
      "v" => 1,
      "anchor_id" => "#{kind}-#{precision}-#{System.unique_integer([:positive])}",
      "conversation_id" => Ref.conversation_id(ctx.ref),
      "kind" => kind,
      "precision" => precision,
      "pos" => pos,
      "event" => %{"event_id" => 1},
      "subject_ref" => %{"decision_id" => ctx.decision_id}
    }

    Ingest.anchor(ctx.ref, anchor)
    assert :ok = flush(ctx.ref)
    # Journal flush acknowledges after it sends the cache update; this call drains that update.
    AnchorResolver.stats()
  end
end
