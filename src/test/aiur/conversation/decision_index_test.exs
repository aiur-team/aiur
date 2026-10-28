Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.DecisionIndexTest do
  use ExUnit.Case, async: false
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, ResolverSupervisor, Store, TestSupport}
  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionConversation}
  alias AiurWeb.OperatorControlCenter.History, as: CommandHistory
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures

  setup context do
    on_exit(fn -> Supervisor.restart_child(ResolverSupervisor, AnchorResolver) end)
    ctx = TestSupport.setup(context)
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, Store)
    Application.put_env(:aiur, :conversation_journal, opts)
    on_exit(fn -> Supervisor.terminate_child(ResolverSupervisor, AnchorResolver) end)
    Map.put(ctx, :decision_id, "decision-" <> Path.basename(ctx.root))
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
