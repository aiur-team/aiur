defmodule AiurWeb.Streamdeck.Deck.Turns do
  @moduledoc "Chronological conversation turns over the desktop entry projection."

  @spec group([map()]) :: [map()]
  def group(entries) do
    {turns, pending} =
      Enum.reduce(entries, {[], []}, fn entry, {turns, pending} ->
        case entry.k do
          "milestone" -> {[turn(entry, [entry]) | flush(turns, pending)], []}
          "say" -> {[turn(entry, Enum.reverse([entry | pending])) | turns], []}
          "op" -> {[turn(entry, [entry]) | flush(turns, pending)], []}
          _ -> {turns, [entry | pending]}
        end
      end)

    turns |> flush(pending) |> Enum.reverse()
  end

  defp flush(turns, []), do: turns
  defp flush(turns, pending), do: [turn(hd(pending), Enum.reverse(pending)) | turns]

  defp turn(entry, entries) do
    %{id: "t:" <> entry.id, at: entry.at, k: entry.k, text: entry[:text] || entry[:label] || entry[:arg] || "", tools: Enum.count(entries, &(&1.k == "tool")), entries: entries}
  end
end
