defmodule AiurWeb.OperatorControlCenter.DecisionConversation do
  @moduledoc false
  alias Aiur.Conversation.History

  @spec link(String.t()) :: %{href: String.t(), precision: String.t()} | nil
  def link(decision_id) do
    case History.command_anchor(decision_id) do
      {:ok, anchor} ->
        id = URI.encode(anchor.conversation_id, &URI.char_unreserved?/1)
        %{href: "/conversations/#{id}?pos=#{anchor.pos}", precision: anchor.precision}

      :none ->
        nil
    end
  end
end
