defmodule AiurWeb.Streamdeck.Deck.Input do
  @moduledoc "Resolve raw keys against ordered Deck sections before reducing navigation."

  alias AiurWeb.Streamdeck.Deck.Nav

  @doc "Sections map each view to ordered `%{id: id, tickets: [...]}` items (tickets need only `id`)."
  @spec reduce(Nav.t(), map(), map()) :: {Nav.t(), [Nav.effect()]} | {:error, map()}
  def reduce(nav, input, sections) do
    sizes = sizes(nav, sections)
    nav = Nav.clamp(nav, sizes)
    target = target(nav, input, sections)
    Nav.reduce(nav, Map.put(input, :target, target), sizes)
  end

  @spec sizes(Nav.t(), map()) :: map()
  def sizes(nav, sections) do
    Map.new([:ticket, :feature, :epic, :fleet], &{&1, length(Map.get(sections, &1, []))})
    |> Map.put(:drill, if(nav.stack == [], do: nil, else: length(items(nav, sections))))
  end

  defp target(nav, %{"kind" => "key_press", "index" => index}, sections) when is_integer(index) and index in 0..7 do
    kind = if nav.stack == [], do: nav.view, else: :ticket

    case Enum.at(items(nav, sections), Nav.page(nav) * 8 + index) do
      %{states: states} when kind == :fleet -> {:state, states}
      %{id: id} when is_binary(id) -> {kind, id}
      _empty -> nil
    end
  end

  defp target(_nav, _input, _sections), do: nil
  defp items(%{stack: [], view: view}, sections), do: Map.get(sections, view, [])

  defp items(%{stack: [{:state, states} | _rest]}, sections) do
    sections |> Map.get(:fleet, []) |> Enum.find(%{}, &(&1.states == states)) |> Map.get(:tickets, [])
  end

  defp items(%{stack: [{view, id} | _rest]}, sections) do
    sections |> Map.get(view, []) |> Enum.find(%{}, &(&1.id == id)) |> Map.get(:tickets, [])
  end
end
