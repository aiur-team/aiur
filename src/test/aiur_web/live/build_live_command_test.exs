defmodule AiurWeb.BuildLiveCommandTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.DecisionStore
  alias Aiur.TestSupport.BuildHome.{CommandStore, FixtureConversationSource}
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TestSupport.LiveViewAsync

  # Fixture row 601 is the design's J:206 `a3` ticket, agent state `command`.
  @ticket "601"

  setup do
    previous_source = Application.get_env(:aiur, :build_conversation_source)
    Application.put_env(:aiur, :build_conversation_source, FixtureConversationSource)

    on_exit(fn ->
      if previous_source, do: Application.put_env(:aiur, :build_conversation_source, previous_source), else: Application.delete_env(:aiur, :build_conversation_source)
    end)

    EndpointStubs.put(dashboard_writable: true)
    %{store: CommandStore.start!(Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}"))}
  end

  defp open_card(ticket \\ @ticket) do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "conversation-page", %{id: ticket})
    assert_reply(view, %{"kind" => "conversation"})
    view
  end

  defp answer(view, decision, choice) do
    render_hook(view, "answer-decision", %{decision_id: decision.decision_id, answer: %{choice: choice}})
    assert_reply(view, reply)
    reply
  end

  defp stored_answer(store, decision) do
    {:ok, stored} = DecisionStore.get(decision.decision_id, store)
    stored.answer
  end

  test "the first view pushes the ticket's open Command as an answerable card", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    assert_push_event(view, "modal:command", %{ticket: @ticket, card: card})
    assert %{state: "open", writable: true, decision_id: id, options: [%{id: "persist", recommended: true}, %{id: "local", recommended: false}]} = card
    assert id == decision.decision_id
  end

  test "an answer from the card is recorded with the dashboard operator through the durable path", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()

    reply = answer(view, decision, "option:persist")
    assert %{status: "accepted", text: "Answered: Persist to disk, rehydrate on boot", card: nil} = reply
    stored = stored_answer(store, decision)
    assert stored.selected_option_id == "persist"
    # The trusted dashboard identity (test_helper's AIUR_DASHBOARD_USERNAME), never a client value.
    assert stored.actor == %{kind: :operator, id: "operator"}
    assert reply.action_id == stored.action_id
  end

  test "an answer recorded elsewhere settles the open card on the next decision signal", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    assert_push_event(view, "modal:command", %{card: %{state: "open"}})

    CommandStore.answer!(store, decision, "local")
    send(view.pid, {:decision_changed, decision.decision_id, decision.version + 1})
    assert_push_event(view, "modal:command", %{card: %{state: "settled", kind: "answered", option_id: "local"}})
  end

  test "a stale version is rejected, the card reloads at the new version and the next click records", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()

    assert {:ok, %{decision: enriched}} =
             DecisionStore.enrich(
               decision.decision_id,
               %{"context" => %{"short_summary" => "More detail"}},
               [actor: %{kind: :supervisor, id: "supervising-agent"}, expected_version: decision.version],
               store
             )

    assert %{status: "error", message: message, card: %{state: "open", version: version}} = answer(view, decision, "option:persist")
    assert message =~ "changed to version #{enriched.version}"
    assert version == enriched.version
    assert %{status: "accepted"} = answer(view, decision, "option:persist")
    assert stored_answer(store, decision).selected_option_id == "persist"
  end

  test "an unknown option is refused and the card stays open", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    assert %{status: "error", message: "That option is no longer available.", card: %{state: "open"}} = answer(view, decision, "option:nope")
    assert stored_answer(store, decision) == nil
  end

  test "a second submission after success records nothing more", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    assert %{status: "accepted"} = answer(view, decision, "option:persist")
    first = stored_answer(store, decision)
    assert %{status: "settled"} = answer(view, decision, "option:persist")
    assert stored_answer(store, decision) == first
  end

  test "after answering the blocking Command the reply carries the next open one", %{store: store} do
    later = CommandStore.request!(store, @ticket, blocking: false)
    blocking = CommandStore.request!(store, @ticket)
    view = open_card()
    assert_push_event(view, "modal:command", %{card: %{decision_id: shown}})
    assert shown == blocking.decision_id

    assert %{status: "accepted", card: %{state: "open", decision_id: next}} = answer(view, blocking, "option:local")
    assert next == later.decision_id
  end

  test "a read-only dashboard disables the card and a forged answer writes nothing", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    EndpointStubs.put(dashboard_writable: false)
    view = open_card()
    assert_push_event(view, "modal:command", %{card: %{writable: false, disabled_reason: "Read-only dashboard"}})
    assert %{status: "error"} = answer(view, decision, "option:persist")
    assert stored_answer(store, decision) == nil
  end

  test "writes re-check the dashboard gate after mount", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    EndpointStubs.put(dashboard_writable: false)
    assert %{status: "error", message: "This dashboard is read-only."} = answer(view, decision, "option:persist")
    assert stored_answer(store, decision) == nil
  end

  test "a forged choice cannot record a custom response", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    render_hook(view, "answer-decision", %{decision_id: decision.decision_id, answer: %{choice: "custom", custom_response: "x"}})
    assert_reply(view, %{status: "error", message: "The submitted answer was incomplete. Try again."})
    assert stored_answer(store, decision) == nil
  end

  test "a command agent with no Command shows the cannot-load card", %{store: _store} do
    view = open_card()
    assert_push_event(view, "modal:command", %{card: %{state: "unavailable", decision_id: nil, href: "/commands"}})
  end

  test "closing the conversation clears the card so a later signal pushes nothing", %{store: store} do
    decision = CommandStore.request!(store, @ticket)
    view = open_card()
    assert_push_event(view, "modal:command", %{card: %{state: "open"}})
    render_hook(view, "conversation-close", %{id: @ticket})
    assert :sys.get_state(view.pid).socket.assigns.command_card == nil

    CommandStore.answer!(store, decision, "local")
    send(view.pid, {:decision_changed, decision.decision_id, decision.version + 1})
    refute_push_event(view, "modal:command", _, 100)
  end
end
