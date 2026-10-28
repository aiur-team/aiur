defmodule AiurWeb.Streamdeck.Deck.ChatNavigation do
  @moduledoc "Seven chronological turn keys and a pinned LIVE key on focused tickets."
  alias AiurWeb.Streamdeck.Deck.Nav

  @spec reduce(Nav.t(), map()) :: {Nav.t(), [Nav.effect()]}
  def reduce(nav, %{"kind" => "key_press", "index" => 7}), do: {%{nav | chat: %{nav.chat | selected: nil, offset: 0}, scroll: 0}, []}

  def reduce(nav, %{"kind" => "key_press", "index" => index}) do
    turns = visible(nav.chat)
    position = index - (7 - length(turns))
    turn = if position >= 0, do: Enum.at(turns, position)
    {%{nav | chat: %{nav.chat | selected: turn && turn.id}, scroll: 0}, []}
  end

  def reduce(nav, %{"kind" => "dial_turn", "index" => 3, "ticks" => ticks}) do
    max_page = max(div(length(nav.chat.turns) - 1, 7), 0)
    requested = max(nav.chat.offset - ticks, 0)
    effects = if requested * 7 + 7 > length(nav.chat.turns) and nav.chat.more and is_binary(nav.chat.before), do: [{:chat_page, nav.chat.before}], else: []
    {%{nav | chat: %{nav.chat | offset: min(requested, max_page + if(effects == [], do: 0, else: 1))}}, effects}
  end

  def reduce(nav, %{"kind" => "dial_turn", "index" => 0, "ticks" => ticks}), do: {AiurWeb.Streamdeck.Render.Chat.clamp_scroll(%{nav | scroll: max(nav.scroll + ticks, 0)}), []}

  def reduce(%{selected: id} = nav, %{"kind" => "dial_turn", "index" => 1, "ticks" => ticks}) when is_binary(id) and ticks != 0,
    do: {nav, [{:priority, id, if(ticks < 0, do: :up, else: :down), abs(ticks)}]}

  def reduce(nav, _), do: {nav, []}

  @spec visible(map()) :: [map()]
  def visible(chat) do
    ending = max(length(chat.turns) - chat.offset * 7, 0)
    Enum.slice(chat.turns, max(ending - 7, 0), min(ending, 7))
  end
end
