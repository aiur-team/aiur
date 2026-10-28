Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationCommandsTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, TestSupport}
  alias Aiur.{DecisionStore, TrackerIdentity}

  setup context do
    ctx = TestSupport.setup(context)
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, Aiur.Conversation.Store)
    Application.put_env(:aiur, :conversation_journal, opts)
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_inline", "number" => 6636}, {"aiur-team", "aiur"}, {"aiur-team", "aiur"})
    {:ok, ref} = Ref.worker(identity)
    Agent.update(ctx.control, &Map.put(&1, :now, DateTime.add(ctx.now, -700)))
    Ingest.append(ref, %{source() | role: :worker}, Enum.map(1..59, &event/1))
    assert :ok = flush(ref)
    Agent.update(ctx.control, &Map.put(&1, :now, ctx.now))
    Ingest.append(ref, %{source() | role: :worker}, [event(60)])
    assert :ok = flush(ref)
    store = start_supervised!({DecisionStore, name: nil, state_dir: Path.join(ctx.root, "commands"), filesystem_sync_fun: fn -> :ok end})
    endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    configure(decision_store: store, dashboard_writable: true)
    on_exit(fn -> Application.put_env(:aiur, AiurWeb.Endpoint, endpoint) end)
    Map.merge(ctx, %{ref: ref, store: store})
  end

  defp request(ctx, source_id, ticket \\ "6636") do
    payload = %{
      "source_id" => source_id,
      "question" => "Choose #{source_id}?",
      "blocking" => false,
      "authority" => "human_required",
      "reversibility" => "reversible",
      "options" => [%{"id" => "yes", "label" => "Yes", "description" => "Proceed"}]
    }

    assert {:ok, %{decision: decision}} =
             Aiur.DecisionStoreCase.request(ctx.store, payload, ticket: %{identifier: ticket, title: "Inline", url: nil}, source: %{agent_id: "worker", session_id: "session-one", event_id: nil})

    decision
  end

  defp configure(opts) do
    updated = Keyword.merge(Application.get_env(:aiur, AiurWeb.Endpoint, []), opts)
    Application.put_env(:aiur, AiurWeb.Endpoint, updated)
    AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, updated}], [])
  end

  defp open(ctx), do: live(build_conn(), "/conversations/" <> Ref.conversation_id(ctx.ref))
  defp card(row), do: "#conversation-command-#{row.decision_id}"
  defp answer(view, row), do: render_submit(element(view, "#decision-answer-form-#{row.decision_id}"), %{"decision_id" => row.decision_id, "answer" => %{"choice" => "option:yes"}})

  defp anchor(ctx, row, pos) do
    Ingest.anchor(ctx.ref, %{
      "v" => 1,
      "anchor_id" => "anchor-#{row.decision_id}",
      "conversation_id" => Ref.conversation_id(ctx.ref),
      "kind" => "command_requested",
      "precision" => "exact",
      "pos" => pos,
      "event" => %{"event_id" => 1},
      "subject_ref" => %{"decision_id" => row.decision_id}
    })

    assert :ok = flush(ctx.ref)
    AnchorResolver.stats()
  end

  test "open Command renders after its anchor and top chip loads an older anchor", ctx do
    row = request(ctx, "anchored")
    anchor(ctx, row, 1)
    {:ok, view, _} = open(ctx)
    refute has_element?(view, card(row))
    render_click(element(view, "button[phx-value-id='#{row.decision_id}']"))
    assert has_element?(view, "#entry-1 > article#{card(row)}")
    assert has_element?(view, "[data-state=live]")
    assert_push_event(view, "conversation-command", %{pos: 1})
    answer(view, row)
    assert has_element?(view, "#{card(row)} .decision-answer-summary", "Yes")
  end

  test "unanchored Command is pinned, other tickets excluded, journal unchanged by answer", ctx do
    row = request(ctx, "pinned")
    other = request(ctx, "other", "99")
    {:ok, before} = History.list_entries(ctx.ref, principal: :internal)
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "section#conversation > article#{card(row)}", "Position unknown")
    refute has_element?(view, card(other))
    answer(view, row)
    assert {:ok, decision} = DecisionStore.get(row.decision_id, ctx.store)
    assert decision.answer.selected_option_id == "yes"
    assert decision.answer.actor.kind == :operator
    assert {:ok, after_page} = History.list_entries(ctx.ref, principal: :internal)
    assert before.entries == after_page.entries
    # Future regression guard for D15: entries remain immutable.
    refute has_element?(view, "#conversation-entries [phx-click*=edit], #conversation-entries [phx-click*=hide]")
  end

  test "answered elsewhere resolves an anchored card live and late submit reports winner", ctx do
    row = request(ctx, "race")
    anchor(ctx, row, 40)
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#{card(row)} form")

    assert {:ok, _} =
             DecisionStore.answer(
               row.decision_id,
               %{"option_id" => "yes", "idempotency_key" => "elsewhere", "expected_version" => row.version},
               [actor: %{kind: :operator, id: "another-device"}],
               ctx.store
             )

    assert has_element?(view, "#{card(row)} .decision-answer-summary", "Yes")
    assert render(view) =~ "Already answered by you on another device"
    render_hook(view, "answer-decision", %{"decision_id" => row.decision_id, "answer" => %{"choice" => "option:yes"}})
    assert render(view) =~ "Already answered by"
    assert {:ok, decision} = DecisionStore.get(row.decision_id, ctx.store)
    assert decision.answer.actor.id == "another-device"
  end

  test "new Commands arrive live and store failure is visibly unavailable", ctx do
    {:ok, view, _} = open(ctx)
    row = request(ctx, "new")
    assert has_element?(view, card(row))
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}, 1_000
    configure(decision_store: dead)
    Aiur.DecisionPubSub.broadcast_changed(row.decision_id, row.version + 1)
    assert render(view) =~ "Some Commands are unavailable"
  end

  test "read-only cards have no controls and reject forged answers", ctx do
    row = request(ctx, "readonly")
    endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    configure(Keyword.put(endpoint, :dashboard_writable, false))
    {:ok, view, _} = open(ctx)
    assert has_element?(view, card(row))
    refute has_element?(view, "#{card(row)} form")
    render_hook(view, "answer-decision", %{"decision_id" => row.decision_id, "answer" => %{"choice" => "option:yes"}})
    assert {:ok, decision} = DecisionStore.get(row.decision_id, ctx.store)
    assert decision.answer == nil
  end
end
