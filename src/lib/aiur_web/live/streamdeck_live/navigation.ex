defmodule AiurWeb.StreamdeckLive.Navigation do
  @moduledoc "Adapt legacy browser selection and paging without cycling its non-grid modes."
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.FrameUpdates
  alias AiurWeb.StreamdeckLive.ChatFocus
  alias Phoenix.LiveView.Socket

  @spec route(Socket.t(), String.t(), map()) :: Socket.t()
  def route(socket, event, params) do
    sections = Deck.navigation(socket.assigns.grid)
    nav = key_nav(socket.assigns.deck_nav, event, params, sections)
    socket = assign(socket, :deck_nav, nav)
    frame = frame(socket, event, params, sections)

    case FrameUpdates.transition(nav, frame, socket.assigns.grid) do
      {:ok, nav, effects} ->
        socket |> assign(deck_nav: nav, deck_effects: effects) |> ChatFocus.apply(effects)

      _ ->
        socket
    end
  end

  defp frame(_socket, "dial-press", %{"action" => "back"}, _sections), do: %{"kind" => "dial_press", "index" => 0}

  defp frame(_socket, "dial-press", params, _sections),
    do: %{"kind" => "dial_turn", "index" => integer(params["index"], 3), "ticks" => 0}

  defp frame(_socket, "dial-long-press", params, _sections),
    do: %{"kind" => "dial_long_press", "index" => integer(params["index"], 3)}

  defp frame(_socket, "dial-turn", params, _sections),
    do: %{
      "kind" => "dial_turn",
      "index" => integer(params["index"], -1),
      "ticks" => integer(params["ticks"], 0)
    }

  # The legacy hook emits this before dial-press for the same physical press.
  defp frame(_socket, "grid-page", %{"action" => "cycle"}, _sections),
    do: %{"kind" => "dial_turn", "index" => 3, "ticks" => 0}

  defp frame(socket, "grid-page", params, _sections) do
    ticks =
      cond do
        Map.has_key?(params, "page") ->
          integer(params["page"], socket.assigns.grid_page) - socket.assigns.grid_page

        Map.has_key?(params, "value") ->
          sign(integer(params["value"], 0) - socket.assigns.grid_dial_value)

        true ->
          1
      end

    %{"kind" => "dial_turn", "index" => 3, "ticks" => max(-32, min(32, ticks))}
  end

  defp frame(_socket, "logs-scroll", params, _sections),
    do: %{
      "kind" => "dial_turn",
      "index" => if(params["axis"] == "events", do: 3, else: 0),
      "ticks" => integer(params["delta"], 0)
    }

  defp frame(socket, "key-press", params, sections) do
    nav = socket.assigns.deck_nav
    index = Enum.find_index(sections.ticket, &(&1.id == params["identifier"]))
    index = if is_integer(index), do: index - Nav.page(nav) * 8, else: -1
    %{"kind" => "key_press", "index" => integer(params["index"], index)}
  end

  # Legacy final windows overlap; resolve their identifier before page-of-eight indexing.
  defp key_nav(nav, "grid-page", %{"action" => "cycle"}, sections) do
    size = length(Map.get(sections, nav.view, []))
    page = rem(Nav.page(nav) + 1, max(ceil(size / 8), 1))
    %{nav | pages: Map.put(nav.pages, nav.view, page)}
  end

  defp key_nav(%{view: :ticket, stack: []} = nav, "key-press", %{"identifier" => id}, sections) do
    case Enum.find_index(sections.ticket, &(&1.id == id)) do
      nil -> nav
      index -> %{nav | pages: Map.put(nav.pages, :ticket, div(index, 8))}
    end
  end

  defp key_nav(nav, _event, _params, _sections), do: nav

  defp sign(value) when value < 0, do: -1
  defp sign(0), do: 0
  defp sign(_value), do: 1
  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer(_value, default), do: default
end
