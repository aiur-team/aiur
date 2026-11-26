defmodule AiurWeb.Build.CommandCardTest do
  # The DecisionStore state dir is application env, so these tests run alone.
  use ExUnit.Case, async: false
  alias Aiur.DecisionStore
  alias Aiur.TestSupport.BuildHome.CommandStore
  alias AiurWeb.Build.CommandCard
  alias AiurWeb.OperatorControlCenter.DecisionCommands

  @context %{agent_state: "command", writable: true}

  setup do
    previous = System.get_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    on_exit(fn -> if previous, do: System.put_env("AIUR_DASHBOARD_USERNAME", previous) end)
    %{store: CommandStore.start!(Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}"))}
  end

  defp socket(row, card) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        writable: true,
        selected_decision: row,
        selected_decision_id: row && row.decision_id,
        decision_actions: %{},
        command_card: %{ticket: "601", agent_state: "command", card: card}
      }
    }
  end

  defp row(decision) do
    {:ok, row} = DecisionCommands.command_detail(decision.decision_id)
    row
  end

  describe "DecisionCommands.ticket_command/1" do
    # Guard: the store matches tickets exactly today; a prefix match would show another ticket's Command.
    test "matches the identifier exactly", %{store: store} do
      wanted = CommandStore.request!(store, "12")
      CommandStore.request!(store, "123")
      assert {:open, %{decision_id: id}} = DecisionCommands.ticket_command("12")
      assert id == wanted.decision_id
    end

    test "settled Commands never hide an open one", %{store: store} do
      open = CommandStore.request!(store, "601")

      for _ <- 1..100 do
        decision = CommandStore.request!(store, "601", blocking: false)
        CommandStore.answer!(store, decision, "local")
      end

      assert {:open, %{decision_id: id}} = DecisionCommands.ticket_command("601")
      assert id == open.decision_id
    end

    test "an unreadable store is never \"no Command\"", %{store: store} do
      assert DecisionCommands.ticket_command("601") == :none
      stop_supervised!(store)
      assert {:unavailable, _reason} = DecisionCommands.ticket_command("601")
      assert {:unavailable, :store_unavailable} = DecisionCommands.command_detail("dec_missing")
    end

    test "the blocking, oldest open Command is shown first", %{store: store} do
      CommandStore.request!(store, "601", blocking: false)
      blocking = CommandStore.request!(store, "601")
      CommandStore.request!(store, "601")
      assert {:open, %{decision_id: id}} = DecisionCommands.ticket_command("601")
      assert id == blocking.decision_id
    end
  end

  describe "payload/3" do
    test "recommended marks exactly the recommended option, and none without a recommendation", %{store: store} do
      local = row(CommandStore.request!(store, "601", recommendation: %{"option_id" => "local", "reason" => "simpler"}))
      assert %{state: "open", options: options} = CommandCard.payload({:open, local}, nil, @context)
      assert Enum.map(options, &{&1.id, &1.recommended}) == [{"persist", false}, {"local", true}]
      assert hd(options).title == "Survives a restart"

      assert %{options: options} = CommandCard.payload({:open, %{local | recommendation: nil}}, nil, @context)
      refute Enum.any?(options, & &1.recommended)
    end

    test "a read-only dashboard disables the card with a visible reason", %{store: store} do
      open = row(CommandStore.request!(store, "601"))
      assert %{writable: false, disabled_reason: "Read-only dashboard"} = CommandCard.payload({:open, open}, nil, %{@context | writable: false})
      assert %{writable: true, disabled_reason: nil} = CommandCard.payload({:open, open}, nil, @context)
    end

    test "expired, dismissed and moot render their own settled text, not \"Answered\"", %{store: store} do
      base = row(CommandStore.request!(store, "601"))

      for {status, kind, text} <- [{:expired, "expired", "This Command expired."}, {:dismissed, "dismissed", "Closed without an answer."}, {:moot, "moot", "No longer needed."}] do
        assert %{state: "settled", kind: ^kind, text: ^text, option_id: nil, at_ms: nil} = CommandCard.payload({:settled, %{base | decision_status: status}}, base.decision_id, @context)
      end
    end

    test "an answer with no time leaves it out instead of inventing one", %{store: store} do
      base = row(CommandStore.request!(store, "601"))
      answer = %{selected_option_id: "local", custom_response: nil, actor: nil, accepted_at: nil, action_id: "act"}
      card = CommandCard.payload({:settled, %{base | decision_status: :decided, answer: answer}}, base.decision_id, @context)
      assert %{kind: "answered", option_id: "local", text: "Answered: Keep process-local", at_ms: nil} = card

      removed = CommandCard.payload({:settled, %{base | decision_status: :decided, answer: %{answer | selected_option_id: "gone"}}}, base.decision_id, @context)
      assert removed.text == "Answered: option gone"
    end

    test "a Command with no options still shows a card", %{store: store} do
      open = row(CommandStore.request!(store, "601"))
      assert %{state: "open", options: []} = CommandCard.payload({:open, %{open | options: []}}, nil, @context)
    end

    test "a command agent with no loadable Command shows the unavailable card, never nothing" do
      for read <- [:none, {:unavailable, :retained_store_unavailable}] do
        assert %{state: "unavailable", decision_id: nil, href: "/commands"} = CommandCard.payload(read, nil, @context)
        assert CommandCard.payload(read, nil, %{@context | agent_state: "active"}) == nil
      end

      assert %{state: "unavailable", decision_id: "dec_1", text: text} = CommandCard.payload({:unavailable, :store_unavailable}, "dec_1", %{@context | agent_state: "active"})
      assert text =~ "outcome is not confirmed"
    end
  end

  describe "reply/2 after record_answer/4" do
    test "a click after another answer won replies settled and keeps the winner", %{store: store} do
      decision = CommandStore.request!(store, "601")
      open = row(decision)
      CommandStore.answer!(store, decision, "local")

      socket = DecisionCommands.record_answer(socket(open, nil), decision.decision_id, %{"choice" => "option:persist"}, &CommandCard.reload/1)
      assert {%{status: "settled", card: %{state: "settled", option_id: "local", text: text}}, _socket} = CommandCard.reply(socket, decision.decision_id)
      # The presented actor carries only its kind, so no operator name is shown.
      assert text == "Answered: Keep process-local"
      assert {:ok, %{answer: %{selected_option_id: "local"}}} = DecisionStore.get(decision.decision_id, store)
    end

    test "a store failure keeps a card for the shown Command with its reason", %{store: store} do
      decision = CommandStore.request!(store, "601")
      open = row(decision)
      stop_supervised!(store)

      socket = DecisionCommands.record_answer(socket(open, nil), decision.decision_id, %{"choice" => "option:persist"}, &CommandCard.reload/1)
      assert {%{status: "error", message: "Command storage is currently unavailable.", card: card}, _socket} = CommandCard.reply(socket, decision.decision_id)
      assert %{state: "unavailable", decision_id: id} = card
      assert id == decision.decision_id
    end
  end
end
