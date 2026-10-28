defmodule AiurWeb.Conversation.CardRefresh do
  @moduledoc false
  alias AiurWeb.Conversation.Paging

  @spec refresh(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket, previous) do
    old = cards(previous)
    new = cards(socket.assigns)

    positions =
      (Map.keys(old) ++ Map.keys(new))
      |> Enum.uniq()
      |> Enum.filter(&(old[&1] != new[&1]))
      |> Enum.flat_map(&(positions(old[&1]) ++ positions(new[&1])))

    Paging.refresh_entries(socket, positions)
  end

  defp cards(assigns) do
    Map.new(assigns.decision_page.decisions, fn row ->
      # These inbox-only fields are not rendered by the inline card.
      content = Map.drop(row, [:latency, :audit_history])
      {row.decision_id, {assigns.command_slots[row.decision_id], content, assigns.decision_actions[row.decision_id]}}
    end)
  end

  defp positions({{:at_pos, pos}, _row, _state}), do: [pos]
  defp positions(_card), do: []
end
