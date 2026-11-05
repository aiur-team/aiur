defmodule AgentConversation.ScopeTest do
  use ExUnit.Case, async: true

  alias AgentConversation.Scope

  defp scope(opts \\ []) do
    {:ok, scope} = Scope.new(Keyword.merge([tickets: ["7488"], games: ["open-game-maker"]], opts))
    scope
  end

  test "a conversation outside the allowed ticket and game cannot be registered" do
    assert {:error, :out_of_scope} = Scope.grant(scope(), "conv-other", ticket: "9999", game: "other-game")
  end

  test "an unregistered conversation is out of scope for every action" do
    for action <- Scope.actions() do
      assert {:error, :out_of_scope} = Scope.check(scope(), "conv-unregistered", action)
      refute Scope.allows?(scope(), "conv-unregistered", action)
    end
  end

  test "a read-only grant denies send, voice and Command answers" do
    {:ok, scope} = Scope.grant(scope(), "conv-1", ticket: "7488", actions: [:read])

    assert :ok = Scope.check(scope, "conv-1", :read)
    assert {:error, :permission_denied} = Scope.check(scope, "conv-1", :send)
    assert {:error, :permission_denied} = Scope.check(scope, "conv-1", :voice)
    assert {:error, :permission_denied} = Scope.check(scope, "conv-1", :answer_command)
  end

  test "a granted action list is reported per conversation without widening others" do
    {:ok, scope} = Scope.grant(scope(), "conv-1", ticket: "7488", actions: [:read, :send])
    {:ok, scope} = Scope.grant(scope, "conv-2", game: "open-game-maker", actions: [:read])

    assert :ok = Scope.check(scope, "conv-1", :send)
    assert {:error, :permission_denied} = Scope.check(scope, "conv-2", :send)
    assert {:ok, %{ticket: "7488", actions: [:read, :send]}} = Scope.conversation(scope, "conv-1")
    assert ["conv-1", "conv-2"] = Scope.conversations(scope)
  end

  test "an unknown action and a malformed scope are refused instead of guessed" do
    {:ok, scope} = Scope.grant(scope(), "conv-1", ticket: "7488", actions: [:read])

    assert {:error, :unknown_action} = Scope.check(scope, "conv-1", :delete)
    assert {:error, :unknown_action} = Scope.grant(scope, "conv-1", ticket: "7488", actions: [:publish])
    assert {:error, :invalid_scope} = Scope.new(ticket: "7488")
  end
end
