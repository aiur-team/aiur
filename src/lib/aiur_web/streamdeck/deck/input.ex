defmodule AiurWeb.Streamdeck.Deck.Input do
  @moduledoc "Resolve raw keys against ordered Deck sections before reducing navigation."

  alias AiurWeb.Streamdeck.Deck.{ChatNavigation, Nav}
  alias AiurWeb.Streamdeck.Render.StripCounts

  @doc "Sections map each view to ordered `%{id: id, tickets: [...]}` items (tickets need only `id`)."
  @spec reduce(Nav.t(), map(), map()) :: {Nav.t(), [Nav.effect()]} | {:error, map()}
  def reduce(%{chat: chat, surface: :chat} = nav, input, _sections) when is_map(chat) do
    case input do
      %{"kind" => kind, "index" => 3} when kind in ["dial_press", "dial_long_press"] ->
        Nav.reduce(%{nav | chat: nil, surface: :grid}, input, %{})

      %{"kind" => "dial_press", "index" => 0} ->
        {%{nav | chat: nil, surface: :grid}, []}

      _ ->
        ChatNavigation.reduce(nav, input)
    end
  end

  def reduce(nav, input, sections) do
    sizes = sizes(nav, sections)
    nav = Nav.clamp(nav, sizes)
    target = target(nav, input, sections)
    Nav.reduce(nav, Map.put(input, :target, target), sizes)
  end

  @spec sizes(Nav.t(), map()) :: map()
  def sizes(nav, sections) do
    Map.new([:ticket, :feature, :epic, :fleet], &{&1, length(Map.get(sections, &1, []))})
    |> Map.put(:chip_max_offset, StripCounts.model(Map.get(sections, :counts), 999).offset)
    |> Map.put(:drill, if(nav.stack == [], do: nil, else: drill_size(nav, sections)))
  end

  defp drill_size(%{stack: [{:meter_detail, _} | _], meter_count: count}, _sections), do: count
  defp drill_size(nav, sections), do: length(items(nav, sections))

  defp target(%{stack: [{:meter_detail, _provider} | _]}, _input, _sections), do: nil

  defp target(nav, %{"kind" => "key_press", "index" => index}, sections) when is_integer(index) and index in 0..7 do
    kind = if nav.stack == [], do: nav.view, else: :ticket

    case Enum.at(items(nav, sections), Nav.page(nav) * 8 + index) do
      %{id: id, kind: :meter_detail} when kind == :fleet -> {:meter_detail, id}
      %{id: id} when is_binary(id) -> {kind, id}
      _empty -> nil
    end
  end

  defp target(_nav, _input, _sections), do: nil
  defp items(%{stack: [], view: view}, sections), do: Map.get(sections, view, [])

  defp items(%{stack: [{:meter_detail, id} | _rest]}, sections), do: Map.get(sections, {:meter_detail, id}, [])

  defp items(%{stack: [{view, id} | _rest]}, sections) do
    sections |> Map.get(view, []) |> Enum.find(%{}, &(Map.get(&1 || %{}, :id) == id)) |> Map.get(:tickets, [])
  end
end
