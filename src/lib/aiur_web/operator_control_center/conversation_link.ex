defmodule AiurWeb.OperatorControlCenter.ConversationLink do
  @moduledoc false

  alias Aiur.Conversation.Ref

  @spec href(term()) :: String.t() | nil
  def href(identity) do
    case Ref.worker(identity) do
      {:ok, ref} -> "/conversations/#{Ref.conversation_id(ref)}"
      {:error, :unjoinable} -> nil
    end
  end
end
