defmodule Aiur.Config.PathsConversationTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  setup do
    keys = [:conversation_state_dir, :decision_state_dir]
    original = Map.new(keys, &{&1, Application.fetch_env(:aiur, &1)})

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          {:ok, path} -> Application.put_env(:aiur, key, path)
          :error -> Application.delete_env(:aiur, key)
        end
      end
    end)

    root = Path.join(System.tmp_dir!(), "conversation-paths-#{System.unique_integer([:positive])}")
    {:ok, root: root}
  end

  test "an explicit conversation override wins over the decision root", %{root: root} do
    override = Path.join(root, "override")
    Application.put_env(:aiur, :decision_state_dir, Path.join(root, "decisions"))
    Application.put_env(:aiur, :conversation_state_dir, override)
    assert Paths.conversation_state_dir() == {:ok, override}
  end

  test "the default is a conversation leaf under the decision root", %{root: root} do
    Application.put_env(:aiur, :decision_state_dir, root)
    Application.delete_env(:aiur, :conversation_state_dir)
    assert Paths.conversation_state_dir() == {:ok, Path.join(root, "conversations")}
    Application.put_env(:aiur, :conversation_state_dir, "")
    assert Paths.conversation_state_dir() == {:ok, Path.join(root, "conversations")}
  end
end
