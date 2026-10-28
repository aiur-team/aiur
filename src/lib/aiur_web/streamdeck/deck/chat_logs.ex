defmodule AiurWeb.Streamdeck.Deck.ChatLogs do
  @moduledoc "Keeps the existing Logs painter on the same allowlisted conversation tail."
  alias Aiur.Conversation.History
  alias AiurWeb.StreamdeckLogs

  @spec push(Phoenix.Socket.t(), String.t(), [map()]) :: :ok
  def push(socket, id, entries) do
    logs = StreamdeckLogs.project(%{events: History.bus_events(id), transcript: Enum.map(entries, &row/1)})
    Phoenix.Channel.push(socket, "logs", StreamdeckLogs.wire(logs))
  end

  defp row(%{k: "tool"} = entry), do: %{type: "message", role: "tool", body: Enum.join([entry[:arg] || "", entry[:res] || ""], " · "), tool: entry[:name], timestamp: timestamp(entry.at)}
  defp row(entry), do: %{type: "message", role: role(entry.k), body: entry[:text] || "", timestamp: timestamp(entry.at)}
  defp role("say"), do: "assistant"
  defp role("op"), do: "user"
  defp role(_), do: "system"
  defp timestamp(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp timestamp(_), do: nil
end
